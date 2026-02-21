# Infisical

Self-hosted secret management platform. Every application credential in this homelab — database passwords, signing keys, admin passwords, API tokens — is stored in Infisical and pulled into the cluster by the External Secrets Operator.

## What Infisical Does

```mermaid
flowchart LR
    subgraph infisical["Infisical (infisical namespace)"]
        UI["Web UI\n:8445 via Tailscale"]
        API["REST API\n:8080 cluster-internal"]
        PG["PostgreSQL\n(bundled, infisical-internal)"]
        Redis["Redis\n(bundled, infisical-internal)"]
        UI --> API
        API --> PG
        API --> Redis
    end

    subgraph consumers["Secret Consumers"]
        ESO["External Secrets Operator\nMachine Identity auth"]
        Dev["Developer / Admin\nbrowser login"]
    end

    ESO -- "GET /api/v3/secrets/raw\nhomelab / prod" --> API
    Dev -- "HTTPS :8445" --> UI
```

Infisical is the **single source of truth** for all secrets. No secret values live in git. Applications access secrets indirectly through Kubernetes `Secret` objects that ESO keeps in sync with Infisical.

## Security

Infisical runs as a non-root user by default. The Docker image sets `USER 1001` (non-root-user), so the container process runs as `uid=1001(non-root-user) gid=1001(nodejs)` without any Kubernetes `securityContext` override.

**Note:** The `infisical-standalone` Helm chart does not expose pod-level or container-level `securityContext` configuration. The non-root execution relies entirely on the image's `USER` directive. If a future image version changes this default, there is no Helm-level safeguard to enforce non-root.

The `pod-security.kubernetes.io/enforce: restricted` label is **not** applied to the `infisical` namespace because the ingress-nginx controller sidecar requires capabilities not permitted under the restricted profile.

## How It Is Deployed

Infisical is **not** managed by a git-tracked ArgoCD Application CR. Its Helm values contain sensitive credentials (PostgreSQL and Redis passwords) that cannot be committed to git. Instead:

```mermaid
flowchart TD
    TFVars["terraform/terraform.tfvars\n(gitignored, local only)"]

    subgraph terraform["terraform apply (run once)"]
        NS["kubernetes_namespace: infisical"]
        S1["kubernetes_secret: infisical-secrets\nENCRYPTION_KEY + AUTH_SECRET"]
        S2["kubernetes_secret: infisical-helm-secrets\npostgres + redis passwords"]
        APP["null_resource: infisical Application CR\nHelm values with passwords embedded"]
    end

    subgraph argocd["ArgoCD"]
        InfisicalApp["Application: infisical\n(created by Terraform, not git)"]
    end

    subgraph infisicalNs["infisical namespace"]
        Pod["Infisical Pod"]
        PGPod["PostgreSQL Pod"]
        RedisPod["Redis Pod"]
    end

    TFVars --> terraform
    NS --> S1
    NS --> APP
    APP --> InfisicalApp
    InfisicalApp -- "Helm chart v1.7.2\ninfisical-standalone" --> Pod
    S1 -- "kubeSecretRef" --> Pod
    S2 -- "valuesObject passwords" --> PGPod
    S2 -- "valuesObject passwords" --> RedisPod
    Pod --> PGPod
    Pod --> RedisPod
```

The Terraform source of truth is `terraform/argocd.tf`. Any changes to Infisical's Helm configuration (version upgrade, resource limits, etc.) are made there and applied with `terraform apply`.

There is intentionally **no** `k8s/apps/argocd/applications/infisical-app.yaml` — that file would need to embed the DB passwords, which would expose them in git.

## Bootstrap Secrets

These two K8s Secrets are created by Terraform and must exist before Infisical starts:

### `infisical/infisical-secrets`

| Key | Purpose | How to generate |
|---|---|---|
| `ENCRYPTION_KEY` | AES key — Infisical encrypts every stored secret at rest with this | `openssl rand -hex 16` (must be exactly 32 hex chars) |
| `AUTH_SECRET` | JWT signing secret — used to sign user session tokens | `openssl rand -base64 32` |

**Critical:** `ENCRYPTION_KEY` must never change once Infisical has stored secrets. Changing it without running a migration makes all stored secrets permanently unreadable.

### `argocd/infisical-helm-secrets`

Contains a `values.yaml` blob injected via `helm.valuesObject` in the Terraform-managed Application CR:

| Helm path | K8s secret key | Purpose |
|---|---|---|
| `postgresql.auth.password` | extracted from `values.yaml` | Password for Infisical's internal PostgreSQL |
| `redis.auth.password` | extracted from `values.yaml` | Password for Infisical's internal Redis |

Both are generated with `openssl rand -hex 12` and stored in `terraform/terraform.tfvars`.

