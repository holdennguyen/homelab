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

Vikunja also appears as a bookmark in the Authentik portal under the **Productivity** group.

## Setup Steps

### 1. Create Infisical Secrets

Before the first sync, add the following secrets to Infisical under `homelab / prod / ` (root path):

| Key | Description | Example |
|-----|-------------|---------|
| `VIKUNJA_POSTGRES_USER` | PostgreSQL superuser username | `vikunja` |
| `VIKUNJA_POSTGRES_PASSWORD` | Password for the PostgreSQL user | (random strong password) |
| `VIKUNJA_POSTGRES_DB` | PostgreSQL database name | `vikunja` |
| `VIKUNJA_OIDC_CLIENT_SECRET` | Authentik OAuth2 client secret for Vikunja | (copy from Authentik provider) |

The External Secrets Operator will sync these into a `vikunja-db-secret` in the `vikunja` namespace. Both the PostgreSQL and Vikunja deployments share the same password key — no duplication needed.

### 2. Authentik OIDC Provider

Vikunja uses Authentik for SSO via OpenID Connect. The OAuth2 provider is created automatically via the Authentik blueprint in `k8s/apps/authentik/blueprints-configmap.yaml`.

After ArgoCD syncs the blueprint:

1. Open Authentik Admin → **Applications** → **Providers** → **vikunja**
2. Copy the **Client Secret** value
3. Add it to Infisical as `VIKUNJA_OIDC_CLIENT_SECRET` under `homelab / prod /` (root path)
4. Force an ExternalSecret re-sync:

```bash
kubectl annotate externalsecret vikunja-db-secret -n vikunja \
  force-sync=$(date +%s) --overwrite
```

5. Restart the Vikunja deployment:

```bash
kubectl rollout restart deployment vikunja -n vikunja
```

The OIDC redirect URI is: `https://holdens-mac-mini.story-larch.ts.net:8449/auth/openid/authentik`

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

## References

- [Vikunja Documentation](https://vikunja.io)
- [Vikunja GitHub](https://github.com/go-vikunja/vikunja)
- [Authentik Bookmark Applications](https://docs.goauthentik.io/docs/Applications/Bookmark)
