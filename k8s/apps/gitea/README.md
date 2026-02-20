# Gitea

Self-hosted Git service running on Kubernetes, backed by PostgreSQL. Provides repository hosting, SSH access, and a web UI accessible at `https://holdens-mac-mini.story-larch.ts.net:8446` via Tailscale. Authentication is handled via **Authentik SSO** (OIDC).

## Architecture

```mermaid
flowchart TD
    subgraph giteaNs["gitea-system namespace"]
        subgraph giteaDeploy["Gitea Deployment"]
            InitContainer["init-config\n(busybox:1.36)"]
            GiteaContainer["gitea\n(gitea/gitea:1.22)"]
            InitContainer -- "copies app.ini\nto PVC" --> GiteaContainer
        end

        GiteaSvc["gitea Service\nNodePort :30300/:30022"]
        GiteaPVC["gitea-data PVC\n10Gi RWO"]
        GiteaConfigMap["gitea-config\nConfigMap (app.ini)"]
        GiteaSecret["gitea-secret\n(SECRET_KEY)"]
        PgSecret["postgresql-secret\n(GITEA_DB_PASSWORD)"]

        GiteaSvc -- ":3000" --> GiteaContainer
        GiteaContainer -- "mounts /data" --> GiteaPVC
        InitContainer -- "reads /etc/gitea/app.ini" --> GiteaConfigMap
        GiteaContainer -- "env: GITEA__database__PASSWD" --> PgSecret
        GiteaContainer -- "env: GITEA__security__SECRET_KEY" --> GiteaSecret
    end

    TServe["tailscale serve\n:8446 -> localhost:30300"] -- "HTTPS" --> GiteaSvc
    User["Browser"] -- "https://holdens-mac-mini\n.story-larch.ts.net:8446" --> TServe
    GiteaContainer -- "postgresql:5432" --> PgSvc["PostgreSQL Service"]
```

## Directory Contents

| File | Purpose |
|------|---------|
| `kustomization.yaml` | Lists all resources for Kustomize/ArgoCD rendering |
| `pvc.yaml` | 10Gi `ReadWriteOnce` PVC for Gitea repositories and data |
| `external-secret.yaml` | `ExternalSecret` that pulls `GITEA_SECRET_KEY` from Infisical → `gitea-secret` |
| `admin-external-secret.yaml` | `ExternalSecret` that pulls admin credentials from Infisical → `gitea-admin-secret` |
| `admin-init-job.yaml` | ArgoCD PostSync `Job` that creates or updates the Gitea admin user after every sync |
| `configmap.yaml` | `app.ini` with all non-sensitive Gitea configuration |
| `deployment.yaml` | Deployment with init container, env var overrides, and resource limits |
| `service.yaml` | NodePort Service exposing HTTP (:30300) and SSH (:30022) |

## Configuration Strategy

Gitea configuration uses a three-layer approach:

1. **ConfigMap** (`configmap.yaml`) — holds all non-sensitive settings in `app.ini` format
2. **ExternalSecret** (`external-secret.yaml`) — ESO pulls `GITEA_SECRET_KEY` from Infisical and creates the `gitea-secret` K8s Secret
3. **Secret-backed env vars** — inject sensitive values from K8s Secrets, overriding specific `app.ini` keys

> **No `secret.yaml`:** There is no static `Secret` manifest in this directory. All secrets originate in Infisical and are synchronized by the External Secrets Operator. See [docs/secret-management.md](../../docs/secret-management.md) for details.

