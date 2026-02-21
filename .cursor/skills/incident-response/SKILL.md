---
name: incident-response
description: Incident response, rollback procedures, and post-incident documentation for the homelab cluster. Use when a deployment causes service degradation or when you need to roll back a change.
---

# Incident Response & Rollback

Quick-reference for detecting, triaging, and rolling back incidents. The canonical procedures live in `skills/incident-response/SKILL.md` (OpenClaw skill); this is a condensed version for Cursor context.

## Severity Classification

| Severity | Criteria | Response Time |
|---|---|---|
| **SEV-1** | Multiple services down, data loss risk, security breach | Immediate |
| **SEV-2** | Single service down or degraded, no data loss | Within 15 minutes |
| **SEV-3** | Non-critical service degraded, workaround exists | Within 1 hour |
| **SEV-4** | Cosmetic issue, no user impact | Next available cycle |

## Triage

```bash
kubectl get applications -n argocd
kubectl get pods -A | grep -v Running | grep -v Completed
kubectl get events -A --sort-by='.lastTimestamp' --field-selector type!=Normal | tail -30
```

## Rollback (git revert — preferred)

```bash
git log --oneline -10
git revert <bad-commit-sha> -m 1 --no-edit
git push origin main
```

For multi-commit rollbacks, use file-level restore:

```bash
git checkout <known-good-sha> -- path/to/file1.yaml path/to/file2.yaml
git commit -m "revert: restore files to pre-<description> state"
git push origin main
```

## ArgoCD Recovery

```bash
# Force hard refresh
for app in $(kubectl get applications -n argocd -o jsonpath='{.items[*].metadata.name}'); do
  kubectl patch application "$app" -n argocd \
    --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
done

# Cancel stuck sync
kubectl patch application <app-name> -n argocd \
  --type json -p '[{"op":"remove","path":"/operation"}]'
```

## Post-Rollback Verification

```bash
kubectl get applications -n argocd
kubectl get pods -A | grep -v Running | grep -v Completed
kubectl get externalsecrets -A
curl -sf http://localhost:30789/health            # OpenClaw
```

## Post-Incident

Document on the related GitHub issue/PR: timeline, root cause, blast radius, resolution, lessons learned, action items. See `skills/incident-response/SKILL.md` for full post-incident cleanup procedures (reopen issue, label reverted PR, create sub-issues, reassess milestone).
