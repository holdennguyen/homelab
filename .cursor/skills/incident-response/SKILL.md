---
name: incident-response
description: Incident response, rollback procedures, and post-incident documentation for the homelab cluster. Use when a deployment causes service degradation or when you need to roll back a change.
---

# Incident Response & Rollback

Quick-reference for detecting, triaging, and rolling back incidents. The canonical procedures live in `skills/incident-response/SKILL.md` (OpenClaw skill); this is a condensed version for Cursor context.

```mermaid
flowchart TD
  Detect[Detect degradation] --> Triage["Triage: apps, pods, events"]
  Triage --> Classify{"Severity?"}
  Classify -->|"SEV-1: multi-svc down"| Immediate[Immediate response]
  Classify -->|"SEV-2: single svc"| Quick["Within 15 min"]
  Classify -->|"SEV-3: non-critical"| Hour["Within 1 hour"]
  Classify -->|"SEV-4: cosmetic"| NextCycle[Next cycle]
  Immediate --> Rollback
  Quick --> Rollback
  Rollback{"Rollback method"} -->|"single commit"| GitRevert["git revert + push main"]
  Rollback -->|"multi-commit"| FileRestore["git checkout known-good -- files"]
  GitRevert --> ArgoSync{ArgoCD syncs?}
  FileRestore --> ArgoSync
  ArgoSync -->|yes| Verify["Verify: apps + pods + secrets + health"]
  ArgoSync -->|stuck| Recovery["Cancel op + hard refresh"]
  Recovery --> Verify
  Verify --> PostIncident["Document: timeline, root cause, blast radius, resolution"]
```

See `skills/incident-response/SKILL.md` for full post-incident cleanup procedures (reopen issue, label reverted PR, create sub-issues, reassess milestone).
