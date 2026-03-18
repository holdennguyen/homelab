### Summary

Release v1.10.0 focuses on monitoring stability and resource optimization:

- **Trivy Operator scan jobs**: memory limit increased from 512Mi to 1Gi to prevent OOM kills during vulnerability scans.
- **Infra assessment disabled**: The node-collector job is now disabled via `operator.infraAssessmentScannerEnabled: false` to avoid PodSecurity baseline violations on the single-node OrbStack cluster and reduce unnecessary resource usage.
- **Documentation updated**: Trivy Operator README now accurately reflects current resource limits and configuration rationale.

These changes have been applied via GitOps (ArgoCD) and are now part of the main branch.
