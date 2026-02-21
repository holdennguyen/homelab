---
name: qa-tester
description: Deployment validation, service health testing, regression checks, and smoke testing for the homelab Kubernetes cluster.
metadata:
  {
    "openclaw":
      {
        "emoji": "🧪",
        "requires": { "anyBins": ["kubectl"] },
      },
  }
---

# QA Tester

Validate deployments, test service health, and catch regressions across the homelab cluster.

## Responsibilities

- Validate ArgoCD sync status and application health
- Verify pod readiness, resource usage, and restart counts
- Test service endpoints and connectivity
- Validate ExternalSecret sync and secret availability
- Smoke-test services after deployments
- Regression testing across cross-namespace dependencies
- Maintain per-service acceptance criteria
- Classify and report defects with evidence

## Test strategy

### Test types and when to apply them

| Test type | When | What it validates | Who triggers |
|---|---|---|---|
| **Pre-deploy review** | Before merging a PR | YAML validity, label conventions, resource limits, docs | On PR review |
| **Smoke test** | After ArgoCD syncs a change | Service starts, health endpoint 200, no crashloops | After every merge to main |
| **Regression test** | After any infrastructure change | Existing services still healthy, secrets synced, endpoints reachable | After merges touching shared resources |
| **Full cluster validation** | Weekly or after major changes | All services, all secrets, all ArgoCD apps | On demand or scheduled |
| **Chaos/failure test** | Before adding critical services | Service recovers from pod kill, secret rotation, node restart | On demand |

### Test priority matrix

Focus testing effort based on risk:

| Service | Change risk | Test priority | Reason |
|---|---|---|---|
| ArgoCD | High | Critical | Manages all other deployments |
| ESO + ClusterSecretStore | High | Critical | All secrets depend on it |
| Infisical | High | Critical | Source of truth for secrets |
| OpenClaw | Medium | High | Agent gateway, multiple components |
| Monitoring | Low | Medium | Observability, non-blocking |

## Validation commands

```bash
# ArgoCD application health
kubectl get applications -n argocd -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'

# All pods status across namespaces
kubectl get pods -A -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,STATUS:.status.phase,RESTARTS:.status.containerStatuses[0].restartCount,READY:.status.containerStatuses[0].ready'

# ExternalSecret sync status
kubectl get externalsecrets -A -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,STATUS:.status.conditions[0].reason'

# Service endpoints populated
kubectl get endpoints -A

# Recent events (errors/warnings)
kubectl get events -A --field-selector type!=Normal --sort-by='.metadata.creationTimestamp'

# Resource usage
kubectl top pods -A --sort-by=memory
```

## Per-service acceptance criteria

### ArgoCD

| Check | Command | Pass criteria |
|---|---|---|
| Server pod running | `kubectl get pods -n argocd -l app.kubernetes.io/component=server` | `Running`, 0 restarts |
| All apps synced | `kubectl get applications -n argocd` | All `Synced` + `Healthy` |
| Repo accessible | `kubectl get application argocd-apps -n argocd -o jsonpath='{.status.sync.status}'` | `Synced` |
| UI reachable | `curl -sk https://localhost:30080/healthz` | 200 |

### External Secrets Operator

| Check | Command | Pass criteria |
|---|---|---|
| Operator pod running | `kubectl get pods -n external-secrets` | All `Running`, 0 restarts |
| ClusterSecretStore connected | `kubectl get clustersecretstore infisical -o jsonpath='{.status.conditions[0].status}'` | `True` |
| All ExternalSecrets synced | `kubectl get externalsecret -A` | All `SecretSynced` |

### OpenClaw

| Check | Command | Pass criteria |
|---|---|---|
| Pod running | `kubectl get pods -n openclaw` | `Running`, 0 restarts |
| Health endpoint | `kubectl exec -n openclaw deploy/openclaw -- wget -qO- http://localhost:18789/health` | 200 |
| Config mounted | `kubectl exec -n openclaw deploy/openclaw -- cat /config/openclaw.json \| jq '.agents.list \| length'` | Agent count matches config |
| Skills loaded | `kubectl exec -n openclaw deploy/openclaw -- ls /skills/` | All skill directories present |

### Monitoring (Prometheus + Grafana)

| Check | Command | Pass criteria |
|---|---|---|
| Prometheus running | `kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus` | `Running` |
| Grafana running | `kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana` | `Running` |
| Grafana UI | `curl -sf http://localhost:30090/api/health` | 200 |

## Health check pattern

For any service with an HTTP health endpoint:

```bash
# Direct pod check via port-forward (non-destructive)
kubectl port-forward -n <ns> svc/<name> <local>:<port> &
PF_PID=$!
sleep 2
curl -sf http://localhost:<local>/health && echo "PASS" || echo "FAIL"
kill $PF_PID
```

## Full cluster validation script

Run this sequence for a complete cluster health check:

```bash
echo "=== Node Health ==="
kubectl get nodes
kubectl top nodes

echo "=== Pod Health ==="
kubectl get pods -A | grep -v Running | grep -v Completed

echo "=== ArgoCD Apps ==="
kubectl get applications -n argocd -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'

echo "=== ExternalSecrets ==="
kubectl get externalsecret -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,READY:.status.conditions[0].reason'

echo "=== PVCs ==="
kubectl get pvc -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,STATUS:.status.phase,CAPACITY:.status.capacity.storage'

echo "=== Warning Events (last 1h) ==="
kubectl get events -A --field-selector type=Warning --sort-by='.metadata.creationTimestamp' | tail -10

echo "=== Resource Usage ==="
kubectl top pods -A --sort-by=memory | head -15
```

## Chaos and failure testing

Test service resilience by simulating failures (use with caution, one at a time):

| Test | Command | Expected recovery |
|---|---|---|
| Kill a pod | `kubectl delete pod <name> -n <ns>` | Deployment recreates pod within 30s |
| Restart a deployment | `kubectl rollout restart deployment/<name> -n <ns>` | New pod healthy within 60s |
| Force ESO re-sync | `kubectl annotate externalsecret <name> -n <ns> force-sync=$(date +%s) --overwrite` | Secret re-synced, pod unaffected |
| ArgoCD hard refresh | `kubectl annotate application <app> -n argocd argocd.argoproj.io/refresh=hard --overwrite` | App re-syncs without changes |

Rules:
- Never chaos-test more than one service at a time
- Always verify the service recovers before testing the next one
- Do not chaos-test during active development or incident response
- Document results in the test report

## Defect classification

Uses the canonical scale from the `incident-response` skill:

| Severity | Criteria | Response expectation |
|---|---|---|
| **SEV-1** | Service down, data loss risk, security exposure | Immediate fix required before any other work |
| **SEV-2** | Core functionality broken, but workaround exists | Fix within same day |
| **SEV-3** | Feature degraded, non-critical path affected | Fix within next PR cycle |
| **SEV-4** | Cosmetic, docs mismatch, non-functional | Best effort, can defer |

## Test report format

When reporting results, use this structure:

```
## Test Report — <date> — <trigger>

### Summary
- **Scope:** <what was tested>
- **Result:** X/Y checks passed
- **SEV-1 issues:** <any blocking issues>

### Results

| Service | Test | Result | Evidence |
|---|---|---|---|
| <service> | <what was checked> | PASS/FAIL | <command output snippet> |

### Issues Found

| ID | Severity | Service | Description | Action |
|---|---|---|---|---|
| QA-NNN | SEV-3 | <service> | <what's wrong> | <who to notify, what to fix> |
```
