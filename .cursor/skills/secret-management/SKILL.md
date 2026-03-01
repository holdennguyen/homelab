---
name: secret-management
description: Manage secrets through the Infisical to External Secrets Operator to Kubernetes pipeline. Add, rotate, and troubleshoot secrets without storing them in git.
---

# Secret Management

```mermaid
flowchart LR
  Infisical["Infisical (source of truth)"] -->|ESO sync| ExternalSecret[ExternalSecret CR]
  ExternalSecret -->|creates| K8sSecret[K8s Secret]
  K8sSecret -->|"secretKeyRef"| Pod[Pod env vars]
```

Secrets never live in git.

## Adding a Secret

```mermaid
flowchart TD
  A["1. Add key/value to Infisical (homelab/prod)"] --> B["2. Add entry to external-secret.yaml"]
  B --> C["3. Add secretKeyRef to deployment.yaml"]
  C --> D["4. Update docs + service README"]
  D --> E["5. Push to main → ArgoCD syncs → ESO creates Secret"]
```

## Rotating a Secret

```mermaid
flowchart TD
  R1["1. Update value in Infisical"] --> R2["2. Force ESO re-sync (annotate externalsecret)"]
  R2 --> R3["3. Restart consuming deployment"]
```

## Health Check

```bash
kubectl get clustersecretstore infisical
kubectl get externalsecret -A
kubectl get secret <name> -n <ns> -o jsonpath='{.data.<KEY>}' | base64 -d
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| `InvalidProviderConfig` on ClusterSecretStore | Check Infisical machine identity credentials |
| 401 Unauthorized | Update clientId/clientSecret in `terraform.tfvars`, run `terraform apply` |
| 403 Forbidden | Add machine identity to the `homelab` project in Infisical |
| ExternalSecret stuck `SecretSyncedError` | Force re-sync with annotation |
