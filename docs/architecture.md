# Architecture

This document describes the full architecture of the homelab: how the three infrastructure layers relate to each other, how services are deployed and connected, and how all configuration flows from code to running pods.

## Overview

The homelab runs on a single **Mac mini M4** using **OrbStack** as the Kubernetes runtime. Everything is codified — no ad-hoc `kubectl` commands are part of normal operations. The infrastructure is organized into three distinct layers with clear responsibilities:

```mermaid
flowchart TD
    subgraph layer0["Layer 0 — Terraform (bootstrap, run once)"]
        TF["terraform apply"]
        TF --> A["ArgoCD Helm release"]
        TF --> B["Bootstrap K8s Secrets\nnever in git"]
        TF --> C["ArgoCD root Application\nApp of Apps"]
        TF --> D["Infisical Application CR\nwith sensitive Helm values"]
    end

    subgraph layer1["Layer 1 — ArgoCD (GitOps, driven by git push)"]
        C --> E["Application: infisical"]
        C --> F["Application: external-secrets"]
        C --> G["Application: external-secrets-config"]
        C --> J["Application: monitoring"]
        C --> K["Application: authentik"]
        D --> E
    end

    subgraph layer2["Layer 2 — Infisical + ESO (secret management)"]
        E --> InfisicalSvc["Infisical service\nrunning in cluster"]
        F --> ESOOperator["ESO operator"]
        G --> CSS["ClusterSecretStore\nconnected to Infisical"]
    end
```

## Layer 0: Terraform

Terraform bootstraps the cluster exactly once. After `terraform apply`, no more Terraform is needed for day-to-day operations — only for credential rotation or ArgoCD version upgrades.

**What Terraform creates:**

| Resource | Where | Why Terraform (not git) |
|---|---|---|
| `argocd` namespace | cluster | Must exist before Helm install |
| ArgoCD Helm release | `argocd` namespace | Installs ArgoCD itself — can't use ArgoCD to deploy ArgoCD |
| `infisical-secrets` K8s Secret | `infisical` namespace | Contains `ENCRYPTION_KEY` + `AUTH_SECRET` — Infisical needs these before it can run, so they can't come from Infisical |
| `infisical-helm-secrets` K8s Secret | `argocd` namespace | Postgres + Redis passwords for the Infisical Helm chart. ArgoCD `Application` CRs don't support `valuesFrom` referencing K8s Secrets, so Terraform injects them via `helm.valuesObject` |
| `infisical-machine-identity` K8s Secret | `external-secrets` namespace | ESO uses this to authenticate to Infisical. Terraform owns it so the credential can be rotated with `terraform apply` |
| ArgoCD root Application (`argocd-apps`) | `argocd` namespace | Triggers the App of Apps — the root of all GitOps |
| ArgoCD Infisical Application (`infisical`) | `argocd` namespace | Created by Terraform because its Helm values embed sensitive credentials |

**Why Terraform for ArgoCD, not `kubectl apply`?**

Every `kubectl apply` invocation is an untracked side-effect. Terraform tracks all resources in `terraform.tfstate`, which means:
- `terraform plan` shows exactly what will change before applying
- `terraform destroy` cleanly removes everything
- The full bootstrap is reproducible from a fresh cluster with a single command

## Layer 1: ArgoCD (App of Apps)

ArgoCD watches the GitHub repository and applies any changes to `k8s/apps/` automatically. The pattern used is **App of Apps**: one root Application (`argocd-apps`) points to `k8s/apps/argocd/`, which contains AppProject and Application CRs for every other service.

Applications are organized into three **AppProjects** that scope which repos, namespaces, and cluster-scoped resources each group of apps can access:

| Project | Purpose | Applications |
|---|---|---|
| `secrets` | Secret management infrastructure | `infisical`, `external-secrets`, `external-secrets-config` |
| `data` | Databases and data stores | (reserved for future use) |
| `apps` | User-facing applications | `monitoring`, `authentik`, `openclaw`, `trivy-operator`, `trivy-operator-vulnerability-scanner`, `trivy-dashboard`, `namespace-security`, `networking-policies` |
| `default` | Bootstrap only | `argocd-apps` (root) |