```mermaid
flowchart LR
    subgraph infisical["Infisical (homelab/prod)"]
        IS1["GITEA_SECRET_KEY"]
        IS2["GITEA_DB_PASSWORD"]
        IS3["POSTGRES_PASSWORD"]
    end

    subgraph eso["External Secrets Operator"]
        ES1["ExternalSecret: gitea-secret"]
        ES2["ExternalSecret: postgresql-secret\n(in postgresql dir)"]
    end

    subgraph sources["K8s Secrets (created by ESO)"]
        CM["ConfigMap\napp.ini"]
        PgSecret["postgresql-secret\nGITEA_DB_PASSWORD"]
        GSecret["gitea-secret\nGITEA_SECRET_KEY"]
    end

    IS1 --> ES1 --> GSecret
    IS2 --> ES2 --> PgSecret

    subgraph init["Init Container"]
        Copy["cp app.ini to PVC\nchown 1000:1000"]
    end

    subgraph main["Gitea Container"]
        EnvToIni["environment-to-ini\n(entrypoint step)"]
        GiteaProc["Gitea process"]
    end

    PVCFile["/data/gitea/conf/app.ini\n(on PVC, writable)"]

    CM -- "read-only mount\n/etc/gitea/" --> Copy
    Copy -- "writes to PVC" --> PVCFile
    PgSecret -- "GITEA__database__PASSWD" --> EnvToIni
    GSecret -- "GITEA__security__SECRET_KEY" --> EnvToIni
    EnvToIni -- "merges env vars\ninto app.ini" --> PVCFile
    PVCFile --> GiteaProc
```

### Why an Init Container Is Needed

The Gitea Docker image reads its config from `/data/gitea/conf/app.ini` (inside the PVC), not from `/etc/gitea/`. Without the init container, a fresh PVC would have no `app.ini`, and Gitea would start in install-wizard mode with default settings.

The init container (`busybox:1.36`) runs before Gitea starts:

```sh
mkdir -p /data/gitea/conf
cp /etc/gitea/app.ini /data/gitea/conf/app.ini
chown 1000:1000 /data/gitea/conf/app.ini
```

The `chown` is required because the init container runs as root, but Gitea runs as UID 1000 (`git` user) and needs write access to save auto-generated tokens (e.g., `INTERNAL_TOKEN`, `LFS_JWT_SECRET`).

On every pod start, the init container overwrites the PVC copy with the ConfigMap version, ensuring the ConfigMap remains the source of truth. Gitea's `environment-to-ini` entrypoint then merges any `GITEA__*` env vars into the file before the main process reads it.

### Environment Variable Overrides

Only two env vars are set, both for sensitive values that cannot be stored in a ConfigMap:

| Env Var | Source | Overrides in app.ini |
|---------|--------|---------------------|
| `GITEA__database__PASSWD` | `postgresql-secret` key `GITEA_DB_PASSWORD` | `[database] PASSWD` |
| `GITEA__security__SECRET_KEY` | `gitea-secret` key `GITEA_SECRET_KEY` | `[security] SECRET_KEY` |

Gitea's env var convention is `GITEA__<SECTION>__<KEY>` (double underscores as separators).

### ConfigMap: app.ini

The `app.ini` covers all non-sensitive configuration:

**`[database]`** -- PostgreSQL connection (password excluded, injected via env var):

| Key | Value | Notes |
|-----|-------|-------|
| `DB_TYPE` | `postgres` | |
| `HOST` | `postgresql:5432` | Kubernetes Service DNS name (same namespace) |
| `USER` | `gitea` | Must match `POSTGRES_USER` in postgresql-secret |
| `NAME` | `gitea` | Must match `POSTGRES_DB` in postgresql-secret |
| `SSL_MODE` | `disable` | Internal cluster traffic, no TLS needed |

**`[server]`** -- HTTP and SSH settings:

| Key | Value | Notes |
|-----|-------|-------|
| `HTTP_PORT` | `3000` | Container listens here |
| `ROOT_URL` | `https://holdens-mac-mini.story-larch.ts.net:8446/` | Tailscale hostname for link generation |
| `START_SSH_SERVER` | `false` | Disabled; the Docker image's OpenSSH handles port 22 |
| `SSH_DOMAIN` | `holdens-mac-mini.story-larch.ts.net` | Used in SSH clone URLs |
| `LFS_START_SERVER` | `true` | Git LFS support |

