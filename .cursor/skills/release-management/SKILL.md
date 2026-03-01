---
name: release-management
description: Release checklist, version tagging, doc freshness sweep, and root README review. Use when cutting a new release or preparing a milestone for release.
disable-model-invocation: true
---

# Release Management

Before tagging a new release (e.g. `v1.1.0`), complete every item in this checklist.

## Pre-Release Checklist

```mermaid
flowchart TD
  A["1. All milestone PRs merged?"] --> B["2. ArgoCD Synced + Healthy?"]
  B --> C["3. doc-freshness.py --stale (resolve stale)"]
  C --> D["4. Review root README.md (architecture, services, docs index, secrets, future plans)"]
  D --> E["5. Re-run doc-freshness.py --stale (confirm all clear)"]
  E --> F["6. git tag -a vX.Y.Z && git push origin vX.Y.Z"]
```

## Semantic Versioning

```mermaid
flowchart TD
  PRs[Scan milestone PRs] --> Breaking{"Any semver:breaking?"}
  Breaking -->|yes| Major[MAJOR bump]
  Breaking -->|no| Feat{"Any type:feat?"}
  Feat -->|yes| Minor[MINOR bump]
  Feat -->|no| Patch["PATCH bump (fix/chore/docs/refactor/security)"]
```

## Milestone Lifecycle

```bash
# Check for open milestones
gh api repos/holdennguyen/homelab/milestones --jq '.[] | select(.state=="open") | .title' | head -1

# Verify milestone completeness
gh api repos/holdennguyen/homelab/milestones --jq '.[] | select(.title=="<version>") | "open: \(.open_issues), closed: \(.closed_issues)"'

# Close milestone after release
gh api repos/holdennguyen/homelab/milestones/<number> --method PATCH -f state="closed"

# Create next milestone
gh api repos/holdennguyen/homelab/milestones --method POST -f title="v<next>" -f description="<goal>"
```
