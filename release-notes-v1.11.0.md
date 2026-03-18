### Summary

Release v1.11.0 introduces network stack modernization with eBPF-based Cilium CNI, delivering true NetworkPolicy enforcement and built-in observability. This release also closes critical network policy gaps that were previously non-functional due to Flannel's limitations.

**Highlights:**
- **Cilium** replaces Flannel for policy enforcement and high-performance networking
- **Hubble** provides real-time network flow visibility and service map
- **Authentik** now has internet egress for OIDC discovery, avatar downloads, and upstream providers
- **Prometheus** can now scrape kubelet metrics (10250) for node-level metrics
- **ArgoCD projects** cleaned up: networking-policies and namespace-security now use `apps` project

---

## New Features

### feat(cni): install Cilium eBPF dataplane

- Switched from Flannel to Cilium for enforced NetworkPolicies
- Enabled eBPF dataplane for lower latency and CPU overhead
- Hubble observability layer installed (optional UI)
- kube-proxy remains enabled initially for compatibility; can switch to `strict` replacement later

Relevant: #130

### feat(network): monitoring cross-namespace scrape rules

- Added `allow-egress-kubelet` policy in `monitoring` namespace (ports 10250, 9153)
  - Port 10250: kubelet metrics
  - Port 9153: coredns metrics
- Enables Prometheus to scrape core infrastructure from `kube-system`
- Completes cross-namespace scrape requirements referenced in #38

Part of PR #129

### feat(network): authentik internet egress

- Added `allow-egress-internet` policy in `authentik` namespace
- Fixes OIDC discovery, avatar downloads, and external authentication providers
- Authentik can now reach external identity providers over HTTPS

Part of PR #129

---

## Improvements

### chore(argocd): migrate networking-policies and namespace-security to apps project

- Both apps moved from `default` to `apps` for consistency
- Expanded `apps` project destinations to include `argocd`, `external-secrets`, `infisical`
- Enforces proper project isolation and alignment with conventions

Part of PR #129

---

## Technical Notes

### NetworkPolicy Gap Closure

Previously, default-deny policies had no effect because Flannel doesn't enforce them. With Cilium, these policies are now active:

- default-deny-all (all app namespaces)
- allow-same-namespace
- allow-dns
- allow-tailscale-ingress
- allow-egress-apiserver
- allow-egress-internet (where defined)
- allow-egress-kubelet (monitoring)
- cross-namespace allows (external-secrets ↔ infisical)

### Cilium Configuration

- **Version:** 1.17.x
- **Mode:** `kubeProxyReplacement=disabled` (coexist with kube-proxy)
- **eBPF:** Enabled with masquerade
- **Hubble:** Enabled with UI at `http://<tailscale-ip>:12000` (configurable)

### Upgrade Path

This release is a **minor** version bump due to the CNI change, which is backward-compatible at the application level (no API changes). Future releases may enable kube-proxy replacement.

---

## Migration Guide (if upgrading from v1.10.x)

**Important:** This release changes the cluster's CNI. Follow these steps carefully.

1. **Backup** your current manifests and `k8s/` repository.
2. Merge PR #129 into your `main` branch and let ArgoCD sync.
3. Deploy Cilium via ArgoCD (new `cilium` app in `apps` project). This will:
   - Disable Flannel DaemonSet (k3s default)
   - Install Cilium operator and agents
   - Reconfigure node networking
4. **Monitor** pod readiness: `kubectl get pods -A -w`
5. Verify service connectivity:
   - Tailscale serve endpoints
   - NodePort services (Grafana, Authentik, etc.)
   - ArgoCD UI
6. Confirm Hubble UI is accessible.
7. Once stable, you may optionally set `kubeProxyReplacement=strict` to remove kube-proxy dependency.

**Rollback:** If issues arise, disable Cilium app and re-enable Flannel (manual steps documented in `docs/networking/cni-migration.md`).

---

## Component Versions

| Component | Previous | Current |
|-----------|----------|---------|
| CNI | Flannel (k3s) | Cilium 1.17.x |
| NetworkPolicy enforcement | No | Yes (via eBPF) |
| Observability | - | Hubble UI |
| Authentik | 2025.12.4 | 2025.12.4 (unchanged) |
| Prometheus | kube-prometheus-stack 82.1.0 | unchanged |
| Infisical | 1.7.2 | unchanged |
| OpenClaw | e024f190 | unchanged |

---

## Errata

- No known issues

---

**Release date:** 2026-03-XX  
**Tag:** v1.11.0  
**GitHub milestone:** [v1.11.0](https://github.com/holdennguyen/homelab/milestone/11)
