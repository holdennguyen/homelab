### Summary

Release v1.11.0 captures merged work since **v1.10.3**: NetworkPolicy egress and ArgoCD project alignment, an attempted Cilium CNI rollout that was **reverted** to stay compatible with OrbStack’s supported CNI, follow-up documentation, and a new default **nightly OrbStack stop/start window** on the Mac mini host (**23:59** / **04:59** local time).

**Highlights:**

- **Nightly shutdown/startup** — launchd schedule updated in-repo (`scripts/com.homelab.*.plist`) with matching docs; reload LaunchAgents on the host after pull
- **Network policies** — additional egress rules (e.g. monitoring → kubelet/coredns, authentik → internet) and migration of apps to the `apps` ArgoCD project (#129)
- **CNI** — Cilium was tried (#131) then **removed** (#133) because OrbStack requires its bundled CNI; docs now describe Flannel limitations and policy expectations

---

## Improvements

### feat(ops): nightly shutdown 23:59, startup 04:59

- Shutdown **23:30 → 23:59**; startup **06:30 → 04:59**
- Updated plist templates, wrapper script comments, and [Nightly Shutdown](docs/operations/nightly-shutdown.md) / [Architecture](docs/getting-started/architecture.md)

### chore(network): policy gaps, ArgoCD project cleanup (#129)

- `allow-egress-kubelet` for monitoring; `allow-egress-internet` for authentik; related fixes
- networking-policies and namespace-security use `apps` project; expanded `apps` destinations where needed

### fix(cni): remove Cilium for OrbStack compatibility (#133)

- Cilium Application and related values removed; cluster remains on OrbStack’s default CNI
- Documentation updated to reflect current networking posture

---

## Technical Notes

- **NetworkPolicy** on Flannel does not enforce L3/L4 isolation like a full CNI policy engine; default-deny and allow rules document intent and future portability
- **Host automation** is not applied by ArgoCD — after upgrading, copy plists to `~/Library/LaunchAgents/` and reload jobs per [nightly-shutdown.md](docs/operations/nightly-shutdown.md)

---

## Errata

- No known issues

---

**Release date:** 2026-03-30  
**Tag:** v1.11.0
