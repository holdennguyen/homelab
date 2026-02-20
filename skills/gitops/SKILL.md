---
name: gitops
description: ArgoCD GitOps workflows for the homelab. Manage applications, sync policies, kustomize manifests, and the App of Apps pattern. Includes the mandatory git workflow for all repo changes.
metadata:
  {
    "openclaw":
      {
        "emoji": "🔄",
        "requires": { "bins": ["kubectl", "git", "gh"] },
      },
  }
---

# GitOps (ArgoCD)

Manage the homelab's GitOps pipeline. All cluster state is defined in `k8s/apps/` and synced by ArgoCD.

## Core rule

Never use `kubectl apply` for persistent changes. All changes go through git → ArgoCD sync. Manual kubectl changes are reverted by selfHeal within ~3 minutes.

## Mandatory Git Workflow

ALL changes to the homelab repository MUST follow this process. Never push directly to `main`. Branch protection is enforced on `main` — PRs require at least one approving review before merge.

### Workspace setup (once per session)

```bash
cd /data/workspaces/<your-agent-id>
gh repo clone holdennguyen/homelab homelab 2>/dev/null || (cd homelab && git checkout main && git pull origin main)
cd homelab
git config user.name "<your-agent-id>[bot]"
git config user.email "<your-agent-id>@openclaw.homelab"
```

The `git config` commands MUST run in every fresh clone. They set the per-agent git identity so commits are traceable to the specific agent.

### GitHub Labels

Every issue and PR MUST be labeled. Use `--label` flags on `gh issue create` and `gh pr create`.

**Agent labels** — who is working on this (always exactly one):

| Label | Agent |
|---|---|
| `agent:homelab-admin` | homelab-admin orchestrator |
| `agent:devops-sre` | devops-sre infrastructure agent |
| `agent:software-engineer` | software-engineer development agent |
| `agent:security-analyst` | security-analyst security agent |
| `agent:qa-tester` | qa-tester QA/testing agent |

**Type labels** — what kind of change (always exactly one):

| Label | Use for |
|---|---|
| `type:feat` | New features, services, resources |
| `type:fix` | Bug fixes, misconfigurations |
| `type:chore` | Maintenance, dependency updates, cleanup |
| `type:docs` | Documentation-only changes |
| `type:refactor` | Restructuring without behavior change |
| `type:security` | Security hardening, vulnerability fixes |

**Area labels** — what part of the homelab is affected (one or more):

| Label | Scope |
|---|---|
| `area:k8s` | Kubernetes manifests (`k8s/apps/`) |
| `area:terraform` | Terraform bootstrap (Layer 0) |
| `area:argocd` | ArgoCD applications and projects |
| `area:secrets` | Secret management (Infisical, ESO) |
| `area:monitoring` | Prometheus, Grafana, Alertmanager |
| `area:networking` | Tailscale, NodePort, DNS |
| `area:openclaw` | OpenClaw agents and skills |
| `area:auth` | Authentik SSO and OIDC |
| `area:gitea` | Gitea git forge |

**Priority labels** — urgency (always exactly one):

| Label | When to use |
|---|---|
| `priority:critical` | Service down, security breach, data loss risk |
| `priority:high` | Broken functionality, needs fix soon |
| `priority:medium` | Normal work, improvements |
| `priority:low` | Nice to have, minor enhancements |

**Semver label** — only when the type label alone is insufficient:

| Label | When to use |
|---|---|
| `semver:breaking` | The change has a breaking impact regardless of its type (e.g., a `type:refactor` that renames Terraform outputs, a `type:feat` that removes an existing API) |