## Project and Environment Structure

```mermaid
flowchart TD
    subgraph org["Infisical Organization"]
        subgraph project["Project: homelab\nslug: homelab"]
            subgraph prod["Environment: prod"]
                subgraph root["Path: /  (root)"]
                    s9["AUTHENTIK_SECRET_KEY"]
                    s10["AUTHENTIK_BOOTSTRAP_PASSWORD"]
                    s11["AUTHENTIK_BOOTSTRAP_TOKEN"]
                    s12["AUTHENTIK_POSTGRES_PASSWORD"]
                    s13["GRAFANA_ADMIN_PASSWORD"]
                    s14["GRAFANA_OAUTH_CLIENT_SECRET"]
                    s16["OPENCLAW_GATEWAY_TOKEN"]
                    s17["OPENROUTER_API_KEY"]
                    s17b["GEMINI_API_KEY"]
                    s18["GITHUB_TOKEN"]
                end
            end
        end
        subgraph identities["Machine Identities"]
            MI["homelab-eso\nUniversal Auth\nMember role on homelab project"]
        end
    end
```

## Complete Secrets Inventory

### SSO & Monitoring Credentials

| Key | Used By | Value Constraints | How to Generate |
|---|---|---|---|
| `AUTHENTIK_SECRET_KEY` | Authentik ExternalSecret | Never change after first install | `openssl rand -hex 32` |
| `AUTHENTIK_BOOTSTRAP_PASSWORD` | Authentik ExternalSecret | Admin login password | Choose a strong password |
| `AUTHENTIK_BOOTSTRAP_TOKEN` | Authentik ExternalSecret | API automation token | `openssl rand -hex 32` |
| `AUTHENTIK_POSTGRES_PASSWORD` | Authentik ExternalSecret | Authentik internal PostgreSQL | `openssl rand -hex 12` |
| `GRAFANA_ADMIN_PASSWORD` | Grafana ExternalSecret | Break-glass admin access | `openssl rand -hex 12` |
| `GRAFANA_OAUTH_CLIENT_SECRET` | Grafana ExternalSecret | OIDC client secret for Authentik | Generated when creating Authentik provider |
### AI Gateway Credentials