```mermaid
flowchart LR
    subgraph git["GitHub: holdennguyen/homelab"]
        direction TB
        RootDir["k8s/apps/argocd/\nkustomization.yaml"]
        ESDir["k8s/apps/external-secrets/"]
        MonDir["k8s/apps/argocd/applications/\nmonitoring-app.yaml (Helm)"]
        OCDir["k8s/apps/openclaw/"]
    end

    subgraph argocd["ArgoCD (argocd namespace)"]
        RootApp["argocd-apps\n(default project)"]

        subgraph secretsProj["secrets project"]
            InfisicalApp["infisical\n(Terraform-managed)"]
            ESOApp["external-secrets"]
            ESCApp["external-secrets-config"]
        end

        subgraph dataProj["data project"]
            DataPlaceholder["(reserved)"]
        end

        subgraph appsProj["apps project"]
            MonApp["monitoring"]
            AuthApp["authentik"]
            OCApp["openclaw"]
            TrivyApp["trivy-operator"]
            TrivyDashApp["trivy-dashboard"]
            NSApp["namespace-security"]
            NPApp["networking-policies"]
        end
    end

    RootApp -- "syncs" --> RootDir
    RootDir -- "creates" --> secretsProj
    RootDir -- "creates" --> dataProj
    RootDir -- "creates" --> appsProj

    ESOApp -- "syncs Helm chart" --> ESOChart["charts.external-secrets.io"]
    ESCApp -- "syncs" --> ESDir
    MonApp -- "syncs Helm chart" --> MonChart["prometheus-community\nHelm repo"]
    OCApp -- "syncs" --> OCDir
    InfisicalApp -- "syncs Helm chart" --> InfisicalChart["cloudsmith Helm repo"]
```

