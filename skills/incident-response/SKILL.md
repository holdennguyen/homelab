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

## Phase 5: Post-Incident Cleanup

After the cluster is recovered, clean up the issue/PR lifecycle so the release process stays accurate.

### 1. Reopen the original issue

The PR merge auto-closed the issue, but the revert means the feature was NOT delivered. Reopen it:

```bash
gh issue reopen <issue-number> --repo holdennguyen/homelab
gh issue comment <issue-number> --repo holdennguyen/homelab --body "$(cat <<'EOF'
Reopening — PR #<pr-number> was merged but reverted due to <root-cause>.
The feature is not delivered. See the post-incident report on PR #<pr-number>.
Re-implementation will be tracked as per-service sub-issues.
EOF
)"
```

### 2. Label the reverted PR

Create and apply a `status:reverted` label to the merged PR so release notes and milestone tracking reflect reality:

```bash
gh label create "status:reverted" --description "PR was merged but changes were reverted" \
  --color "D93F0B" --repo holdennguyen/homelab 2>/dev/null
gh pr edit <pr-number> --add-label "status:reverted" --repo holdennguyen/homelab
```

A PR with `status:reverted` is excluded from the effective changelog — it delivered no net change.

### 3. Assign milestones

- **Original issue**: assign to a future milestone for re-implementation (not the current one, since the work needs to be redone properly)
- **Reverted PR**: leave in its original milestone (if any) — the `status:reverted` label clarifies it

```bash
gh issue edit <issue-number> --milestone "v<future-version>" --repo holdennguyen/homelab
```

### 4. Create per-service sub-issues for re-implementation

The original failure often stems from applying a change to all services at once. Break the re-implementation into smaller, independently testable PRs:

```bash
for service in <service1> <service2> <service3>; do
  gh issue create \
    --title "<type>: <description> for ${service}" \
    --body "$(cat <<EOF
Part of the re-implementation of #<original-issue>.

Original PR #<pr-number> was reverted due to <root-cause>.
This issue covers only the ${service} service.

**Pre-merge checklist (mandatory):**
- [ ] Helm value key verified with \`helm show values\`
- [ ] Container image compatibility confirmed
- [ ] \`kubectl apply --dry-run=client\` passes
- [ ] Tested in isolation before merging

Parent: #<original-issue>
EOF
    )" \
    --label "<labels>" \
    --milestone "v<future-version>" \
    --assignee holdennguyen \
    --repo holdennguyen/homelab
done
```

### 5. Release impact

When a merge and its revert both land in the same milestone:

- **Net effect is zero** — they cancel each other out
- The `status:reverted` label signals to the release manager to exclude the PR from the changelog narrative
- If the reverted PR was the only `type:feat` in the milestone, the version bump may drop from MINOR to PATCH
- The release manager should review milestone PRs for `status:reverted` before cutting the release

## Phase 6: Stale PR Review & Milestone Reassessment

An incident often reveals systemic quality issues that affect sibling PRs created in the same batch. After the immediate cleanup, assess the broader milestone.

### 1. Identify sibling PRs

PRs created by the same agent, in the same time frame, or as part of the same task batch likely share the same quality risks:

```bash
# Find open PRs from the same agent
gh pr list --repo holdennguyen/homelab --state open \
  --label "agent:<agent-id>" --json number,title --jq '.[].title'

# Find open PRs in the same milestone
gh pr list --repo holdennguyen/homelab --state open \
  --search "milestone:<version>" --json number,title --jq '.[].title'
```

### 2. Triage sibling PRs

For each sibling PR, evaluate:

| Question | If yes |
|---|---|
| Was it created in the same batch as the reverted PR? | High risk — likely same quality issues |
| Has it been reviewed? | If not reviewed, close and rewrite |
| Does it modify Helm `valuesObject`? | Verify keys with `helm show values` |
| Does it make broad cross-service changes? | Break into per-service PRs |
| Does it have a pre-merge validation checklist? | If missing, close and rewrite |

**Decision matrix:**

| PR state | Reviewed? | Action |
|---|---|---|
| Open, same batch | No | **Close** — rewrite with pre-merge validation |
| Open, same batch | Yes, passed review | Re-review with incident learnings, merge if safe |
| Open, different batch | No | Review normally, but apply heightened scrutiny |
| Merged, not reverted | — | Spot-check for same class of issues |

### 3. Reassess the milestone

After closing stale PRs and moving issues, the milestone scope changes:

```bash
# Check milestone state
gh api repos/holdennguyen/homelab/milestones --jq \
  '.[] | select(.state=="open") | "\(.title): open=\(.open_issues), closed=\(.closed_issues)"'
```

**Milestone reassessment rules:**

- **All planned features reverted or deferred** → rescope the milestone to what's already shipped (merged infrastructure, docs, tooling). Update the milestone description.
- **Milestone has 0 open issues** → it's ready for release. Cut the release with what's there.
- **Only `status:reverted` PRs remain as features** → the version bump drops (e.g., MINOR → PATCH if no net features).
- **Unreviewed PRs from a failed batch** → close them, move their parent issues to the next milestone, create fresh per-service sub-issues.

### 4. Update milestone description

Reflect the new scope so anyone reading the milestone understands what changed and why:

```bash
gh api repos/holdennguyen/homelab/milestones/<number> --method PATCH \
  -f description="<updated description explaining scope change and why>"
```

### 5. Assign orphaned merged PRs

Merged PRs without a milestone create gaps in release tracking. Assign them to the current milestone:

```bash
# Find merged PRs with no milestone
gh pr list --repo holdennguyen/homelab --state merged --json number,title,milestone \
  --jq '.[] | select(.milestone == null) | "\(.number) | \(.title)"'

# Assign each to the appropriate milestone
gh pr edit <number> --milestone "v<version>" --repo holdennguyen/homelab
```

### Summary checklist (full post-incident)

- [ ] Original issue reopened with revert explanation
- [ ] Reverted PR labeled `status:reverted`
- [ ] Original issue assigned to future milestone
- [ ] Per-service sub-issues created for re-implementation
- [ ] Post-incident report posted on the reverted PR
- [ ] Sibling PRs triaged — unreviewed ones from same batch closed
- [ ] Parent issues of closed sibling PRs moved to future milestone
- [ ] Orphaned merged PRs assigned to milestones
- [ ] Milestone description updated to reflect new scope
- [ ] Release cut if milestone is ready (0 open issues)
- [ ] Release manager notified of milestone impact

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