| Key | Used By | Value Constraints | How to Generate |
|---|---|---|---|
| `OPENCLAW_GATEWAY_TOKEN` | OpenClaw ExternalSecret | Any hex string | `openssl rand -hex 32` |
| `OPENROUTER_API_KEY` | OpenClaw ExternalSecret | Valid OpenRouter API key | From [openrouter.ai/keys](https://openrouter.ai/keys) |
| `GEMINI_API_KEY` | OpenClaw ExternalSecret | Valid Google Gemini API key | From [aistudio.google.com/apikey](https://aistudio.google.com/apikey) |
| `GITHUB_TOKEN` | OpenClaw ExternalSecret | GitHub PAT with repo scope | Fine-grained PAT for `holdennguyen/homelab` |

> **ArgoCD OIDC client secret** is managed via Terraform (`argocd_oidc_client_secret` in tfvars), not by ESO. It is injected into `argocd-secret` via the `set_sensitive` Helm value in `terraform/argocd.tf`.

## First-Time Setup Walkthrough

This is done once after `terraform apply` deploys Infisical.

```mermaid
flowchart TD
    A["1. Open https://holdens-mac-mini.story-larch.ts.net:8445"] --> B
    B["2. Create admin account\n(signup form on first visit)"] --> C
    C["3. Create project named 'homelab'\nverify slug = 'homelab'"] --> D
    D["4. Add all secrets in homelab/prod/\n(see inventory table)"] --> E
    E["5. Create Machine Identity 'homelab-eso'\nUniversal Auth"] --> F
    F["6. Add homelab-eso to homelab project\nRole: Member"] --> G
    G["7. Copy clientId + clientSecret\nto terraform.tfvars"] --> H
    H["8. terraform apply\n(updates infisical-machine-identity secret)"] --> I
    I["9. ESO connects to Infisical\nClusterSecretStore becomes Valid"] --> J
    J["All K8s Secrets synced\nAll pods healthy"]
```

### Step 1 — First Login

Open `https://holdens-mac-mini.story-larch.ts.net:8445`. On first visit, Infisical shows a registration screen. Create an admin account. This is the superadmin of the Infisical instance.

### Step 2 — Create the `homelab` Project

1. Click **New Project** → name it `homelab`
2. Verify the slug: **Project Settings → General** must show `Slug: homelab`

The slug is hardcoded in `k8s/apps/external-secrets/cluster-secret-store.yaml`. If you use a different slug, update both files.

### Step 3 — Add Secrets

Navigate to `homelab` project → `prod` environment → click the **+** to add secrets. Add every key in the secrets inventory table above. Pay special attention to:
- `AUTHENTIK_SECRET_KEY` must never be changed after first install

### Step 4 — Create Machine Identity

1. Top-left dropdown → **Organization Settings → Machine Identities → Create**
2. Name: `homelab-eso`, Auth method: **Universal Auth**, click **Create**
3. A `clientId` and `clientSecret` are shown — copy them immediately (secret is not shown again)

### Step 5 — Grant Project Access

1. Open the `homelab` project → **Access Control → Machine Identities → Add Identity**
2. Select `homelab-eso` → Role: **Member** → **Add**

Without this step, ESO gets a 403 when trying to read secrets.

### Step 6 — Update Terraform and Apply

```bash
# Edit terraform/terraform.tfvars:
infisical_machine_identity_client_id     = "<clientId>"
infisical_machine_identity_client_secret = "<clientSecret>"

cd terraform && terraform apply
```

Terraform updates only the `infisical-machine-identity` K8s Secret. ESO picks it up within ~30 seconds.

## Accessing the UI

| Method | URL | Notes |
|---|---|---|
| Tailscale (any device) | `https://holdens-mac-mini.story-larch.ts.net:8445` | Requires Tailscale |
| Local (Mac mini only) | `http://localhost:30445` | Direct NodePort access |

If Tailscale Serve is not yet configured:

```bash
tailscale serve --bg --https 8445 http://localhost:30445
```

## Networking

```mermaid
flowchart LR
    subgraph tailnet["Tailscale Network"]
        Device["Browser\nhttps://*.story-larch.ts.net:8445"]
    end

    subgraph mac["Mac mini"]
        TS["tailscale serve\n:8445 → localhost:30445"]
        subgraph k8s["Kubernetes"]
            SVC["infisical Service\nNodePort :30445"]
            POD["Infisical Pod\n:8080"]
            SVC --> POD
        end
        TS --> SVC
    end

    subgraph esoNs["external-secrets namespace"]
        ESO["ESO Controller"]
        CSS["ClusterSecretStore\nhttp://infisical-infisical-standalone-infisical\n.infisical.svc.cluster.local:8080"]
    end

    Device --> TS
    ESO --> CSS --> POD
```

| Layer | Value |
|---|---|
| Container port | `:8080` |
| Kubernetes NodePort | `:30445` |
| Tailscale Serve upstream | `http://localhost:30445` |
| Tailscale URL | `https://holdens-mac-mini.story-larch.ts.net:8445` |
| Internal cluster DNS | `infisical-infisical-standalone-infisical.infisical.svc.cluster.local:8080` |

The internal DNS name is what the `ClusterSecretStore` uses to reach Infisical — no external network hop, no Tailscale, no NodePort.

## Day-2 Operations

### Adding a New Application Secret

1. Open the Infisical UI → `homelab / prod` → add the new key (e.g. `MY_APP_API_KEY`)
2. Create `k8s/apps/my-app/external-secret.yaml`:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: my-app-secret
  namespace: my-app
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: infisical
    kind: ClusterSecretStore
  target:
    name: my-app-secret
    creationPolicy: Owner
  data:
    - secretKey: API_KEY
      remoteRef:
        key: MY_APP_API_KEY
```

3. Add it to `k8s/apps/my-app/kustomization.yaml`, push to git.

### Rotating the Machine Identity

```mermaid
sequenceDiagram
    participant Admin
    participant InfisicalUI as Infisical UI
    participant TFVars as terraform.tfvars
    participant TF as terraform apply
    participant K8s as infisical-machine-identity Secret
    participant ESO as ESO Controller

    Admin->>InfisicalUI: Generate new credentials\nfor homelab-eso
    InfisicalUI-->>Admin: New clientId + clientSecret
    Admin->>TFVars: Update credentials
    Admin->>TF: terraform apply
    TF->>K8s: Update secret data
    ESO->>K8s: Detects change (~30s)
    ESO->>InfisicalUI: Re-authenticates with new credentials
```

```bash
# After updating terraform.tfvars:
cd terraform && terraform apply

# Verify ESO reconnected:
kubectl get clustersecretstore infisical
# Should show: Ready: True
```

### Rotating `ENCRYPTION_KEY` (Emergency Only)

> **This is destructive.** Only do this if the key is compromised. You must re-encrypt all stored secrets.

1. Read the [Infisical key rotation guide](https://infisical.com/docs/self-hosting/configuration/envars) first
2. Export all secrets from the Infisical UI before proceeding
3. Update `infisical_encryption_key` in `terraform/terraform.tfvars`
4. `terraform apply`
5. Restart Infisical: `kubectl rollout restart deployment -n infisical -l app.kubernetes.io/component=infisical`
6. Re-import secrets

### Upgrading the Infisical Helm Chart

1. Check available versions: `helm search repo infisical/infisical-standalone --versions`
2. Update `targetRevision` in `terraform/argocd.tf`:
   ```hcl
   locals {
     infisical_app_yaml = yamlencode({
       ...
       source = {
         targetRevision = "1.8.0"  # <-- update here
   ```
3. `terraform apply`
4. ArgoCD detects the change and upgrades the Helm release

### Backing Up Infisical Data

Infisical stores all data in its bundled PostgreSQL. To back up:

```bash
# Export all secrets from UI (recommended for disaster recovery)
# Infisical UI → homelab project → Export Secrets → JSON or CSV

# Or pg_dump from the pod
kubectl exec -n infisical postgresql-0 -- \
  pg_dump -U infisical infisicalDB > infisical-backup-$(date +%Y%m%d).sql
```

## Operational Commands

```bash
# Check Infisical pod status
kubectl get pods -n infisical

# View Infisical application logs
kubectl logs -n infisical -l app.kubernetes.io/component=infisical --tail=50

# View PostgreSQL logs
kubectl logs -n infisical -l app.kubernetes.io/instance=infisical-standalone,app.kubernetes.io/name=postgresql --tail=30

# Check the bootstrap secret is present and has the right keys
kubectl get secret infisical-secrets -n infisical -o jsonpath='{.data}' | python3 -c "import sys,json,base64; d=json.load(sys.stdin); [print(k,'=',base64.b64decode(v).decode()[:8]+'...') for k,v in d.items()]"

# Restart Infisical (e.g. after credential rotation)
kubectl rollout restart deployment -n infisical -l app.kubernetes.io/component=infisical

# Port-forward for local access without Tailscale
kubectl port-forward -n infisical svc/infisical-infisical-standalone-infisical 8080:8080
# Then open http://localhost:8080
```

## Troubleshooting

```mermaid
flowchart TD
    Start["Problem with secrets not syncing"]
    A["kubectl get clustersecretstore infisical"]
    Start --> A
    A --> B{"Ready?"}
    B -- "No — 401 Unauthorized" --> C["Machine identity credentials wrong\nUpdate terraform.tfvars + terraform apply"]
    B -- "No — 403 Forbidden" --> D["homelab-eso not added to homelab project\nInfisical UI → Project → Access Control → Machine Identities → Add"]
    B -- "No — 404 Project not found" --> E["Project slug wrong\nVerify slug in Infisical UI Settings = 'homelab'"]
    B -- "No — connection refused" --> F["Infisical pod not running\nkubectl get pods -n infisical"]
    B -- "Yes — Ready: True" --> G["kubectl get externalsecret -A"]
    G --> H{"ExternalSecret status?"}
    H -- "SecretSyncedError" --> I["Force refresh:\nkubectl annotate externalsecret <name> -n <ns>\n  force-sync=$(date +%s) --overwrite"]
    H -- "SecretSynced: True" --> J["Secrets are fine\nCheck the pod consuming them"]
```

| Symptom | Cause | Fix |
|---|---|---|
| `CrashLoopBackOff` on first start | PostgreSQL not ready when Infisical starts DB migration | Wait — Kubernetes retries automatically. Usually resolves within 2–3 minutes |
| `Error: ENCRYPTION_KEY must be 32 hex characters` | Wrong format for `ENCRYPTION_KEY` | Regenerate: `openssl rand -hex 16` — output must be exactly 32 characters |
| `Error: invalid AUTH_SECRET` | `AUTH_SECRET` missing or malformed in `infisical-secrets` | `kubectl describe secret infisical-secrets -n infisical` — verify keys exist |
| `ClusterSecretStore` 401 | Machine identity credentials are wrong or placeholder values | Update `terraform.tfvars` and `terraform apply` |
| `ClusterSecretStore` 403 | Machine identity not added to `homelab` project | Infisical UI → Project → Access Control → Machine Identities → Add Identity |
| `ClusterSecretStore` 404 project not found | `projectSlug` doesn't match Infisical project | Infisical UI → Project Settings → confirm Slug field is exactly `homelab` |
| UI shows "Invalid login" | Wrong admin password | Use the Infisical admin password you set during initial signup (not an application password) |
| ESO can read secrets but wrong values | Secret updated in Infisical but ESO cache not refreshed | `kubectl annotate externalsecret <name> -n <ns> force-sync=$(date +%s) --overwrite` |
| Infisical UI inaccessible from Tailscale | `tailscale serve` not configured for :8445 | `tailscale serve --bg --https 8445 http://localhost:30445` |
