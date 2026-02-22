---
name: homelab-admin
description: Manage the homelab Kubernetes cluster, GitOps workflows, and infrastructure services. Use for kubectl operations, ArgoCD sync, Tailscale networking, and general homelab administration.
metadata:
  {
    "openclaw":
      {
        "emoji": "🏠",
        "requires": { "anyBins": ["kubectl"] },
      },
  }
---

# Homelab Admin

Orchestrate and manage the homelab Kubernetes cluster running on OrbStack (Mac mini M4). This skill covers day-to-day operations across all deployed services.

## Cluster overview

- **Host:** Mac mini M4, macOS, arm64
- **Runtime:** OrbStack Kubernetes (single-node), Kubernetes v1.33, node name `orbstack`
- **GitOps:** ArgoCD (App of Apps pattern) syncs from `github.com/holdennguyen/homelab`, branch `main`, path `k8s/apps/`
- **Secrets:** Infisical → External Secrets Operator → K8s Secrets (never in git)
- **Networking:** NodePort (localhost only) + Tailscale Serve (auto TLS via Let's Encrypt)
- **Manifests:** Kustomize for app workloads; Helm only for upstream charts (ESO, Infisical)
- **Storage:** `local-path` provisioner (OrbStack default)
- **Container image:** OpenClaw runs a custom image (`openclaw:latest`) built with `Dockerfile.openclaw`, which includes kubectl, helm, terraform, argocd, jq, git, gh
- **Pod RBAC:** This pod's ServiceAccount has a namespace-scoped Role in `openclaw` with read-only access to pods, logs, secrets, configmaps, services, PVCs, and exec into pods. It does NOT have cluster-wide access.

## Tailscale network

The Mac mini's Tailscale hostname is `holdens-mac-mini` on the tailnet `story-larch.ts.net`. All services are accessible via HTTPS with auto-provisioned Let's Encrypt certificates.

Discover current endpoints and devices dynamically:

```bash
# Current Tailscale serve endpoints
tailscale serve status

# Tailnet devices
tailscale status

# All NodePort services
kubectl get svc -A -o jsonpath='{range .items[?(@.spec.type=="NodePort")]}{.metadata.namespace}/{.metadata.name}: {.spec.ports[*].nodePort}{"\n"}{end}'
```

For the canonical endpoint table, see `docs/networking.md`.

## Cluster inventory

Discover the current state of the cluster dynamically rather than relying on stale snapshots:

```bash
# Namespaces and pods
kubectl get pods -A

# ArgoCD applications and their sync status
kubectl get applications -n argocd

# PVCs
kubectl get pvc -A

# ExternalSecrets
kubectl get externalsecret -A
```

### ArgoCD projects

| Project | Purpose |
|---|---|
| `secrets` | Secret management infra (ESO, Infisical) |
| `data` | Databases and persistent stores |
| `apps` | User-facing applications and cluster-wide policies |

For the full service inventory, see `k8s/apps/argocd/README.md` and the root `README.md`.

## Delegation decision framework

As homelab admin, you handle most tasks directly. Only delegate when deep specialist expertise genuinely adds value.

| Signal | Handle yourself | Delegate |
|---|---|---|
| **Scope** | Status checks, manifest edits, config changes, service deployments, secret management, GitOps workflow | Deep domain work requiring extended specialist focus |
| **Expertise** | General admin, k8s operations, ArgoCD, networking, routine RBAC, incident response | Full security audits, complex code development, comprehensive test suites |
| **Complexity** | Single-service or multi-file changes, routine operations, standard troubleshooting | Multi-day investigations, cross-cutting refactors needing dedicated attention |

**Agent selection (delegate only when specialist depth is needed):**

| Task type | Agent | Examples |
|---|---|---|
| Complex Terraform refactoring, monitoring pipeline design | `devops-sre` | Multi-resource Terraform migrations, Prometheus recording rules |
| Non-trivial code development | `software-engineer` | OpenClaw source changes, new scripts, Dockerfile rewrites |
| Full security audits, vulnerability assessments | `security-analyst` | Cluster-wide RBAC audit, CVE response plan, compliance review |
| Comprehensive test campaigns | `qa-tester` | Multi-service regression suites, post-migration validation |

Default: handle it yourself. Delegate only when specialist depth genuinely adds value.

## Change impact assessment

Before making or approving any change, assess its blast radius:

| Impact level | Criteria | Required actions |
|---|---|---|
| **Low** | Single service, no shared resources, non-breaking | Execute directly, standard PR review |
| **Medium** | Shared secrets, cross-namespace deps, port changes | Execute directly, verify downstream consumers after apply |
| **High** | Multi-service impact, resource tuning across namespaces | Execute directly with documented rollback plan in the PR |
| **Critical** | See critical risk classification below | **MUST** follow the critical risk protocol — confirmation required |

### Critical risk classification

An action is **critical risk** if it matches ANY of these criteria:

| Category | Examples |
|---|---|
| **Data destruction** | Deleting PVCs, PVs, StatefulSets with persistent data, dropping databases |
| **Security exposure** | Modifying RBAC (Roles, ClusterRoles, bindings), changing network policies, disabling authentication, exposing new services externally |
| **Cluster-wide blast radius** | Terraform apply, ArgoCD AppProject permission changes, ClusterSecretStore modifications, namespace deletion |
| **Secret operations** | Deleting secrets from Infisical, rotating secrets for multiple services simultaneously, modifying the ESO ClusterSecretStore |
| **Irreversible changes** | Force-pushing branches, deleting git tags/releases, purging ArgoCD application history |
| **Service disruption** | Scaling critical services to 0, changing NodePort numbers on active Tailscale endpoints, modifying ArgoCD sync policies (disabling selfHeal/prune) |

### Critical risk protocol

Before executing any critical-risk action, you MUST:

1. **Classify** — state that the action is critical risk and which category applies
2. **Detail** — present to the user:
   - What exactly will be changed
   - Why the change is needed
   - Blast radius (affected services/namespaces)
   - Rollback plan (how to undo)
3. **Confirm** — request explicit user confirmation using this format:

   > **⚠ Critical Risk — [category]**
   >
   > **Action:** [what will be done]
   > **Blast radius:** [affected services/namespaces]
   > **Rollback:** [how to undo]
   >
   > Proceed? (yes/no)

4. **Execute** — only after the user explicitly confirms
5. **Verify** — confirm success and check for collateral damage

When in doubt about risk level, classify as critical. Over-confirming is safer than causing an outage.

## Common operations

```bash
# Cluster health overview
kubectl get nodes
kubectl get pods -A
kubectl top nodes
kubectl top pods -A

# ArgoCD application status
kubectl get applications -n argocd

# Force ArgoCD hard refresh
kubectl annotate application <app-name> -n argocd argocd.argoproj.io/refresh=hard --overwrite

# Check ExternalSecrets cluster-wide
kubectl get externalsecret -A

# Force secret re-sync
kubectl annotate externalsecret <name> -n <ns> force-sync=$(date +%s) --overwrite

# View logs
kubectl logs -n <namespace> deploy/<name> --tail=100

# Restart a deployment
kubectl rollout restart deployment/<name> -n <namespace>

# Check events (sorted by time)
kubectl get events -A --sort-by='.metadata.creationTimestamp' | tail -20
```

## GitOps workflow

All changes follow: edit manifests in `k8s/apps/` → commit → push to `main` → ArgoCD syncs within ~3 minutes. ArgoCD has `selfHeal: true` and `prune: true` on all apps, so manual `kubectl apply` changes are reverted automatically.

The repo structure:
- `terraform/` — Layer 0 bootstrap (ArgoCD Helm release, bootstrap secrets, Infisical App CR)
- `k8s/apps/` — Layer 1 GitOps manifests (one directory per service)
- `k8s/apps/argocd/` — App of Apps: AppProjects + Application CRs
- `skills/` — OpenClaw skills (mounted at `/skills` in this pod)
- `agents/workspaces/` — Agent AGENTS.md personalities (copied into pod by init container)
- `docs/` — MkDocs documentation site (auto-deploys to GitHub Pages on push)

## Adding a new service

1. Create `k8s/apps/<service>/` with manifests and `kustomization.yaml`
2. Create `k8s/apps/argocd/applications/<service>-app.yaml` (assign to correct project, include standard labels)
3. Add to `k8s/apps/argocd/kustomization.yaml`
4. If the service needs secrets: add to Infisical, create ExternalSecret, reference in deployment
5. If the service needs a Tailscale endpoint: `tailscale serve --bg --https <port> http://localhost:<nodeport>`
6. Update root `README.md` — architecture diagram, repository structure, deployed services table, documentation index
7. Push to `main`

## Adding secrets for a service

1. Add secret to Infisical under `homelab / prod`
2. Create `ExternalSecret` resource in the service's k8s directory
3. Reference the created K8s Secret in the Deployment env vars
4. Push to `main`

## Tailscale Serve management

```bash
# Check current serve status
tailscale serve status

# Add a new HTTPS service
tailscale serve --bg --https <port> http://localhost:<nodeport>

# Remove a service
tailscale serve --https=<port> off

# Check tailnet devices
tailscale status
```

Note: `tailscale serve` runs on the host, not inside this pod. These commands are for reference when advising the user.

## OpenClaw image rebuild

When the OpenClaw submodule is updated or `Dockerfile.openclaw` is changed:

```bash
./scripts/build-openclaw.sh
kubectl rollout restart deployment/openclaw -n openclaw
```

## Troubleshooting

| Symptom | Check | Fix |
|---|---|---|
| Pod CrashLoopBackOff | `kubectl logs <pod> -n <ns> --previous` | Fix config/secrets, restart |
| App stuck OutOfSync | `kubectl get application <app> -n argocd -o yaml` | Hard refresh or check repo access |
| ExternalSecret SecretSyncedError | `kubectl describe externalsecret <name> -n <ns>` | Verify key exists in Infisical |
| Service unreachable via Tailscale | `tailscale serve status` | Re-add the serve rule on the host |
| Node not ready | `kubectl describe node orbstack` | Check OrbStack is running |
| ArgoCD can't clone repo | `git ls-remote https://github.com/holdennguyen/homelab.git` | Verify HTTPS URL is reachable |