Every Application CR carries standard `app.kubernetes.io/*` labels (`name`, `part-of`, `component`, `managed-by`). See the [ArgoCD README](../k8s/apps/argocd/README.md#adding-a-new-application) for the full labeling rules and new-application template.

**Branch protection** on `main`:
- PRs require at least one approving review before merge
- Force pushes and branch deletion are blocked
- Linear history is required (no merge commits)
- Admin bypass is available for emergencies (`enforce_admins: false`)

**Sync policies** on all applications:
- `automated.prune: true` — resources removed from git are deleted from the cluster
- `automated.selfHeal: true` — any manual `kubectl` change is reverted within ~3 minutes
- All applications target `targetRevision: HEAD` — every merge to `main` is deployed

## Layer 2: Secret Management

Secrets never live in git. All application credentials flow from **Infisical** (the secret store) through **External Secrets Operator** into Kubernetes Secrets that pods consume.

```mermaid
flowchart TD
    subgraph infisical_ui["Infisical UI / CLI"]
        dev["Developer adds secret\nPOSTGRES_PASSWORD = abc123"]
    end

    subgraph infisical_svc["Infisical (infisical namespace)"]
        InfisicalAPI["Infisical API\nproject: homelab / prod"]
    end

    subgraph eso["External Secrets Operator (external-secrets namespace)"]
        CSS["ClusterSecretStore\ninfisical\nauthenticates via machine identity"]
        ES["ExternalSecret\npostgresql-secret"]
    end

    subgraph target_ns["target namespace"]
        K8sSecret["K8s Secret\n(created by ESO)"]
        TargetPod["Application Pod\nenv from secret"]
    end

    dev --> InfisicalAPI
    CSS -- "Universal Auth\nclientId + clientSecret" --> InfisicalAPI
    InfisicalAPI -- "GET /api/v3/secrets/raw\n?workspaceSlug=homelab\n&environment=prod" --> ES
    ES -- "creates/updates" --> K8sSecret
    K8sSecret -- "envFrom / secretKeyRef" --> TargetPod
```

For the full secret management reference, see [docs/secret-management.md](./secret-management.md).

## Host-Level Automation

Some operational tasks are managed outside of Kubernetes using macOS launchd:

- **Nightly shutdown/startup**: The OrbStack Kubernetes cluster automatically stops at 23:30 and starts at 06:30 daily to save power and reduce host wear. This is implemented with wrapper scripts (`scripts/orb-stop.sh`, `scripts/orb-start.sh`) and launchd plists (`scripts/com.homelab.orbstop.plist`, `scripts/com.homelab.orbstart.plist`). See [Nightly Shutdown Documentation](./nightly-shutdown.md) for full details.

These components run on the host macOS and are not managed by ArgoCD (since ArgoCD itself runs inside the cluster that gets shut down).

## Service Map

```mermaid
flowchart TD
    subgraph infisicalNs["infisical namespace"]
        InfisicalPod["Infisical\nNodePort :30445"]
        InfisicalPG["PostgreSQL\n(Infisical internal)"]
        InfisicalRedis["Redis\n(Infisical internal)"]
        InfisicalPod --> InfisicalPG
        InfisicalPod --> InfisicalRedis
    end

    subgraph esoNs["external-secrets namespace"]
        ESOPod["ESO operator"]
        CSS["ClusterSecretStore: infisical"]
    end

    subgraph argocdNs["argocd namespace"]
        ArgoServer["argocd-server\nNodePort :30080"]
        ArgoController["application-controller"]
        ArgoRepo["repo-server"]
    end

    subgraph monNs["monitoring namespace"]
        GrafanaPod["Grafana\nNodePort :30090"]
        PromPod["Prometheus\n60s scrape interval"]
        TrivyPod["Trivy Operator\n(ClientServer mode)\nDaily scheduled scans"]
        GrafanaPod --> PromPod
    end

    subgraph authentikNs["authentik namespace"]
        AuthentikPod["Authentik SSO\nNodePort :30500"]
        AuthentikPG["PostgreSQL\n(Authentik internal)"]
        AuthentikPod --> AuthentikPG
    end

    subgraph openclawNs["openclaw namespace"]
        OpenClawPod["OpenClaw Gateway\nNodePort :30789"]
    end

    subgraph trivyDashNs["trivy-dashboard namespace"]
        TrivyDashPod["Trivy Dashboard\nNodePort :30448"]
    end

    AuthentikPod -. "OIDC" .-> GrafanaPod
    AuthentikPod -. "OIDC" .-> ArgoServer
    ESOPod --> CSS
    CSS -- "Universal Auth" --> InfisicalPod
    CSS -- "ExternalSecret" --> OpenClawPod
    OpenClawPod -- "primary" --> OpenRouterAPI["OpenRouter\nstepfun/step-3.5-flash:free"]
    OpenClawPod -. "fallback" .-> GeminiAPI["Google Gemini\ngemini-2.5-pro"]
    ArgoController -- "poll git" --> GitHub["GitHub\nholdennguyen/homelab"]
```

## Networking

Services are exposed through **Tailscale Serve**, which provides automatic TLS certificates and makes services accessible from any device on the tailnet. OrbStack NodePorts only bind to `localhost`, and Tailscale Serve bridges the gap.

| Service | NodePort | Tailscale URL | Tailscale Port | Auth |
|---|---|---|---|---|
| Authentik (SSO) | `:30500` | `https://holdens-mac-mini.story-larch.ts.net` | 443 (default) | SSO portal |
| ArgoCD | `:30080` (HTTP) | `https://holdens-mac-mini.story-larch.ts.net:8443` | 8443 | SSO via Authentik |
| Grafana | `:30090` | `https://holdens-mac-mini.story-larch.ts.net:8444` | 8444 | SSO via Authentik |
| Infisical | `:30445` | `https://holdens-mac-mini.story-larch.ts.net:8445` | 8445 | Local admin |
| OpenClaw | `:30789` | `https://holdens-mac-mini.story-larch.ts.net:8447` | 8447 | Local |
| Trivy Dashboard | `:30448` | `https://holdens-mac-mini.story-larch.ts.net:8448` | 8448 | Bookmark via Authentik |

For the full networking reference, see [docs/networking.md](./networking.md).

## Technology Choices

| Technology | Role | Why |
|---|---|---|
| **OrbStack** | Kubernetes runtime | Lightweight, single-node, Mac-native, fast startup |
| **Terraform** | Bootstrap layer | Tracks cluster setup as code; reproducible; safe credential injection via tfvars |
| **ArgoCD** | GitOps controller | Continuous sync from git; self-healing; declarative; App of Apps for service lifecycle |
| **Infisical** | Secret store | Self-hosted; UI for secret management; supports ESO Universal Auth; project/environment scoping |
| **External Secrets Operator** | Secret sync | Bridges Infisical to Kubernetes Secrets; polling refresh; decoupled from app manifests |
| **Tailscale** | Private networking | Zero-config WireGuard VPN; MagicDNS; auto TLS via `tailscale serve`; works across all devices |
| **OpenRouter** | Model provider | Unified API for Anthropic, OpenAI, Google, Mistral models; single API key; usage-based billing |
| **Kustomize** | Manifest rendering | Native in `kubectl apply -k` and ArgoCD; overlays without templating language |

## Repository Layout

```
homelab/
├── .gitignore                      # Guards terraform.tfvars, .terraform/, *.tfstate
├── .github/workflows/docs.yml     # GitHub Pages deploy on push to main
├── README.md                       # Quick-start and service table
├── mkdocs.yml                      # MkDocs Material site config
├── Dockerfile.openclaw             # Homelab overlay for OpenClaw image (kubectl, helm, git, gh, etc.)
├── terraform/                      # Layer 0 — bootstrap (run once)
│   ├── README.md                   # Terraform variables and day-2 ops reference
│   ├── providers.tf                # kubernetes + helm + local + null providers
│   ├── argocd.tf                   # ArgoCD Helm release, Infisical App, root App
│   ├── bootstrap-secrets.tf        # K8s Secrets created from tfvars
│   ├── variables.tf                # All variable declarations
│   ├── outputs.tf                  # Post-apply instructions
│   └── terraform.tfvars.example   # Template — copy to terraform.tfvars
├── k8s/                            # Layer 1 — GitOps manifests
│   └── apps/
│       ├── argocd/                 # App of Apps: AppProjects + Application CRs
│       │   ├── projects/           # AppProject CRs (secrets, data, apps)
│       │   └── applications/       # Application CRs
│       ├── authentik/              # Authentik SSO ExternalSecret
│       ├── external-secrets/       # ClusterSecretStore
│       ├── infisical/              # (Helm chart managed by Terraform-created Application)
│       ├── monitoring/             # Grafana ExternalSecret
│       ├── openclaw/               # OpenClaw AI gateway manifests
│       ├── trivy-operator/         # Trivy vulnerability scanner (README only; deployed via Helm)
│       ├── trivy-dashboard/       # Trivy Operator Dashboard web UI
│       ├── namespace-security/     # Pod Security Standard labels for namespaces
│       └── networking-policies/    # Default-deny NetworkPolicies for all namespaces
├── docs/                           # MkDocs documentation site
│   ├── architecture.md             # This file
│   ├── bootstrap.md                # Day-1 setup walkthrough
│   ├── networking.md               # Tailscale + NodePort deep-dive
│   ├── secret-management.md       # Infisical + ESO reference
│   ├── argocd.md                   # ArgoCD (includes k8s/apps/argocd/README.md)
│   ├── authentik.md                # Authentik SSO and OIDC integration
│   ├── external-secrets.md         # ESO (includes k8s/apps/external-secrets/README.md)
│   ├── infisical.md                # Infisical (includes k8s/apps/infisical/README.md)
│   ├── monitoring.md               # Grafana + Prometheus monitoring stack
│   ├── openclaw.md                 # OpenClaw AI gateway
│   └── ai-agents.md               # Cursor rules + OpenClaw agents/skills
├── agents/workspaces/              # OpenClaw agent AGENTS.md personality files
├── skills/                         # Homelab-specific OpenClaw skills
├── openclaw/                       # OpenClaw source (git submodule)
└── scripts/                        # Helper scripts (image builds, etc.)
```

## Security

The homelab implements defense-in-depth across network isolation (Tailscale-only, default-deny NetworkPolicies), workload hardening (Pod Security Standards, non-root containers, least-privilege RBAC), and secret hygiene (Infisical pipeline, never in git). A dedicated section covers LLM/AI agent (OpenClaw) permissions including RBAC scope, secret access, and agent workflow guardrails.

For the full security report — including per-namespace PSS compliance, RBAC inventory, container security audit, supply chain controls, OpenClaw agent permissions detail, vulnerability scanning, and the hardening roadmap — see [docs/security.md](./security.md).
