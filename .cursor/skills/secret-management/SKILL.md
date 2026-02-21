---
name: secret-management
description: Manage secrets through the Infisical to External Secrets Operator to Kubernetes pipeline. Add, rotate, and troubleshoot secrets without storing them in git.
---

# Secret Management

All secrets flow through: Infisical (source of truth) → ESO (sync) → K8s Secret (consumed by pods). Secrets never live in git.

## Adding a Secret

1. Add the key/value to Infisical UI under `homelab / prod`
2. Add an entry to `k8s/apps/<service>/external-secret.yaml`:
   ```yaml
   - secretKey: MY_KEY
     remoteRef:
       key: MY_KEY
   ```
3. Add the env var to the service's `deployment.yaml`:
   ```yaml
   - name: MY_KEY
     valueFrom:
       secretKeyRef:
         name: <service>-secret
         key: MY_KEY
   ```
4. Update `docs/secret-management.md` and the service's README with the new key
5. Push to `main` — ArgoCD syncs, ESO creates the K8s Secret

## Rotating a Secret

1. Update the value in Infisical
2. Force ESO re-sync: `kubectl annotate externalsecret <name> -n <ns> force-sync=$(date +%s) --overwrite`
3. Restart the consuming deployment: `kubectl rollout restart deployment/<name> -n <ns>`

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