**`[security]`**:

| Key | Value | Notes |
|-----|-------|-------|
| `INSTALL_LOCK` | `true` | Prevents the install wizard from showing |

### SSH Configuration

The Gitea Docker image bundles OpenSSH, which starts on port 22 inside the container. Gitea's built-in SSH server (`START_SSH_SERVER`) is disabled to avoid a port conflict. Both services would try to bind `:22`, and the second one fails with `address already in use`.

```mermaid
flowchart LR
    Client["Git SSH Client"] -- ":22" --> Svc["gitea Service\nport 22"]
    Svc --> OpenSSH["OpenSSH\n(Docker image built-in)"]
    OpenSSH --> GiteaInternal["Gitea Git backend"]
```

## Networking

### Service

The `gitea` Service is `NodePort` with two ports:

| Port | NodePort | Target | Protocol | Use |
|------|----------|--------|----------|-----|
| 3000 | 30300 | `http` | TCP | Web UI, API, Git HTTP |
| 22 | 30022 | `ssh` | TCP | Git SSH operations |

### Tailscale Serve

External access is provided via `tailscale serve` rather than a Kubernetes Ingress controller. This avoids the need for an ingress controller, certificate management, or DNS configuration.

```bash
tailscale serve --bg --https 8446 http://localhost:30300
```

```mermaid
flowchart LR
    Browser["Browser / Git Client"] -- "HTTPS :8446" --> TServe["tailscale serve\nauto TLS cert"]
    TServe -- "HTTP" --> NodePort["localhost:30300"]
    NodePort --> GiteaSvc["gitea Service\n:3000"]
    GiteaSvc --> GiteaPod["Gitea Pod"]
```

Access URL: `https://holdens-mac-mini.story-larch.ts.net:8446`

