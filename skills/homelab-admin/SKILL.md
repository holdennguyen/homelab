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

**Tailscale IP:** `100.77.144.4`

### Service endpoints

| Service | Tailscale URL | NodePort | Proxy target |
|---|---|---|---|
| Authentik (SSO) | `https://holdens-mac-mini.story-larch.ts.net` | 30500 | `http://localhost:30500` |
| ArgoCD | `https://holdens-mac-mini.story-larch.ts.net:8443` | 30080 | `http://localhost:30080` |
| Grafana | `https://holdens-mac-mini.story-larch.ts.net:8444` | 30090 | `http://localhost:30090` |
| Infisical | `https://holdens-mac-mini.story-larch.ts.net:8445` | 30445 | `http://localhost:30445` |
| Gitea | `https://holdens-mac-mini.story-larch.ts.net:8446` | 30300 | `http://localhost:30300` |
| Gitea SSH | N/A (TCP) | 30022 | SSH |
| OpenClaw | `https://holdens-mac-mini.story-larch.ts.net:8447` | 30789 | `http://localhost:30789` |

### Tailnet devices

| Device | IP | OS |
|---|---|---|
| holdens-mac-mini | 100.77.144.4 | macOS |
| iphone-12-pro-max | 100.67.153.52 | iOS |
| ipad-mini-gen-5 | 100.121.193.73 | iOS |

## Namespaces

| Namespace | Services |
|---|---|
| `argocd` | ArgoCD server, repo-server, application-controller, redis, dex, notifications |
| `external-secrets` | ESO operator, cert-controller, webhook |
| `gitea-system` | Gitea, PostgreSQL (Gitea's DB) |
| `infisical` | Infisical standalone, PostgreSQL, Redis, ingress-nginx |
| `monitoring` | Prometheus, Grafana, Alertmanager, node-exporter, kube-state-metrics, Trivy Operator, trivy-server |
| `openclaw` | OpenClaw gateway (this pod) |

## ArgoCD applications

| Application | Project | Description |
|---|---|---|
| `argocd-apps` | `default` | Root App of Apps — syncs all other Application CRs |
| `external-secrets` | `secrets` | ESO Helm chart (installs CRDs) — sync wave 0 |
| `external-secrets-config` | `secrets` | ClusterSecretStore for Infisical — sync wave 1 |
| `infisical` | `secrets` | Infisical secret manager (managed by Terraform, not App of Apps) |
| `authentik` | `apps` | Authentik SSO (Helm chart) |
| `authentik-config` | `apps` | Authentik ExternalSecret and config |
| `gitea` | `apps` | Gitea git forge |
| `monitoring` | `apps` | kube-prometheus-stack (Prometheus + Grafana + Alertmanager) |
| `monitoring-config` | `apps` | Monitoring ExternalSecret and config |
| `trivy-operator` | `apps` | Container image vulnerability scanning (ClientServer mode) |
| `namespace-security` | `apps` | Pod Security Standard labels per namespace |
| `networking-policies` | `apps` | Default-deny NetworkPolicy per namespace |
| `openclaw` | `apps` | OpenClaw AI gateway (this service) |
| `postgresql` | `data` | PostgreSQL for Gitea |

### ArgoCD projects

| Project | Purpose | Namespaces |
|---|---|---|
| `secrets` | Secret management infra (ESO, Infisical) | `external-secrets`, `infisical` |
| `data` | Databases and persistent stores | `gitea-system` |
| `apps` | User-facing applications | `gitea-system`, `authentik`, `monitoring`, `openclaw`, `argocd` (for cluster-wide policies) |

## Persistent volumes

| PVC | Namespace | Size | Purpose |
|---|---|---|---|
| `gitea-data` | `gitea-system` | 10Gi | Gitea repositories and data |
| `postgresql-data` | `gitea-system` | 5Gi | Gitea's PostgreSQL data |
| `data-postgresql-0` | `infisical` | 8Gi | Infisical's PostgreSQL data |
| `redis-data-redis-master-0` | `infisical` | 8Gi | Infisical's Redis data |
| `openclaw-data` | `openclaw` | 5Gi | OpenClaw state, workspaces, sessions |
| `data-trivy-server-0` | `monitoring` | 5Gi | Trivy vulnerability DB cache (ClientServer mode) |

## ExternalSecrets

| ExternalSecret | Namespace | Keys | Status |
|---|---|---|---|
| `postgresql-secret` | `gitea-system` | POSTGRES_PASSWORD, POSTGRES_USER, POSTGRES_DB, GITEA_DB_PASSWORD | SecretSynced |
| `gitea-secret` | `gitea-system` | GITEA_SECRET_KEY | SecretSynced |
| `gitea-admin-secret` | `gitea-system` | GITEA_ADMIN_USERNAME, GITEA_ADMIN_PASSWORD, GITEA_ADMIN_EMAIL | SecretSynced |
| `openclaw-secret` | `openclaw` | OPENCLAW_GATEWAY_TOKEN, OPENROUTER_API_KEY, GEMINI_API_KEY, GITHUB_TOKEN | SecretSynced |

All secrets are stored in Infisical under `homelab / prod` and synced via the `infisical` ClusterSecretStore using Universal Auth.

## Delegation decision framework

Use this matrix to decide whether to handle a task yourself or delegate to a sub-agent:

| Signal | Handle yourself | Delegate |
|---|---|---|
| **Scope** | Read-only status checks, quick lookups | Changes to manifests, code, or config |
| **Expertise** | General cluster health, ArgoCD sync | Deep domain work (security audit, code implementation, incident root cause) |
| **Risk** | Non-destructive, informational | Destructive, security-impacting, or multi-file changes |
| **Duration** | Single command, immediate answer | Multi-step workflow requiring issue → branch → PR |

**Agent selection:**

| Task type | Agent | Examples |
|---|---|---|
| Infrastructure provisioning, Terraform, monitoring, incidents | `devops-sre` | New service manifest, resource tuning, alert rules, outage investigation |
| Code changes, feature development, code review | `software-engineer` | Dockerfile updates, script changes, OpenClaw config code |
| Security audits, hardening, vulnerability response | `security-analyst` | RBAC review, secret rotation audit, image CVE scan |
| Deployment validation, regression testing, health checks | `qa-tester` | Post-deploy smoke tests, cross-service regression check |

When in doubt: delegate. Sub-agents produce auditable PRs; direct changes do not.

## Change impact assessment

Before making or approving any change, assess its blast radius:

| Impact level | Criteria | Required actions |
|---|---|---|
| **Low** | Single service, no shared resources, non-breaking | Standard PR review |
| **Medium** | Shared secrets, cross-namespace deps, port changes | Notify affected service owners, verify downstream consumers |
| **High** | RBAC/security policy, Terraform bootstrap, ArgoCD config, networking | Explicit user approval, rollback plan documented in PR, delegate to `qa-tester` for post-deploy validation |

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
| ArgoCD can't clone repo | `kubectl get secret repo-homelab -n argocd` | Check SSH deploy key |
