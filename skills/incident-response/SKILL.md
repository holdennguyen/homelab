---
name: incident-response
description: Incident response, rollback procedures, pre-merge validation, and post-incident documentation for the homelab cluster.
metadata:
  {
    "openclaw":
      {
        "emoji": "🚨",
        "requires": { "bins": ["kubectl", "git", "gh"] },
      },
  }
---

# Incident Response & Rollback

Procedures for detecting, triaging, rolling back, and documenting incidents in the GitOps-managed homelab cluster. Every agent with this skill MUST follow these procedures when a deployment causes service degradation.

## Severity Classification

| Severity | Criteria | Response Time |
|---|---|---|
| **SEV-1** | Multiple services down, data loss risk, security breach | Immediate — drop everything |
| **SEV-2** | Single service down or degraded, no data loss | Within 15 minutes |
| **SEV-3** | Non-critical service degraded, workaround exists | Within 1 hour |
| **SEV-4** | Cosmetic issue, no user impact | Next available cycle |

## Phase 1: Detection & Triage

When a deployment causes issues, run this triage sequence to assess blast radius:

```bash
# 1. ArgoCD application health (are any apps OutOfSync or Degraded?)
kubectl get applications -n argocd

# 2. Pod health across all namespaces
kubectl get pods -A | grep -v Running | grep -v Completed

# 3. Recent events (errors and warnings in the last 10 minutes)
kubectl get events -A --sort-by='.lastTimestamp' --field-selector type!=Normal | tail -30

# 4. Identify the failing service
kubectl describe pod <crashing-pod> -n <namespace>
kubectl logs -n <namespace> deploy/<name> --tail=100
```

**Triage checklist:**

- [ ] Which services are affected? (blast radius)
- [ ] What was the last change merged to `main`? (`git log -5 --oneline`)
- [ ] Are pods crashing (`CrashLoopBackOff`) or stuck (`Pending`/`Progressing`)?
- [ ] Is the issue caused by the new change or a pre-existing condition?
- [ ] Severity classification (SEV-1 through SEV-4)

## Phase 2: Rollback

### Decision: when to roll back

Roll back immediately if:
- A service is in `CrashLoopBackOff` after a merge
- ArgoCD shows `Degraded` for any application
- Health checks or endpoints are unreachable
- Logs show fatal errors tied to the new change

Do NOT roll back if:
- The issue is transient (pod restart resolved it)
- The issue is pre-existing and unrelated to the recent merge
- A forward fix is faster and safer than reverting

### Option A: Git revert (preferred for GitOps)

This is the standard rollback method. It creates a new commit that undoes the bad change, and ArgoCD syncs the revert automatically.

```bash
# Identify the bad merge commit
git log --oneline -10

# Revert the merge commit (use -m 1 for merge commits)
git revert <bad-commit-sha> -m 1 --no-edit
# OR for a non-merge commit:
git revert <bad-commit-sha> --no-edit

git push origin main
```

### Option B: File-level restore (when multiple commits need reverting)

When reverting multiple commits or when `git revert` causes conflicts, restore files to a known-good state:

```bash
# Find the last known-good commit (before the bad change)
git log --oneline -20

# Restore specific files to the known-good state
git checkout <known-good-sha> -- \
  path/to/file1.yaml \
  path/to/file2.yaml \
  path/to/file3.yaml

# Commit the restore
git commit -m "revert: restore files to pre-<description> state

Reverts commit <bad-sha> due to <root-cause>.
All affected files restored to <known-good-sha>.
"
git push origin main
```

### Option C: Emergency kubectl override (SEV-1 only)

Only for SEV-1 when git push → ArgoCD sync is too slow (ArgoCD will overwrite this within ~3 minutes, so the git revert must follow immediately):

```bash
kubectl rollout undo deployment/<name> -n <namespace>
```

**Always follow up with a proper git revert** — the kubectl change is temporary.

## Phase 3: ArgoCD Recovery

After pushing the revert to `main`, ArgoCD should auto-sync. If it doesn't:

### Force hard refresh on all applications

```bash
for app in $(kubectl get applications -n argocd -o jsonpath='{.items[*].metadata.name}'); do
  kubectl patch application "$app" -n argocd \
    --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
done
```

### Stuck sync (Progressing indefinitely)

If ArgoCD is stuck waiting for a crashing pod to become healthy:

```bash
# Cancel the stuck operation
kubectl patch application <app-name> -n argocd \
  --type json -p '[{"op":"remove","path":"/operation"}]'

# Force-delete the crashing pod so the new spec can take effect
kubectl delete pod <crashing-pod> -n <namespace> --force --grace-period=0

# Trigger a fresh sync
kubectl patch application <app-name> -n argocd \
  --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

### Sync wave ordering issues

If a revert affects resources across sync waves (e.g., CRDs + CRs), sync them in order:

```bash
kubectl get application external-secrets -n argocd -o jsonpath='{.status.sync.status}'
# Wait for wave 0 to sync before checking wave 1+
```

## Phase 4: Post-Rollback Verification

Run this checklist after every rollback to confirm full recovery:

```bash
# 1. All ArgoCD applications Synced + Healthy
kubectl get applications -n argocd