The TLS certificate is automatically provisioned by Tailscale (Let's Encrypt) for the `*.ts.net` domain. No manual certificate management is needed.

OrbStack NodePorts only bind to `localhost`, not to external interfaces. `tailscale serve` bridges this by listening on the Tailscale interface and proxying to localhost.

### Storage

The `gitea-data` PVC (10Gi, ReadWriteOnce) is mounted at `/data` and holds:

```
/data/
├── git/
│   ├── repositories/     # Git bare repos
│   └── lfs/              # LFS objects
└── gitea/
    ├── conf/
    │   └── app.ini        # Runtime config (seeded by init container)
    ├── sessions/
    ├── avatars/
    ├── attachments/
    ├── packages/
    └── data/
        └── ssh/           # OpenSSH host keys
```

## Resource Limits

| Resource | Request | Limit |
|----------|---------|-------|
| CPU | 100m | 500m |
| Memory | 256Mi | 512Mi |

## Non-Root Execution

The Gitea container runs as a non-root user (`git` UID 1000) enforced by the pod's `securityContext`. This mitigates the impact of a container escape by limiting the attacker's privileges inside the host.

```yaml
securityContext:
  runAsUser: 1000
  runAsGroup: 1000
  fsGroup: 1000
```

The init container still runs as root to set up the configuration volume with correct ownership, then the main container drops to non-root.

## Integration with PostgreSQL

Gitea depends on PostgreSQL for all persistent application data (users, repositories metadata, issues, pull requests, etc.). Git repository data (bare repos, LFS objects) is stored on the PVC.

```mermaid
flowchart TD
    subgraph gitea["Gitea"]
        WebUI["Web UI / API"]
        GitBackend["Git Backend"]
        ORM["ORM Engine"]
    end

    subgraph storage["Storage"]
        PVC["gitea-data PVC\n(repos, LFS, config)"]
        PG["PostgreSQL\n(users, issues, PRs,\nrepo metadata)"]
    end

    WebUI --> ORM
    GitBackend --> PVC
    ORM --> PG
```

## Admin User Management

The `gitea-admin-init` Job (an ArgoCD PostSync hook) creates or updates the Gitea admin user after every sync. It runs as the `git` user (UID 1000) inside the running Gitea pod using `kubectl exec`, which avoids config file issues.

```mermaid
sequenceDiagram
    participant ArgoCD
    participant Job as gitea-admin-init Job
    participant Gitea as Gitea Pod (git user)
    participant Infisical

    ArgoCD->>Job: PostSync — create Job
    Job->>Gitea: kubectl exec — wait for gitea admin user list
    Note over Job,Gitea: credentials base64-encoded,<br/>decoded inside the pod
    Gitea-->>Job: Ready
    Job->>Gitea: gitea admin user create/change-password
    Job->>Gitea: gitea admin user must-change-password --all --unset
    Gitea-->>Job: Success
    Job-->>ArgoCD: Completed
```

The admin credentials are pulled from Infisical into `gitea-admin-secret` by `admin-external-secret.yaml` before the Job runs.

**To update the admin password:** Change `GITEA_ADMIN_PASSWORD` in Infisical, force-sync the ExternalSecret, then trigger an ArgoCD sync to re-run the PostSync job.

```bash
# Force ESO to pull the new password
kubectl annotate externalsecret gitea-admin-secret -n gitea-system \
  force-sync=$(date +%s) --overwrite

# Check admin user credentials are correct
GITEA_USER=$(kubectl get secret gitea-admin-secret -n gitea-system \
  -o jsonpath='{.data.GITEA_ADMIN_USERNAME}' | base64 -d)
GITEA_PASS=$(kubectl get secret gitea-admin-secret -n gitea-system \
  -o jsonpath='{.data.GITEA_ADMIN_PASSWORD}' | base64 -d)
curl -s "http://localhost:30300/api/v1/user" -u "${GITEA_USER}:${GITEA_PASS}" | python3 -m json.tool
```

## Operational Commands

```bash
# Check pod status
kubectl get pods -n gitea-system -l app.kubernetes.io/name=gitea

# View logs (main container)
kubectl logs -n gitea-system deploy/gitea -c gitea

# View init container logs
kubectl logs -n gitea-system deploy/gitea -c init-config

# Check admin-init job logs (PostSync)
kubectl logs -n gitea-system -l job-name=gitea-admin-init

# Test API with admin credentials from secret
GITEA_USER=$(kubectl get secret gitea-admin-secret -n gitea-system \
  -o jsonpath='{.data.GITEA_ADMIN_USERNAME}' | base64 -d)
GITEA_PASS=$(kubectl get secret gitea-admin-secret -n gitea-system \
  -o jsonpath='{.data.GITEA_ADMIN_PASSWORD}' | base64 -d)
curl -s "http://localhost:30300/api/v1/user" -u "${GITEA_USER}:${GITEA_PASS}"

# Check effective app.ini on the PVC
kubectl exec -n gitea-system deploy/gitea -c gitea -- \
  cat /data/gitea/conf/app.ini

# List Gitea users (run as git user inside pod)
kubectl exec -n gitea-system deploy/gitea -- \
  su git -s /bin/sh -c 'gitea admin user list'
```

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| `password authentication failed` | `GITEA_DB_PASSWORD` in postgresql-secret doesn't match `POSTGRES_PASSWORD` | Align both values, delete PG PVC, restart |
| `database "gitea" does not exist` | PostgreSQL init was interrupted | Delete PG PVC and let it reinitialize |
| `permission denied` on app.ini | Init container didn't chown to UID 1000 | Check init container command includes `chown 1000:1000` |
| `address already in use` on :22 | `START_SSH_SERVER = true` in app.ini | Set to `false` (Docker OpenSSH already uses port 22) |
| Install wizard appears | No `app.ini` on PVC or `INSTALL_LOCK` not set | Verify init container runs and ConfigMap has `INSTALL_LOCK = true` |
| Config changes not taking effect | Pod not restarted after ConfigMap update | `kubectl rollout restart deployment gitea -n gitea-system` |
