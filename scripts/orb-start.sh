#!/bin/bash
#
# OrbStack Kubernetes nightly startup script
# Starts the OrbStack Kubernetes cluster and waits for health
#
# This script is intended to be run via macOS launchd at 06:30 daily.
# Launchd redirects stdout/stderr to ~/Library/Logs/homelab/startup.log,
# so this script writes to stdout only (no tee).
#
# Usage: /Users/holden.nguyen/homelab/scripts/orb-start.sh

set -euo pipefail

TIMESTAMP_FORMAT="%Y-%m-%d %H:%M:%S"
MAX_WAIT_CLUSTER_HEALTH=300  # 5 minutes max wait for cluster health
MAX_WAIT_ARGOCD=600          # 10 minutes max wait for ArgoCD sync

log() {
    local level="$1"
    local message="$2"
    echo "[$(date +"${TIMESTAMP_FORMAT}")] [${level}] ${message}"
}

if ! command -v orb &>/dev/null; then
    log "ERROR" "OrbStack CLI (orb) not found in PATH"
    exit 1
fi

log "INFO" "Starting OrbStack Kubernetes startup sequence"

# Check if cluster is already running (kubectl works when cluster is up; orb status k8s not in OrbStack 2.x)
if kubectl get nodes &>/dev/null; then
    log "INFO" "Cluster is already accessible - verifying health"
    NOT_READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -cv " Ready" || true)
    NOT_READY="${NOT_READY:-0}"
    if [ "${NOT_READY}" -eq 0 ]; then
        log "INFO" "Cluster is healthy - nothing to start"
        exit 0
    else
        log "WARN" "Cluster accessible but nodes not Ready - attempting restart"
        orb restart k8s || true
    fi
else
    log "INFO" "Starting OrbStack Kubernetes cluster with 'orb start k8s'"
    if orb start k8s; then
        log "INFO" "OrbStack start command completed successfully"
    else
        EXIT_CODE=$?
        log "ERROR" "OrbStack start command failed with exit code ${EXIT_CODE}"
        exit ${EXIT_CODE}
    fi
fi

# Wait for cluster to become accessible
log "INFO" "Waiting up to ${MAX_WAIT_CLUSTER_HEALTH}s for cluster to become healthy"
WAITED=0
CLUSTER_HEALTHY=false

while [ ${WAITED} -lt ${MAX_WAIT_CLUSTER_HEALTH} ]; do
    if kubectl get nodes &>/dev/null; then
        NOT_READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -cv " Ready" || true)
        NOT_READY="${NOT_READY:-0}"
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
    kubectl get nodes 2>&1 || true
fi

# Wait for critical system pods
log "INFO" "Checking core system pods"
WAITED=0
ALL_RUNNING=false
while [ ${WAITED} -lt ${MAX_WAIT_CLUSTER_HEALTH} ]; do
    ALL_RUNNING=true
    for ns in kube-system argocd external-secrets monitoring; do
        if kubectl get namespace "${ns}" &>/dev/null; then
            PENDING=$(kubectl get pods -n "${ns}" --field-selector=status.phase!=Running,status.phase!=Succeeded --no-headers 2>/dev/null | wc -l | tr -d ' ')
            if [ "${PENDING}" -gt 0 ]; then
                log "DEBUG" "Namespace ${ns} has ${PENDING} non-running pods"
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
    APPS=$(kubectl get applications -n argocd --no-headers -o custom-columns=:metadata.name 2>/dev/null || true)
    if [ -n "${APPS}" ]; then
        APP_COUNT=$(echo "${APPS}" | wc -w | tr -d ' ')
        for app in ${APPS}; do
            kubectl patch application "${app}" -n argocd \
                --type merge \
                -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}' 2>/dev/null || true
        done
        log "INFO" "ArgoCD refresh triggered for ${APP_COUNT} applications"
    else
        log "INFO" "No ArgoCD applications found to refresh"
    fi

    log "INFO" "Monitoring ArgoCD synchronization (max ${MAX_WAIT_ARGOCD}s)"
    WAITED=0
    while [ ${WAITED} -lt ${MAX_WAIT_ARGOCD} ]; do
        NOT_SYNCED=$(kubectl get applications -n argocd --no-headers 2>/dev/null | grep -cv " Synced " || true)
        NOT_HEALTHY=$(kubectl get applications -n argocd --no-headers 2>/dev/null | grep -cv " Healthy" || true)
        NOT_SYNCED="${NOT_SYNCED:-0}"
        NOT_HEALTHY="${NOT_HEALTHY:-0}"

        if [ "${NOT_SYNCED}" -eq 0 ] && [ "${NOT_HEALTHY}" -eq 0 ] && [ -n "${APPS}" ]; then
            log "INFO" "All ArgoCD applications are Synced and Healthy (took ${WAITED}s)"
            break
        fi

        if [ -z "${APPS}" ]; then
            log "INFO" "No ArgoCD applications present"
            break
        fi

        sleep 15
        WAITED=$((WAITED + 15))
    done

    if [ ${WAITED} -ge ${MAX_WAIT_ARGOCD} ]; then
        log "WARN" "ArgoCD not fully synced after ${MAX_WAIT_ARGOCD}s - some apps may still be progressing"
        kubectl get applications -n argocd 2>&1 || true
    fi
else
    log "INFO" "ArgoCD namespace not found - skipping refresh"
fi

log "INFO" "Nightly startup sequence completed"
log "INFO" "=== Cluster State Summary ==="
kubectl get nodes 2>&1 || true
kubectl get applications -n argocd 2>&1 || true
log "INFO" "=== End Summary ==="

exit 0