# 2. All pods Running with zero recent restarts
kubectl get pods -A | grep -v Running | grep -v Completed

# 3. ExternalSecrets synced
kubectl get externalsecrets -A

# 4. Service endpoints reachable (adapt ports to your services)
# Gitea
curl -sf http://localhost:30300/api/v1/version
# Monitoring (Grafana)
curl -sf http://localhost:30400/api/health
# Authentik
curl -sf http://localhost:30600/api/v3/root/config/
# OpenClaw
curl -sf http://localhost:30789/health

# 5. No error events in last 5 minutes
kubectl get events -A --sort-by='.lastTimestamp' --field-selector type!=Normal | tail -10
```

**Verification must pass ALL checks before the rollback is considered complete.**

## Pre-Merge Validation Checklist

Run this BEFORE merging any PR that modifies cluster resources. This prevents the need for rollbacks in the first place.

### Manifest validation

- [ ] YAML is valid (`kubectl apply --dry-run=client -f <file>`)
- [ ] Labels follow conventions (`app.kubernetes.io/*`)
- [ ] Namespace exists or `CreateNamespace=true` is set
- [ ] No secrets or credentials in the diff

### Helm chart value verification (CRITICAL)

Before changing any Helm `valuesObject` in an ArgoCD Application CR:

```bash
# 1. Verify the key exists in the chart
helm show values <repo>/<chart> --version <version> | grep -A5 "<key>"

# 2. Render templates to confirm the value takes effect
helm template <release> <repo>/<chart> --version <version> \
  --set <key>=<value> | grep -A10 "securityContext"
```

**Never assume a Helm value key exists.** Charts silently ignore unknown keys — the value appears to be set but has no effect on the rendered manifests. This was the root cause of the PR #11 incident where `controller.securityContext` (External Secrets) and `infisical.securityContext` (Infisical) were silently ignored.

### Service compatibility checks

- [ ] Container image supports the proposed configuration (e.g., non-root execution)
- [ ] Init systems (s6-overlay, tini) are compatible with securityContext changes
- [ ] Volume permissions match the proposed `fsGroup`/`runAsUser`
- [ ] Upstream chart documentation confirms the value path

### Cross-service impact

- [ ] Changes don't break sync wave dependencies
- [ ] Shared resources (ClusterRoles, CRDs) are not removed or renamed
- [ ] Existing ExternalSecrets still reference valid keys

## Post-Incident Documentation

After every incident (SEV-1 through SEV-3), document the following on the related GitHub issue or PR:

### Required sections

1. **Timeline** — chronological list of events (merge time, detection, triage, rollback, recovery)
2. **Root cause** — the specific technical cause of the failure
3. **Blast radius** — which services were affected and for how long
4. **Resolution** — what was done to restore service (revert commit SHA, manual steps)
5. **Lessons learned** — what could have prevented this (e.g., pre-merge validation, better testing)
6. **Action items** — concrete follow-up tasks with owners

### Template

```markdown
## Post-Incident Report

**Severity:** SEV-<N>
**Duration:** <start> — <end> (<minutes> min)
**Affected services:** <list>

### Timeline
| Time | Event |
|---|---|
| HH:MM | PR #N merged to main |
| HH:MM | ArgoCD sync triggered |
| HH:MM | <service> entered CrashLoopBackOff |
| HH:MM | Root cause identified |
| HH:MM | Revert pushed to main |
| HH:MM | All services recovered |

### Root Cause
<technical explanation>

### Resolution
<revert commit, manual steps>

### Lessons Learned
- <what we'd do differently>

### Action Items
- [ ] <follow-up task> — owner: <agent/user>
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `git revert` has conflicts | Multiple overlapping changes | Use file-level restore (Option B) instead |
| ArgoCD stuck `Progressing` | Waiting for crashing pod health check | Cancel operation + force-delete pod (see Phase 3) |
| Revert pushed but ArgoCD not syncing | Webhook or refresh delay | Force hard refresh on all applications |
| `kubectl rollout undo` reverted by ArgoCD | Expected — ArgoCD enforces git state | Push the git revert ASAP; kubectl undo is only a temporary bridge |
| Helm values silently ignored | Invalid key path in `valuesObject` | Always verify keys with `helm show values` before PRs |
| Container crashes after `securityContext` change | Image requires root (e.g., s6-overlay init) | Check image docs; some images drop privileges internally and must start as root |
| `fsGroup` warning on OrbStack volumes | OrbStack local-path provisioner uses GID 0 | Acceptable warning; doesn't affect functionality unless the app checks GID |