Most PRs do NOT need a semver label — the version bump is derived from the type label automatically (see [Semantic Versioning](#semantic-versioning)).

### Agent footprint (mandatory)

Every action MUST be traceable to the specific agent that performed it. This is non-negotiable.

**Git identity** — set per-clone via `git config` (done in workspace setup above):

| Agent ID | `user.name` | `user.email` |
|---|---|---|
| `homelab-admin` | `homelab-admin[bot]` | `homelab-admin@openclaw.homelab` |
| `devops-sre` | `devops-sre[bot]` | `devops-sre@openclaw.homelab` |
| `software-engineer` | `software-engineer[bot]` | `software-engineer@openclaw.homelab` |
| `security-analyst` | `security-analyst[bot]` | `security-analyst@openclaw.homelab` |
| `qa-tester` | `qa-tester[bot]` | `qa-tester@openclaw.homelab` |

**Commit messages** — always include the agent tag at the end:

```
<type>: <description> (#<issue-number>) [<agent-id>]
```

Example: `feat: add redis caching layer (#42) [devops-sre]`

**Issue/PR body signature** — every issue and PR body MUST end with this footer:

```
---
Agent: <agent-id> | OpenClaw Homelab
```

**Branch names** — prefix with agent ID:

```
<agent-id>/<type>/<issue-number>-<short-description>
```

Example: `devops-sre/feat/42-redis-caching`

**Labels** — the `agent:<agent-id>` label is always required (see GitHub Labels above).

**Summary of where footprints appear:**

| Artifact | Footprint |
|---|---|
| Git commit author | `<agent-id>[bot] <<agent-id>@openclaw.homelab>` |
| Commit message | `... [<agent-id>]` suffix |
| Branch name | `<agent-id>/...` prefix |
| Issue labels | `agent:<agent-id>` |
| Issue body | `Agent: <agent-id> \| OpenClaw Homelab` footer |
| PR labels | `agent:<agent-id>` |
| PR body | `Agent: <agent-id> \| OpenClaw Homelab` footer |

### Step-by-step process

1. **Create a GitHub issue** — every change starts with a labeled issue assigned to the current milestone:
   ```bash
   gh issue create \
     --title "<type>: <description>" \
     --body "$(cat <<'EOF'
   <why this change is needed>

   ---
   Agent: <your-agent-id> | OpenClaw Homelab
   EOF
   )" \
     --assignee holdennguyen \
     --label "agent:<your-agent-id>,type:<type>,area:<area>,priority:<priority>" \
     --milestone "<current-milestone>" \
     --repo holdennguyen/homelab
   ```
   Capture the issue number from the output. If no open milestone exists, ask the orchestrator (or user) to create one before proceeding.

2. **Create a branch** from latest main:
   ```bash
   git checkout main && git pull origin main
   git checkout -b <your-agent-id>/<type>/<issue-number>-<short-description>
   ```

   Branch naming convention:
   | Prefix | Use for |
   |---|---|
   | `feat/` | New features, new services, new resources |
   | `fix/` | Bug fixes, misconfigurations |
   | `chore/` | Maintenance, dependency updates, cleanup |
   | `docs/` | Documentation-only changes |
   | `refactor/` | Restructuring without behavior change |

3. **Make changes** to the appropriate files:
   - Kubernetes manifests: `k8s/apps/<service>/`
   - ArgoCD applications: `k8s/apps/argocd/applications/`
   - Terraform (Layer 0): `terraform/`
   - Documentation: `k8s/apps/<service>/README.md` (single source of truth)

4. **Commit** referencing the issue with agent tag:
   ```bash
   git add <files>
   git commit -m "<type>: <description> (#<issue-number>) [<your-agent-id>]"
   ```

5. **Push and create a labeled PR** assigned to the same milestone as the issue:
   ```bash
   git push -u origin HEAD
   gh pr create \
     --title "<type>: <description>" \
     --label "agent:<your-agent-id>,type:<type>,area:<area>,priority:<priority>" \
     --assignee holdennguyen \
     --milestone "<current-milestone>" \
     --body "$(cat <<'EOF'
   Closes #<issue-number>

   ## Summary
   - <bullet points: what changed and why>

   ## Test plan
   - [ ] ArgoCD syncs successfully
   - [ ] Service health verified
   - [ ] Documentation updated

   ---
   Agent: <your-agent-id> | OpenClaw Homelab
   EOF
   )"
   ```

6. **Report** the PR URL to the user or orchestrator agent.

### After merge

- **Layer 1 (k8s manifests):** ArgoCD auto-syncs within ~3 minutes. Verify: `kubectl get applications -n argocd`
- **Layer 0 (Terraform):** Requires manual `terraform apply` on the host after merge.
- **Docker image changes:** Requires `./scripts/build-openclaw.sh` + `kubectl rollout restart` on the host.

### Keeping your branch up to date

Your feature branch MUST stay current with `main` throughout your work. Stale branches cause merge conflicts and block ArgoCD sync after merge.

**Before every push**, pull latest main into your branch:

```bash
git fetch origin main
git merge origin/main --no-edit
```

If the merge has conflicts:
1. Do NOT force-push or reset
2. Resolve conflicts in every affected file
3. `git add <resolved-files> && git merge --continue`
4. If conflicts are too complex, report to the orchestrator (or user) with the list of conflicting files

**When to run this:**
- Before your first commit on a new branch (right after `git checkout -b`)
- Before every `git push`
- When you discover main has been updated while your PR is open

### Pre-merge validation

Before merging any PR that modifies cluster resources, run these checks. This prevents rollbacks and outages.

**Manifest validation:**
- Confirm YAML is valid: `kubectl apply --dry-run=client -f <file>`
- Verify labels, namespaces, and resource references are correct
- Ensure no secrets or credentials appear in the diff

**Helm chart value verification (CRITICAL):**

Before changing any Helm `valuesObject` in an ArgoCD Application CR, ALWAYS verify the key exists:

```bash
helm show values <repo>/<chart> --version <version> | grep -A5 "<key>"
helm template <release> <repo>/<chart> --version <version> \
  --set <key>=<value> | grep -A10 "<expected-output>"
```

Charts silently ignore unknown keys — the value appears set but has no effect. Never assume a key path is valid without verification.

**Service compatibility:**
- Container image supports the proposed configuration (e.g., some images require starting as root and drop privileges internally)
- Volume permissions match `fsGroup`/`runAsUser` settings
- Init systems (s6-overlay, tini) are compatible with securityContext changes

### Post-merge verification

After every merge to `main`, verify the deployment succeeded:

```bash
# ArgoCD sync status (wait ~3 minutes)
kubectl get applications -n argocd

# Pod health
kubectl get pods -A | grep -v Running | grep -v Completed

# Service endpoints (adapt to affected services)
curl -sf http://localhost:<nodeport>/health
```

If any check fails, follow the rollback procedures in the `incident-response` skill.

### Rollback

When a merge to `main` causes service degradation, follow the `incident-response` skill for:
- Git revert procedures (preferred for GitOps)
- ArgoCD recovery (stuck syncs, force refresh)
- Post-rollback verification checklist
- Post-incident documentation requirements

Quick reference for the most common rollback:

```bash
# Revert a merge commit
git revert <bad-commit-sha> -m 1 --no-edit
git push origin main
# ArgoCD auto-syncs the revert within ~3 minutes
```

### What NOT to do

- Never push directly to `main`
- Never commit secrets, API keys, or credentials
- Never bundle unrelated changes in one PR
- Never use `kubectl apply` for persistent resources (ArgoCD will revert them)
- Never create an issue or PR without labels
- Never commit without the `[<agent-id>]` suffix in the message
- Never create an issue or PR body without the agent signature footer
- Never use a branch name without the `<agent-id>/` prefix
- Never assume a Helm value key exists — always verify with `helm show values` or `helm template`
- Never apply `securityContext` changes without verifying image compatibility

## App of Apps pattern

The root Application (`argocd-apps`) watches `k8s/apps/argocd/`. Each child Application CR in that directory points to a service's manifest directory.

```
k8s/apps/argocd/kustomization.yaml  →  lists Application CRs
k8s/apps/argocd/applications/*.yaml  →  one per service
k8s/apps/<service>/                  →  kustomize manifests
```

## Application management

```bash
# List all applications and their sync status
kubectl get applications -n argocd

# Get detailed status for one application
kubectl get application <name> -n argocd -o yaml

# Force hard refresh (re-read from git)
kubectl patch application <name> -n argocd \
  --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'

# Check sync diff (what would change)
kubectl get application <name> -n argocd -o jsonpath='{.status.sync.status}'
```

## Sync waves

ESO uses sync waves to handle CRD dependencies:
- Wave 0: `external-secrets` (installs CRDs)
- Wave 1: `external-secrets-config` (applies ClusterSecretStore)
- Default: all other applications (no ordering)

## Adding a new application

Follow the mandatory git workflow above, then:

1. Create `k8s/apps/<name>/` with manifests + `kustomization.yaml`
2. Create `k8s/apps/argocd/applications/<name>-app.yaml`
3. Add the file to `k8s/apps/argocd/kustomization.yaml` resources list
4. Update `k8s/apps/<name>/README.md` and `docs/<name>.md`
5. Commit, push, and create PR

## Semantic Versioning

The homelab repository follows [Semantic Versioning 2.0.0](https://semver.org/) with the format `vMAJOR.MINOR.PATCH` (e.g., `v0.3.1`).

### Version bump rules

The version bump for a release is determined by the **highest-impact change** among all PRs in the milestone:

| Condition | Bump | Example |
|---|---|---|
| Any PR has the `semver:breaking` label | **MAJOR** | Terraform state migration, removed service, renamed secrets that break consumers |
| At least one `type:feat` PR (no breaking) | **MINOR** | New service, new agent, new skill, new capability |
| Only `type:fix`, `type:chore`, `type:docs`, `type:refactor`, `type:security` PRs | **PATCH** | Bug fix, dependency update, doc improvement, security hardening |

Priority order: MAJOR > MINOR > PATCH. A single breaking PR escalates the entire release to MAJOR.

### What counts as breaking

A change is breaking if it requires manual intervention to adopt or causes existing functionality to stop working:

- Terraform state changes that require `terraform state mv` or re-import
- Removing or renaming a service, namespace, or secret key
- Changing a NodePort number or Tailscale Serve port
- Modifying ArgoCD project permissions that block existing apps
- Changing the OpenClaw agent config structure in a non-backward-compatible way

When in doubt, add `semver:breaking` — it's safer to over-classify than to surprise users.

## Milestones

GitHub Milestones group issues and PRs into planned releases. Every issue and PR MUST be assigned to a milestone.

### Milestone naming

Milestones are named with the target version: `vMAJOR.MINOR.PATCH` (e.g., `v0.3.0`). The version in the milestone name is the **planned** version — it may change if a breaking change is introduced mid-milestone.

### Milestone lifecycle

1. **Create** — `homelab-admin` (or the user) creates the next milestone:
   ```bash
   gh api repos/holdennguyen/homelab/milestones \
     --method POST \
     -f title="v<MAJOR>.<MINOR>.<PATCH>" \
     -f description="<high-level goal for this release>"
   ```

2. **Assign** — every agent assigns their issues and PRs to the current open milestone using `--milestone` on `gh issue create` and `gh pr create`

3. **Track** — check milestone progress:
   ```bash
   gh api repos/holdennguyen/homelab/milestones --jq '.[] | select(.state=="open") | "\(.title): \(.open_issues) open, \(.closed_issues) closed"'
   ```

4. **Close** — when all issues in the milestone are resolved and the release is cut, close the milestone:
   ```bash
   gh api repos/holdennguyen/homelab/milestones/<milestone-number> \
     --method PATCH -f state="closed"
   ```

### Finding the current milestone

Before creating an issue or PR, check for the current open milestone:

```bash
gh api repos/holdennguyen/homelab/milestones --jq '.[] | select(.state=="open") | .title' | head -1
```

If no open milestone exists, ask the orchestrator (or user) to create one. Never create issues or PRs without a milestone.

### Adjusting the milestone version

If a `semver:breaking` PR is merged into a milestone originally planned as a MINOR release (e.g., `v0.3.0`), the milestone should be renamed to reflect the MAJOR bump (e.g., `v1.0.0`). The orchestrator handles this:

```bash
gh api repos/holdennguyen/homelab/milestones/<milestone-number> \
  --method PATCH -f title="v<new-version>"
```

## Releases

Releases are cut when a milestone is complete. The `homelab-admin` orchestrator (or the user) owns the release process. Sub-agents do NOT create releases or tags.

### Release process

1. **Verify** all issues in the milestone are closed:
   ```bash
   gh api repos/holdennguyen/homelab/milestones --jq '.[] | select(.title=="<version>") | "open: \(.open_issues), closed: \(.closed_issues)"'
   ```

2. **Determine the version** by scanning the milestone's PRs for the highest semver impact:
   ```bash
   # Check for breaking changes
   gh pr list --repo holdennguyen/homelab --state merged --label "semver:breaking" --search "milestone:<version>" --json number,title --jq '.[].title'
   # Check for features
   gh pr list --repo holdennguyen/homelab --state merged --label "type:feat" --search "milestone:<version>" --json number,title --jq '.[].title'
   ```

3. **Create the tag and GitHub Release** with auto-generated release notes:
   ```bash
   gh release create "v<MAJOR>.<MINOR>.<PATCH>" \
     --repo holdennguyen/homelab \
     --target main \
     --title "v<MAJOR>.<MINOR>.<PATCH>" \
     --generate-notes \
     --latest
   ```

4. **Close the milestone**:
   ```bash
   gh api repos/holdennguyen/homelab/milestones/<milestone-number> \
     --method PATCH -f state="closed"
   ```

5. **Create the next milestone** for upcoming work:
   ```bash
   gh api repos/holdennguyen/homelab/milestones \
     --method POST \
     -f title="v<next-version>" \
     -f description="<goal>"
   ```

### Release notes

GitHub auto-generates release notes from merged PRs. The existing type and area labels provide natural grouping. No manual CHANGELOG is needed.

### What NOT to do with releases

- Sub-agents MUST NOT create tags or releases — only `homelab-admin` (or the user)
- Never tag an unmerged branch — tags are always on `main`
- Never skip the milestone — every PR must be traceable to the release it shipped in
- Never reuse a version tag — if a release needs a fix, bump PATCH and release again

## Troubleshooting

| Symptom | Fix |
|---|---|
| App stuck `OutOfSync` | Check ArgoCD can clone repo: `kubectl get secret repo-homelab -n argocd` |
| App stuck `Progressing` | Pod not ready: `kubectl describe pod -n <ns>` |
| CRD not found | Sync wave ordering issue: ensure wave 0 apps are healthy first |
| Changes not deploying | Wait ~3min or force refresh via annotation |
