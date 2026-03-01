---
name: secret-management
description: Manage secrets through the Infisical → External Secrets Operator → Kubernetes pipeline. Add, rotate, and troubleshoot secrets without storing them in git.
metadata:
  {
    "openclaw":
      {
        "emoji": "🔑",
        "requires": { "bins": ["kubectl"] },
      },
  }
---

# Secret Management

```mermaid
flowchart LR
  Infisical["Infisical (source of truth)"] -->|ESO sync| ExternalSecret[ExternalSecret CR]
  ExternalSecret -->|creates| K8sSecret[K8s Secret]
  K8sSecret -->|"secretKeyRef"| Pod[Pod]
```

Secrets never live in git.

## Adding a secret for a service

```mermaid
flowchart TD
  A["1. Add key/value to Infisical (homelab/prod)"] --> B["2. Add entry to external-secret.yaml"]
  B --> C["3. Add secretKeyRef to deployment.yaml"]
  C --> D["4. Push to main → ArgoCD syncs → ESO creates Secret"]
```

## Rotating a secret

```mermaid
flowchart TD
  R1["1. Update value in Infisical"] --> R2["2. Force ESO re-sync (annotate externalsecret)"]
  R2 --> R3["3. Restart consuming deployment"]
```

## Checking secret health

```bash
# ClusterSecretStore connectivity
kubectl get clustersecretstore infisical
kubectl describe clustersecretstore infisical

# All ExternalSecrets across the cluster
kubectl get externalsecret -A

# Decode a secret value
kubectl get secret <name> -n <ns> -o jsonpath='{.data.<KEY>}' | base64 -d
```

## Current secrets

| ExternalSecret | Namespace | Keys |
|---|---|---|
| `authentik-secret` | `authentik` | AUTHENTIK_SECRET_KEY, AUTHENTIK_BOOTSTRAP_PASSWORD, AUTHENTIK_BOOTSTRAP_TOKEN, AUTHENTIK_POSTGRES_PASSWORD |
| `grafana-secret` | `monitoring` | GRAFANA_ADMIN_PASSWORD, GRAFANA_OAUTH_CLIENT_SECRET |
| `openclaw-secret` | `openclaw` | OPENCLAW_GATEWAY_TOKEN, OPENROUTER_API_KEY, GEMINI_API_KEY, GITHUB_TOKEN |

## Troubleshooting

| Symptom | Fix |
|---|---|
| `InvalidProviderConfig` on ClusterSecretStore | Check Infisical machine identity credentials |
| 401 Unauthorized | Update clientId/clientSecret in `terraform.tfvars`, run `terraform apply` |
| 403 Forbidden | Add machine identity to the `homelab` project in Infisical |
| ExternalSecret stuck `SecretSyncedError` | Force re-sync with annotation |
