# Trivy Operator

Trivy Operator is a Kubernetes operator that continuously scans container images for vulnerabilities and generates `VulnerabilityReport` resources for each running pod.

## Overview

- **Helm Chart**: `aquasecurity/trivy-operator`
- **Namespace**: `monitoring`
- **Reports**: View vulnerabilities with `kubectl get vulnerabilityreports -n <pod-namespace>`
- **Integration**: Works natively with Prometheus and Grafana (dashboards can be added)

## Architecture

The operator runs in **ClientServer mode**: a dedicated `trivy-server` StatefulSet maintains the vulnerability database on a persistent volume, and scan jobs query it over HTTP instead of each managing their own cache. This eliminates cache lock contention when scanning pods with multiple containers.

```mermaid
flowchart TD
    subgraph cluster["Kubernetes Cluster"]
        OP[Trivy Operator<br/>Deployment]
        TS[Trivy Server<br/>StatefulSet + PVC]
        SJ[Scan Jobs]
        Pod1[Pod with Image]
        Pod2[Pod with Image]
        VR[VulnerabilityReport<br/>Custom Resource]
    end
    OP -->|watches| Pod1
    OP -->|watches| Pod2
    OP -->|creates| SJ
    SJ -->|queries| TS
    SJ -->|produces| VR
```

## Configuration

The operator is deployed with tuned settings to balance scanning coverage with resource stability on a single-node homelab:

**Resource Optimization Notes:**
- Infra assessment (node-collector) is disabled (`operator.infraAssessmentScannerEnabled: false`) because its hostPath volume requirements violate the monitoring namespace's PodSecurity baseline and it's unnecessary for single-node OrbStack.

- Runs in **ClientServer mode** with a built-in trivy-server (eliminates cache lock contention)
- **On-change vulnerability scanning is disabled** to reduce resource usage; a scheduled daily scan is performed via a `VulnerabilityScanner` custom resource.
- Scans images of running pods on a schedule and generates reports.
- Does not block pod scheduling (report-only)
- Stores reports as Kubernetes custom resources
- Excludes the `openclaw` namespace (locally-built image not available from any registry)
- Limits concurrent scan jobs to 3
- Config audit (compliance) scans run daily at midnight UTC via the built-in compliance scheduler
- Scanner reports are retained for 72 hours; completed scan jobs are cleaned up after 30 minutes

### Helm Values

Overrides are set in the Application CR's `spec.source.helm.valuesObject`:

| Key | Value | Purpose |
|-----|-------|---------|
| `trivy.mode` | `ClientServer` | Centralized DB via trivy-server, no per-job cache |
| `operator.builtInTrivyServer` | `true` | Deploy trivy-server StatefulSet in-cluster |
| `trivy.serverURL` | `http://trivy-service.monitoring:4975` | Scan jobs query this endpoint |
| `operator.vulnerabilityScannerEnabled` | `false` | Disable on-change vulnerability scans |
| `operator.scanJobsConcurrentLimit` | `3` | Limit parallel scan jobs |
| `operator.scanJobTTL` | `30m` | Cleanup completed scan jobs after 30 minutes |
| `operator.scanJobsRetryDelay` | `2m` | Delay between retry attempts |
| `operator.scannerReportTTL` | `72h` | Keep vulnerability reports for 3 days |
| `compliance.cron` | `0 0 * * *` | Daily config audit scans at midnight |
| `resources.limits.memory` | `512Mi` | Operator deployment — prevents OOM |
| `trivy.resources.limits.memory` | `1Gi` | Scan job container memory (increased to prevent OOM) |
| `trivy.server.resources.limits.memory` | `512Mi` | Trivy server memory |
| `excludeNamespaces` | `openclaw` | Skip namespaces with local-only images |

### Scheduled Vulnerability Scans

A separate `VulnerabilityScanner` custom resource (installed via `k8s/apps/trivy-operator/vulnerability-scanner.yaml`) defines a daily scan schedule. This is managed by the trivy-operator's `VulnerabilityScanner` controller and runs in addition to (or instead of) on-change scans. With `operator.vulnerabilityScannerEnabled: false`, only the scheduled scans are performed.

Additional options:
- `trivy.severity`: filter by severity (e.g., `HIGH`, `CRITICAL`)
- `trivy.ignoreUnfixed`: whether to ignore vulnerabilities without a fix

Refer to the [Trivy Operator documentation](https://github.com/aquasecurity/trivy-operator) for advanced configuration.

## Secrets

No secrets are required; the operator uses read-only access to the Kubernetes API and the container runtime (via hostPID and container runtime socket).

## Networking

- The trivy-server needs egress to download the vulnerability database (`mirror.gcr.io/aquasec/trivy-db`).
- Scan jobs need egress to container registries to pull image layers for scanning.
- Ensure that egress to `ghcr.io`, `docker.io`, `mirror.gcr.io`, and other registries is allowed on HTTPS (443).

## Operational Commands

```bash
# List all vulnerability reports
kubectl get vulnerabilityreports --all-namespaces

# View report for a specific pod
kubectl get vulnerabilityreport <pod-name> -n <namespace> -o yaml

# Delete old reports (they are automatically garbage-collected)
kubectl delete vulnerabilityreport --all -n <namespace>
```

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| No VulnerabilityReport CRs appear | Operator not running or RBAC issues | Check pod logs: `kubectl logs -n monitoring -l app.kubernetes.io/name=trivy-operator` |
| Reports show `FAILED` | Image scan failed (private registry, large image, timeout) | Verify image pull secret exists; consider increasing resources/timeouts |
| Operator OOMKilled (exit 137) | Too many workloads to reconcile | Increase `resources.limits.memory` in Helm values |
| "cache may be in use by another process" | Multiple scan containers contending on shared cache | Use ClientServer mode (`trivy.mode: ClientServer`) |
| Scan job OOMKilled | Large container image exceeds scan job memory | Increase `trivy.resources.limits.memory` |
| "unable to find the specified image" | Local-only image not in any registry | Add namespace to `excludeNamespaces` |
