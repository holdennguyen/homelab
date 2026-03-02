# Secret Management

This document covers how secrets are managed in the homelab: where they are stored, how they flow into running pods, how to add secrets for new services, and how to rotate credentials.

## Design Principles

1. **No secrets in git** — no `Secret` YAML files are committed. Only `ExternalSecret` resources (which reference secret names, not values) live in git.
2. **Infisical is the single source of truth** — all application credentials live in one place with an audit trail.
3. **Terraform owns bootstrap secrets** — a small set of credentials that Infisical itself needs to start (ENCRYPTION_KEY, AUTH_SECRET, postgres/redis passwords) are injected by Terraform from a local `terraform.tfvars` file that is gitignored.
4. **ESO bridges Infisical to Kubernetes** — the External Secrets Operator watches `ExternalSecret` resources and creates real `Secret` objects in the cluster, polling Infisical every hour.
5. **Least privilege** — both ESO and Infisical run with non-root security contexts and read-only root filesystems where supported by their upstream charts. See each service's `README.md` for security details.

## Secret Layers

```mermaid
flowchart TD
    subgraph git["Git (public, no secrets)"]
        ES["ExternalSecret YAML\n(references key names only)"]
        CSS_yaml["ClusterSecretStore YAML\n(references secret name only)"]
    end

    subgraph tfvars["terraform.tfvars (gitignored, local only)"]
        TFVars["infisical_encryption_key\ninfisical_auth_secret\ninfisical_postgres_password\ninfisical_redis_password\ninfisical_machine_identity_client_id\ninfisical_machine_identity_client_secret\nargocd_oidc_client_secret"]
    end

    subgraph tf["Terraform state"]
        TFState["bootstrap K8s Secrets\n(sensitive, local tfstate only)"]
    end

    subgraph cluster["Kubernetes Cluster"]
        subgraph infisicalNs["infisical namespace"]
            infisical_secrets["infisical-secrets\nENCRYPTION_KEY + AUTH_SECRET"]
        end
        subgraph esoNs["external-secrets namespace"]
            machine_id["infisical-machine-identity\nclientId + clientSecret"]
        end
        subgraph argocdNs["argocd namespace"]
            helm_secrets["infisical-helm-secrets\npostgres + redis passwords"]
        end
        subgraph authentikNs["authentik namespace"]
            authentik_secret["authentik-secret\n(created by ESO)"]
        end
        subgraph monitoringNs["monitoring namespace"]
            grafana_secret["grafana-secret\n(created by ESO)"]
        end
        subgraph openclawNs["openclaw namespace"]
            openclaw_secret["openclaw-secret\n(created by ESO)"]
        end
        subgraph argocdNs2["argocd namespace"]
            argocd_secret["argocd-secret\n(admin.password set by Helm)"]
        end
    end

    subgraph infisical_store["Infisical (project: homelab / env: prod)"]
        AUTHENTIK_SECRETS["AUTHENTIK_SECRET_KEY\nAUTHENTIK_BOOTSTRAP_PASSWORD\nAUTHENTIK_BOOTSTRAP_TOKEN\nAUTHENTIK_POSTGRES_PASSWORD"]
        GRAFANA_SECRETS["GRAFANA_ADMIN_PASSWORD\nGRAFANA_OAUTH_CLIENT_SECRET"]
        OPENCLAW_SECRETS["OPENCLAW_GATEWAY_TOKEN\nOPENROUTER_API_KEY\nGEMINI_API_KEY\nGITHUB_TOKEN\nDISCORD_BOT_TOKEN\nDISCORD_WEBHOOK_DEUTSCH\nDISCORD_WEBHOOK_ENGLISH\nDISCORD_WEBHOOK_ALERTS"]
    end

    TFVars --> TFState
    TFState --> infisical_secrets
    TFState --> machine_id
    TFState --> helm_secrets
    TFVars -- "argocd_oidc_client_secret\n→ Helm value" --> argocd_secret
    CSS_yaml --> machine_id
    machine_id -- "Universal Auth" --> infisical_store
    AUTHENTIK_SECRETS --> authentik_secret
    GRAFANA_SECRETS --> grafana_secret
    OPENCLAW_SECRETS --> openclaw_secret
```

## Bootstrap Secrets (Terraform-Managed)

These secrets are the "chicken-and-egg" exceptions — they cannot come from Infisical because Infisical itself needs them to start. All are created by `terraform apply`, live in `terraform.tfstate` (local only), and are never committed to git.

