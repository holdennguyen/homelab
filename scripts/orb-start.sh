#!/bin/bash
#
# OrbStack Kubernetes nightly startup script
# Starts the OrbStack Kubernetes cluster and waits for health
#
# This script is intended to be run via macOS launchd at 06:30 daily.
#
# Usage: /path/to/scripts/orb-start.sh

set -euo pipefail

# Configuration
LOG_DIR="/var/log/homelab"
LOG_FILE="${LOG_DIR}/startup.log"
TIMESTAMP_FORMAT="%Y-%m-%d %H:%M:%S"
MAX_WAIT_CLUSTER_HEALTH=300  # 5 minutes max wait for cluster health
MAX_WAIT_ARGOCD=600          # 10 minutes max wait for ArgoCD sync

# Ensure log directory exists
mkdir -p "${LOG_DIR}" 2>/dev/null || true

# Logging function
log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date +"${TIMESTAMP_FORMAT}")
    echo "[${timestamp}] [${level}] ${message}" | tee -a "${LOG_FILE}"
}

# Check if orb command is available
if ! command -v orb &>/dev/null; then
    log "ERROR" "OrbStack CLI (orb) not found in PATH"
    exit 1
fi

log "INFO" "Starting OrbStack Kubernetes startup sequence"

# Check if cluster is already running
if orb status k8s &>/dev/null; then
    log "INFO" "Cluster appears to be already running - verifying health"
    if kubectl get nodes &>/dev/null; then
        log "INFO" "Cluster is accessible - nothing to start"
        exit 0
    else
        log "WARN" "Orb reports running but kubectl cannot access - may need manual intervention"
        exit 0
    fi
fi

# Start the cluster
log "INFO" "Starting OrbStack Kubernetes cluster with 'orb start k8s'"
if orb start k8s; then
    log "INFO" "OrbStack start command completed successfully"
else
    EXIT_CODE=$?
    log "ERROR" "OrbStack start command failed with exit code ${EXIT_CODE}"
    exit ${EXIT_CODE}
fi

# Wait for cluster to become accessible
log "INFO" "Waiting up to ${MAX_WAIT_CLUSTER_HEALTH}s for cluster to become healthy"
WAITED=0
CLUSTER_HEALTHY=false

while [ ${WAITED} -lt ${MAX_WAIT_CLUSTER_HEALTH} ]; do
    if kubectl get nodes &>/dev/null; then
        # Check if all nodes are Ready
        NOT_READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -v "^.* Ready" | wc -l | tr -d ' ')
        if [ "${NOT_READY}" -eq 0 ]; then
            CLUSTER_HEALTHY=true
            log "INFO" "All nodes are Ready (took ${WAITED}s)"
            break
        else
            log "DEBUG" "Nodes not all Ready yet (${WAITED}s elapsed)"
        fi
    fi
    sleep 5
    WAITED=$((WAITED + 5))
done

if [ "${CLUSTER_HEALTHY}" = false ]; then
    log "ERROR" "Cluster did not become healthy within ${MAX_WAIT_CLUSTER_HEALTH}s"
    log "ERROR" "Current kubectl get nodes output:"
    kubectl get nodes 2>&1 | sed 's/^/    /' >> "${LOG_FILE}" || true
    # Continue anyway - cluster might recover
fi

# Wait for all system namespaces to have running pods
log "INFO" "Checking core system pods (kube-system, local-path-storage, ...)"
WAITED=0
while [ ${WAITED} -lt ${MAX_WAIT_CLUSTER_HEALTH} ]; do
    # Check critical system namespaces
    CRITICAL_NS="kube-system local-path-storage cert-manager ingress-nginx argo-cd"
    ALL_RUNNING=true
    for ns in ${CRITICAL_NS}; do
        if kubectl get namespace "${ns}" &>/dev/null; then
            PENDING_OR_FAILING=$(kubectl get pods -n "${ns}" --field-selector=status.phase!=Running,status.phase!=Succeeded --no-headers 2>/dev/null | wc -l | tr -d ' ')
            if [ "${PENDING_OR_FAILING}" -gt 0 ]; then
                log "DEBUG" "Namespace ${ns} has ${PENDING_OR_FAILING} non-running pods"
                ALL_RUNNING=false
            fi
        fi
    done

    if [ "${ALL_RUNNING}" = true ]; then
        log "INFO" "All critical system pods are running (took ${WAITED}s)"
        break
    fi

    sleep 10
    WAITED=$((WAITED + 10))
done

if [ "${ALL_RUNNING}" != true ]; then
    log "WARN" "Some system pods still not running after ${WAITED}s - continuing anyway"
fi

# Trigger ArgoCD refresh and wait for sync
if kubectl get namespace argocd &>/dev/null; then
    log "INFO" "Triggering ArgoCD hard refresh of all applications"
    # Annotate all apps to refresh
    APPS=$(kubectl get applications -n argocd --no-headers -o custom-columns=:metadata.name 2>/dev/null || true)
    if [ -n "${APPS}" ]; then
        for app in ${APPS}; do
            kubectl patch application "${app}" -n argocd \
                --type merge \
                -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}' 2>/dev/null || true
        done
        log "INFO" "ArgoCD refresh triggered for ${#APPS[@]} applications (if array) or similar count"
    else
        log "INFO" "No ArgoCD applications found to refresh"
    fi

    # Wait for ArgoCD health (best effort, don't fail if it takes too long)
    log "INFO" "Monitoring ArgoCD synchronization (max ${MAX_WAIT_ARGOCD}s)"
    WAITED=0
    while [ ${WAITED} -lt ${MAX_WAIT_ARGOCD} ]; do
        SYNCED=$(kubectl get applications -n argocd --no-headers 2>/dev/null | grep -v "^.* Synced" | grep -v "^.* Unknown" | wc -l | tr -d ' ')
        HEALTHY=$(kubectl get applications -n argocd --no-headers 2>/dev/null | grep -v "\(.* Healthy\)" | wc -l | tr -d ' ')

        if [ "${SYNCED}" -eq 0 ] && [ "${HEALTHY}" -eq 0 ] && [ -n "${APPS}" ]; then
            log "INFO" "All ArgoCD applications are Synced and Healthy (took ${WAITED}s)"
            break
        fi

        # If there are no apps, break immediately
        if [ -z "${APPS}" ]; then
            log "INFO" "No ArgoCD applications present"
            break
        fi

        sleep 15
        WAITED=$((WAITED + 15))
    done

    if [ ${WAITED} -ge ${MAX_WAIT_ARGOCD} ]; then
        log "WARN" "ArgoCD not fully synced after ${MAX_WAIT_ARGOCD}s - some apps may still be progressing"
        # List status for debugging
        kubectl get applications -n argocd --no-headers 2>&1 | sed 's/^/    /' >> "${LOG_FILE}" || true
    fi
else
    log "INFO" "ArgoCD namespace not found - skipping refresh"
fi

# Final verification and summary
log "INFO" "Nightly startup sequence completed"

# Summary of cluster state
log "INFO" "=== Cluster State Summary ==="
kubectl get nodes --no-headers 2>&1 | sed 's/^/    /' >> "${LOG_FILE}" || true
kubectl get pods --all-namespaces --no-headers 2>&1 | tail -5 >> "${LOG_FILE}" || true
log "INFO" "=== End Summary ==="

exit 0
