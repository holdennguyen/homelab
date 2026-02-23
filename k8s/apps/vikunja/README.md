# Vikunja Todo List Application

Vikunja is a self-hosted, feature-rich todo list and task management application.

## Architecture

This deployment consists of:
- PostgreSQL database (Deployment with PVC) for data persistence
- Vikunja application server (Deployment)
- Kubernetes Services for internal and external access
- Prometheus ServiceMonitor for metrics collection
- OIDC authentication via Authentik (SSO)

## Resources

| Resource | Request | Limit |
|----------|---------|-------|
| PostgreSQL | CPU: 100m, Mem: 256Mi | CPU: 500m, Mem: 512Mi |
| Vikunja | CPU: 100m, Mem: 512Mi | CPU: 500m, Mem: 1Gi |
| Storage (PostgreSQL) | 5Gi | - |
| Storage (Vikunja files) | 1Gi | - |

## Access

- **Internal service DNS:** `vikunja.vikunja.svc.cluster.local`
- **NodePort:** `http://localhost:30888`
- **Tailscale Serve:** `https://holdens-mac-mini.story-larch.ts.net:8449`

One-time Tailscale Serve setup (run on the Mac mini):

```bash
tailscale serve --bg --https 8449 http://localhost:30888
```

Vikunja is an OIDC-protected application in the Authentik portal under the **Productivity** group. Login is handled via Authentik SSO.

## Setup Steps

### 1. Create Infisical Secrets

Before the first sync, add the following secrets to Infisical under `homelab / prod / ` (root path):

| Key | Description | Example |
|-----|-------------|---------|
| `VIKUNJA_POSTGRES_USER` | PostgreSQL superuser username | `vikunja` |
| `VIKUNJA_POSTGRES_PASSWORD` | Password for the PostgreSQL user | (random strong password) |
| `VIKUNJA_POSTGRES_DB` | PostgreSQL database name | `vikunja` |
| `VIKUNJA_OIDC_CLIENT_SECRET` | Authentik OAuth2 client secret for Vikunja | (random 64-char alphanumeric string) |

The External Secrets Operator will sync these into a `vikunja-db-secret` in the `vikunja` namespace. Both the PostgreSQL and Vikunja deployments share the same password key — no duplication needed.

### 2. Create Authentik OIDC Provider

Vikunja uses Authentik for SSO via OpenID Connect. The provider is created in the Authentik Admin UI (same pattern as ArgoCD and Grafana).

1. Open Authentik Admin → **Applications** → **Providers** → **Create** → **OAuth2/OpenID Provider**
2. Configure:

| Field | Value |
|---|---|
| Name | `vikunja` |
| Authorization flow | `default-provider-authorization-implicit-consent` |
| Client type | Confidential |
| Client ID | `vikunja` |
| Client Secret | Paste the value from Infisical key `VIKUNJA_OIDC_CLIENT_SECRET` |
| Redirect URIs | `https://holdens-mac-mini.story-larch.ts.net:8449/auth/openid/authentik` |
| Signing Key | `authentik Self-signed Certificate` |
| Scopes | `openid`, `email`, `profile` |

3. Save the provider.
4. Go to **Applications** → **vikunja** → **Edit** → set **Provider** to `vikunja` → Save.
5. Restart the Vikunja deployment to re-discover the OIDC provider:

```bash
kubectl rollout restart deployment vikunja -n vikunja
```

**OIDC details:**

| Setting | Value |
|---|---|
| Client ID | `vikunja` |
| Redirect URI | `https://holdens-mac-mini.story-larch.ts.net:8449/auth/openid/authentik` |
| OIDC Discovery | `https://holdens-mac-mini.story-larch.ts.net/application/o/vikunja/.well-known/openid-configuration` |
| Scopes | `openid profile email` |
| Signing algorithm | RS256 |

The client secret flows from Infisical → Vikunja ExternalSecret → K8s Secret → file mount at `/secrets/oidc-client-secret` → referenced by `vikunja-config.yaml`.

For the general pattern, see [Adding a new OIDC-protected service](../authentik/README.md#adding-a-new-oidc-protected-service).

### 3. ArgoCD Sync

Once the files are merged to `main`, ArgoCD will automatically sync the `vikunja` application within ~3 minutes.

You can also manually trigger sync:
```bash
kubectl patch application vikunja -n argocd \
  --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

## Post-Deployment Verification

```bash
# Check pods
kubectl get pods -n vikunja

# Check services
kubectl get svc -n vikunja

# Test connectivity
kubectl exec -n vikunja deploy/vikunja -- curl -s http://postgresql.vikunja.svc.cluster.local:5432

# View vikunja logs
kubectl logs -n vikunja deploy/vikunja

# Access via Tailscale: open browser to http://<node-tailscale-ip>:30888
```

## Maintenance

### Changing the Vikunja version

Edit `k8s/apps/vikunja/vikunja-deployment.yaml` and update the `image` tag (e.g., `vikunja/vikunja:1.1.0`). Then commit and push; ArgoCD will roll out the update.

### Backing up the database

```bash
kubectl exec -n vikunja deploy/postgresql -- \
  pg_dump -U vikunja vikunja > backup_$(date +%F).sql
```

### Restoring a backup

```bash
kubectl exec -i -n vikunja deploy/postgresql -- \
  psql -U vikunja -d vikunja < backup_2024-01-01.sql
```

### Updating Infisical secrets

After updating secrets in Infisical, force a sync:
```bash
kubectl annotate externalsecret vikunja-db-secret -n vikunja \
  force-sync=$(date +%s) --overwrite
```

Then restart affected deployments:
```bash
kubectl rollout restart deployment postgresql -n vikunja
kubectl rollout restart deployment vikunja -n vikunja
```

Note: Changing the PostgreSQL `POSTGRES_PASSWORD` requires a database password update inside PostgreSQL as well (see PostgreSQL docs). For simplicity, treat these credentials as immutable; if you must change them, back up and recreate the database.

## Troubleshooting

- **Pods not starting:** Check `kubectl logs -n vikunja <pod>`; common issues are missing Infisical secret or invalid values.
- **Cannot connect to database:** Verify the `vikunja-db-secret` exists and has correct keys. Ensure PostgreSQL pod is Ready.
- **No metrics in Prometheus:** Confirm the ServiceMonitor has been synced and the `vikunja` Service has the correct labels.
- **External access not working:** Ensure Tailscale routing to the node and that the NodePort is within the allowed range (30000-32767). Check service `type: NodePort` and `nodePort: 30888`.
- **OIDC "Login with Authentik" not showing:** Check that `vikunja-config` ConfigMap is mounted at `/etc/vikunja/config.yml` and the `auth.openid.enabled` is `true`. Verify the pod has restarted after ConfigMap changes.
- **OIDC "invalid client" error:** Verify `VIKUNJA_OIDC_CLIENT_SECRET` in Infisical matches what the Authentik provider has. Force re-sync both ExternalSecrets (`authentik-secret` and `vikunja-db-secret`) and restart both pods.

## References

- [Vikunja Documentation](https://vikunja.io)
- [Vikunja OpenID Connect](https://vikunja.io/docs/openid)
- [Vikunja GitHub](https://github.com/go-vikunja/vikunja)
- [Authentik Blueprints — YAML Tags](https://docs.goauthentik.io/customize/blueprints/v1/tags)
- [Authentik OIDC Provider](https://docs.goauthentik.io/docs/add-secure-apps/providers/oauth2/)
