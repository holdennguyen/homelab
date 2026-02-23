# Vikunja Todo List Application

Vikunja is a self-hosted, feature-rich todo list and task management application.

## Architecture

This deployment consists of:
- PostgreSQL database (Deployment with PVC) for data persistence
- Vikunja application server (Deployment)
- Kubernetes Services for internal and external access
- Prometheus ServiceMonitor for metrics collection

## Resources

| Resource | Request | Limit |
|----------|---------|-------|
| PostgreSQL | CPU: 100m, Mem: 256Mi | CPU: 500m, Mem: 512Mi |
| Vikunja | CPU: 100m, Mem: 512Mi | CPU: 500m, Mem: 1Gi |
| Storage (PostgreSQL) | 5Gi | - |
| Storage (Vikunja files) | 1Gi | - |

## Access

- **Internal service DNS:** `vikunja.vikunja.svc.cluster.local`
- **External access (Tailscale):** `http://<tailscale-ip>:30888`
  - The service is exposed via NodePort 30888. Use Tailscale to route to the node's Tailscale address.

## Setup Steps

### 1. Create Infisical Secrets

Before the first sync, add the following secrets to Infisical under the path `/homelab/prod/vikunja/` (or your chosen environment):

| Key | Description | Example |
|-----|-------------|---------|
| `POSTGRES_USER` | PostgreSQL superuser username | `vikunja` |
| `POSTGRES_PASSWORD` | Password for the PostgreSQL user | (random strong password) |
| `POSTGRES_DB` | PostgreSQL database name | `vikunja` |
| `VIKUNJA_DB_PASSWORD` | Password used by Vikunja to connect (should match `POSTGRES_PASSWORD`) | (same as above) |

The External Secrets Operator will sync these into a `vikunja-db-secret` in the `vikunja` namespace.

### 2. Authentik Bookmark

To add Vikunja as a bookmark in Authentik:

1. Log into Authentik.
2. Go to **Applications** → **Add Application** → **Bookmark Application**.
3. Configuration:
   - **Name:** Vikunja
   - **URL:** `http://<tailscale-ip>:30888` (or the Tailscale DNS name)
   - **Group:** (assign as needed)
   - **Icon:** (optional)
4. Save. The application will appear in the user portal.

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
