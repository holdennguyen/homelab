Run pre-merge validation checks on the current branch before merging a PR that modifies cluster resources.

## Checks to Run

### 1. YAML Validation

For each modified YAML file under `k8s/`:
```bash
kubectl apply --dry-run=client -f <file>
```
Or for full kustomize builds:
```bash
kustomize build k8s/apps/<service>/ | kubectl apply --dry-run=client -f -
```

### 2. Helm Value Verification

If any ArgoCD Application CR `valuesObject` was modified, verify every changed key exists in the chart:
```bash
helm show values <repo>/<chart> --version <version> | grep -A5 "<key>"
```
Flag as **FAIL** if any key is not found — Helm silently ignores unknown keys.

### 3. Secret Scan

Check the diff for accidentally committed secrets:
```bash
git diff origin/main...HEAD
```
Flag any strings that look like API keys, passwords, tokens, or base64-encoded credentials.

### 4. Doc Freshness

Check if documentation needs updating for the files changed in this branch:
```bash
python scripts/doc-freshness.py --check-pr
```
Flag as **WARN** if the script reports missing doc updates.

### 5. Label and Convention Check

For modified K8s manifests, verify:
- All resources have `app.kubernetes.io/*` labels (name, instance, part-of, managed-by)
- Namespaces exist or `CreateNamespace=true` is set
- Container images use pinned tags (not `:latest` for upstream)

### 6. Mermaid Syntax Check

For modified `*.md` files containing mermaid blocks, verify:
- No spaces in node IDs (use camelCase/PascalCase/underscores)
- No `style`, `classDef`, or `:::` directives (break dark mode)
- No reserved keywords as bare node IDs (`end`, `subgraph`, `graph`)
- Edge labels with special characters are quoted: `-->|"label"|`
- Node labels with parentheses/colons are double-quoted: `A["Label (detail)"]`

Flag as **WARN** if any violations found. See the `/documentation` skill for the full mermaid conventions.

## Report Format

Summarize results as a checklist:
- [ ] YAML validation — PASS/FAIL
- [ ] Helm value keys — PASS/FAIL/N/A
- [ ] Secret scan — PASS/FAIL
- [ ] Doc freshness — PASS/WARN
- [ ] Labels and conventions — PASS/FAIL
- [ ] Mermaid syntax — PASS/WARN/N/A