| K8s Secret | Namespace | Keys | Purpose |
|---|---|---|---|
| `infisical-secrets` | `infisical` | `ENCRYPTION_KEY`, `AUTH_SECRET` | Infisical app encryption and session signing |
| `infisical-helm-secrets` | `argocd` | `values.yaml` (YAML blob) | Postgres + Redis passwords passed to Infisical Helm chart via ArgoCD Application |
| `infisical-machine-identity` | `external-secrets` | `clientId`, `clientSecret` | ESO authenticates to Infisical using this Universal Auth identity |
| `argocd-secret` | `argocd` | `oidc.argocd.clientSecret` | ArgoCD OIDC client secret for Authentik SSO — set via Terraform `set_sensitive` Helm value. **Not** managed by ESO to avoid annotation-propagation conflicts. |

## Infisical Project Structure

```mermaid
flowchart LR
    subgraph infisical["Infisical"]
        subgraph org["Organization"]
            subgraph project["Project: homelab\nslug: homelab"]
                subgraph prod["Environment: prod"]
                    subgraph path["Secret Path: /"]
                        s9["AUTHENTIK_SECRET_KEY"]
                        s10["AUTHENTIK_BOOTSTRAP_PASSWORD"]
                        s11["AUTHENTIK_BOOTSTRAP_TOKEN"]
                        s12["AUTHENTIK_POSTGRES_PASSWORD"]
                        s13["GRAFANA_ADMIN_PASSWORD"]
                        s14["GRAFANA_OAUTH_CLIENT_SECRET"]
                        s16["OPENCLAW_GATEWAY_TOKEN"]
                        s17["OPENROUTER_API_KEY"]
                        s18["GEMINI_API_KEY"]
                        s19["GITHUB_TOKEN"]
                        s20["DISCORD_BOT_TOKEN"]
                        s25["DISCORD_WEBHOOK_DEUTSCH"]
                        s26["DISCORD_WEBHOOK_ENGLISH"]
                        s27["DISCORD_WEBHOOK_ALERTS"]
                    end
                end
            end
            subgraph identities["Machine Identities"]
                MI["homelab-eso\nUniversal Auth"]
            end
        end
    end

    MI -- "Member role\non homelab project" --> project
```

> **ArgoCD OIDC client secret** is the only secret managed via Terraform instead of ESO (to avoid annotation-propagation conflicts with `argocd-secret`). All other secrets are pulled from Infisical by ESO.

The ClusterSecretStore in `k8s/apps/external-secrets/cluster-secret-store.yaml` is configured with:

- `projectSlug: homelab`
- `environmentSlug: prod`
- `secretsPath: /`

This means any `ExternalSecret` using this store references secrets by their key name directly (e.g., `key: AUTHENTIK_SECRET_KEY`).

## How ExternalSecrets Work

Each application that needs secrets has an `ExternalSecret` resource in its kustomization directory. ArgoCD syncs the `ExternalSecret` to the cluster; ESO then creates the actual `Secret`.

```mermaid
sequenceDiagram
    participant ArgoCD
    participant ESO as ESO Controller
    participant CSS as ClusterSecretStore
    participant Infisical
    participant K8s as Kubernetes

    ArgoCD->>K8s: Apply ExternalSecret (from git)
    ESO->>CSS: Validate store is ready
    CSS->>Infisical: POST /api/v1/auth/universal-auth/login
    Infisical-->>CSS: accessToken (JWT)
    ESO->>Infisical: GET /api/v3/secrets/raw?workspaceSlug=homelab&environment=prod
    Infisical-->>ESO: { AUTHENTIK_SECRET_KEY: "abc123", ... }
    ESO->>K8s: Create/Update Secret "authentik-secret"
    Note over ESO: Repeats every refreshInterval (1h)
```

## Adding Secrets for a New Service

When deploying a new service that needs secrets, follow these steps:

### Step 1: Add the secret to Infisical

Open `https://holdens-mac-mini.story-larch.ts.net:8445`, navigate to the `homelab` project → `prod` environment, and add your secret (e.g., `MY_SERVICE_API_KEY`).

### Step 2: Create an ExternalSecret manifest

Create `k8s/apps/my-service/external-secret.yaml`:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: my-service-secret
  namespace: my-service
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: infisical
    kind: ClusterSecretStore
  target:
    name: my-service-secret
    creationPolicy: Owner
  data:
    - secretKey: API_KEY
      remoteRef:
        key: MY_SERVICE_API_KEY
```

### Step 3: Add to kustomization

In `k8s/apps/my-service/kustomization.yaml`, add:

```yaml
resources:
  - external-secret.yaml
  # ... other resources
```

### Step 4: Reference the Secret in the Deployment

```yaml
env:
  - name: API_KEY
    valueFrom:
      secretKeyRef:
        name: my-service-secret
        key: API_KEY
