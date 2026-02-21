#!/bin/bash
#
# OrbStack Kubernetes nightly shutdown script
# Safely stops the OrbStack Kubernetes cluster with logging and state checks
#
# This script is intended to be run via macOS launchd at 23:30 daily.
# Launchd redirects stdout/stderr to ~/Library/Logs/homelab/shutdown.log,
# so this script writes to stdout only (no tee).
#
# Usage: /Users/holden.nguyen/homelab/scripts/orb-stop.sh

set -euo pipefail

TIMESTAMP_FORMAT="%Y-%m-%d %H:%M:%S"

log() {
    local level="$1"
    local message="$2"
    echo "[$(date +"${TIMESTAMP_FORMAT}")] [${level}] ${message}"
}

if ! command -v orb &>/dev/null; then
    log "ERROR" "OrbStack CLI (orb) not found in PATH"
    exit 1
fi

log "INFO" "Starting OrbStack Kubernetes shutdown sequence"

# Check if cluster is running (kubectl works when cluster is up; orb status k8s not in OrbStack 2.x)
if ! kubectl get nodes &>/dev/null; then
    log "INFO" "Cluster is not running or not accessible - nothing to stop"
    exit 0
fi

CLUSTER_STATUS=$(kubectl get nodes 2>&1) || true
log "DEBUG" "Current cluster status: ${CLUSTER_STATUS}"

RUNNING_PODS=$(kubectl get pods --all-namespaces --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
log "INFO" "Found ${RUNNING_PODS} running pods across all namespaces"

log "INFO" "Stopping OrbStack Kubernetes cluster with 'orb stop k8s'"
if orb stop k8s; then
    log "INFO" "OrbStack stop command completed successfully"
else
    EXIT_CODE=$?
    log "ERROR" "OrbStack stop command failed with exit code ${EXIT_CODE}"
    exit ${EXIT_CODE}
fi

# Verify cluster has stopped (kubectl fails when cluster is down)
MAX_WAIT=30
WAITED=0
while [ ${WAITED} -lt ${MAX_WAIT} ]; do
    if ! kubectl get nodes &>/dev/null; then
        log "INFO" "Cluster has stopped successfully (verified after ${WAITED}s)"
        break
    fi
    sleep 2
    WAITED=$((WAITED + 2))
done

if [ ${WAITED} -ge ${MAX_WAIT} ]; then
    log "WARN" "Cluster stop verification timed out after ${MAX_WAIT}s, but stop command succeeded"
fi

log "INFO" "Nightly shutdown sequence completed"

exit 0
