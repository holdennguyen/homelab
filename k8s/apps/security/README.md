# Security - Trivy Operator

This directory contains the ArgoCD application and network policies for the `security` namespace, which hosts the Trivy Operator.

## Trivy Operator

Trivy Operator provides continuous container image vulnerability scanning for Kubernetes workloads. It periodically scans images of running pods and creates `VulnerabilityReport` custom resources that can be viewed via `kubectl` or integrated with monitoring.

**Key features:**

- Scans images of running pods automatically.
- Generates `VulnerabilityReport` CRs in the same namespace as the scanned pod.
- Can optionally block deployments of images with critical vulnerabilities when used as an admission controller (not enabled in this setup).
- Supports configurable severity thresholds and resource limits.

**Deployment:** Managed via the `trivy-operator` Helm chart from the Aquasecurity repository.

**Network Policies:** The `security` namespace uses default-deny with specific egress rules to allow:
- DNS resolution (UDP/TCP 53) to `kube-system`.
- Egress to Kubernetes API server (TCP 6443).
- Egress to container registries over HTTPS (TCP 443).
- Intra-namespace communication.

See [`docs/networking.md`](../../docs/networking.md) for the full traffic matrix.

## Resources

| File | Purpose |
|------|---------|
| `policies/` | NetworkPolicy definitions for the `security` namespace |
| `trivy-operator-app.yaml` (in `k8s/apps/argocd/applications/`) | ArgoCD Application that installs Trivy Operator via Helm |

## Accessing Vulnerability Reports

```bash
# List all VulnerabilityReports in a namespace
kubectl get vulnerabilityreports -n <namespace>

# View a specific report
kubectl get vulnerabilityreport <pod-name> -n <namespace> -o yaml
```