```

### Step 5: Push to git

ArgoCD will detect the new `ExternalSecret` and sync it. ESO will then create the K8s `Secret` within seconds. The Deployment will get the secret on next rollout.

## Credential Rotation

### Rotating the Machine Identity (ESO ↔ Infisical)

1. In the Infisical UI, go to **Settings → Machine Identities** → create a new identity or generate new credentials for the existing one.
2. Update `terraform/terraform.tfvars`:
   ```hcl
   infisical_machine_identity_client_id     = "<new-client-id>"
   infisical_machine_identity_client_secret = "<new-client-secret>"
   ```
3. Apply:
   ```bash
   cd terraform && terraform apply
   ```
   Terraform updates only the `infisical-machine-identity` K8s Secret. ESO picks up the new credentials on its next poll cycle (~30s).

### Rotating the Infisical ENCRYPTION_KEY / AUTH_SECRET

> **Warning:** Changing `ENCRYPTION_KEY` requires a data migration — all encrypted secrets in Infisical's database must be re-encrypted. Do this only if the key is compromised, and follow the [Infisical key rotation guide](https://infisical.com/docs/self-hosting/configuration/envars) first.

1. Update `terraform/terraform.tfvars` with new values.
2. Run `terraform apply`.
3. Restart the Infisical pod: `kubectl rollout restart deployment -n infisical -l app.kubernetes.io/component=infisical`

### Rotating the ArgoCD OIDC Client Secret

ArgoCD's OIDC client secret for Authentik SSO is managed through Terraform Helm values, not ESO.

1. Generate a new client secret in Authentik (UI or API) for the `argocd` provider.
2. Update `terraform/terraform.tfvars`:
   ```hcl
   argocd_oidc_client_secret = "<new-secret>"
   ```
3. Apply:
   ```bash
   cd terraform && terraform apply
   ```
   Helm updates `argocd-secret` with the new OIDC secret. ArgoCD picks it up on the next login — no pod restart required.

### Updating an Application Secret

1. In the Infisical UI, update the secret value in `homelab / prod`.
2. ESO automatically reconciles within `refreshInterval` (1 hour). To apply immediately:
   ```bash
   kubectl annotate externalsecret <name> -n <namespace> \
     force-sync=$(date +%s) --overwrite
   ```
3. The K8s Secret is updated. Restart the consuming pod to pick up the new value:
   ```bash
   kubectl rollout restart deployment <name> -n <namespace>
   ```

## Troubleshooting

```mermaid
flowchart TD
    Start["ExternalSecret shows SecretSyncedError"]
    A["kubectl describe externalsecret <name> -n <ns>"]
    Start --> A
    A --> B{"Error message?"}
    B -- "ClusterSecretStore not ready" --> C["kubectl get clustersecretstore infisical"]
    C --> D{"Status?"}
    D -- "InvalidProviderConfig\n401 Unauthorized" --> E["Machine identity credentials wrong\nor not in Terraform tfvars yet\n→ terraform apply"]
    D -- "InvalidProviderConfig\n403 Forbidden" --> F["Machine identity not added\nto homelab project in Infisical UI\n→ Project → Access Control → Add Identity"]
    D -- "InvalidProviderConfig\n404 Project not found" --> G["Project slug wrong\nCheck Infisical project settings\nEnsure slug = 'homelab'"]
    D -- "Valid / Ready: True" --> H["Store is fine, force ExternalSecret refresh:\nkubectl annotate externalsecret <name> -n <ns> force-sync=$(date +%s) --overwrite"]
    B -- "secret key not found" --> I["Key name doesn't exist in Infisical\n→ Add it in Infisical UI\n→ homelab / prod / AUTHENTIK_SECRET_KEY etc."]
```

| Symptom | Cause | Fix |
|---|---|---|
| `ClusterSecretStore` shows `InvalidProviderConfig` 401 | Wrong machine identity credentials | `terraform apply` with correct credentials in tfvars |
| `ClusterSecretStore` shows `InvalidProviderConfig` 403 | Machine identity not added to Infisical project | Infisical UI → Project → Access Control → Machine Identities → Add |
| `ClusterSecretStore` shows `InvalidProviderConfig` 404 | Wrong project slug | Infisical UI → Project Settings → confirm slug is `homelab` |
| `ExternalSecret` shows `SecretSyncedError` after store becomes valid | Cached old error state | `kubectl annotate externalsecret <name> -n <ns> force-sync=$(date +%s) --overwrite` |
| Pod can't start, missing secret keys | ExternalSecret not synced yet | `kubectl get externalsecret -n <ns>` — wait for `SecretSynced: True` |
| Infisical pod crashes on startup | `infisical-secrets` K8s Secret is wrong/missing | Check `kubectl get secret infisical-secrets -n infisical`; re-run `terraform apply` |
