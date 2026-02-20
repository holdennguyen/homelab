#!/bin/bash
#
# OrbStack Kubernetes nightly shutdown script
# Safely stops the OrbStack Kubernetes cluster with logging and state checks
#
# This script is intended to be run via macOS launchd at 23:30 daily.
#
# Usage: /path/to/scripts/orb-stop.sh

set -euo pipefail

# Configuration
LOG_DIR="/var/log/homelab"
LOG_FILE="${LOG_DIR}/shutdown.log"
TIMESTAMP_FORMAT="%Y-%m-%d %H:%M:%S"

# Ensure log directory exists (may need sudo on first run)
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

log "INFO" "Starting OrbStack Kubernetes shutdown sequence"

# Check current cluster state
log "DEBUG" "Checking cluster current state"
if ! orb status k8s &>/dev/null; then
    log "INFO" "Cluster is not running or not accessible - nothing to stop"
    exit 0
fi

# Get detailed status
CLUSTER_STATUS=$(orb status k8s 2>&1) || true
log "DEBUG" "Current cluster status: ${CLUSTER_STATUS}"

# Check if cluster is actually running by attempting kubectl
if kubectl get nodes &>/dev/null; then
    # Check for running pods (excluding Completed pods)
    RUNNING_PODS=$(kubectl get pods --all-namespaces --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "${RUNNING_PODS}" -gt 0 ]; then
        log "INFO" "Found ${RUNNING_PODS} running pods across all namespaces"
    else
        log "INFO" "No running pods found"
    fi
else
    log "WARN" "kubectl cannot access cluster, but orb reports it exists"
fi

# Stop the cluster
log "INFO" "Stopping OrbStack Kubernetes cluster with 'orb stop k8s'"
if orb stop k8s; then
    log "INFO" "OrbStack stop command completed successfully"
else
    EXIT_CODE=$?
    log "ERROR" "OrbStack stop command failed with exit code ${EXIT_CODE}"
    exit ${EXIT_CODE}
fi

# Verify cluster has stopped
MAX_WAIT=30
WAITED=0
while [ ${WAITED} -lt ${MAX_WAIT} ]; do
    if ! orb status k8s &>/dev/null; then
        log "INFO" "Cluster has stopped successfully (verified after ${WAITED}s)"
        break
    fi
    sleep 2
    WAITED=$((WAITED + 2))
done

if [ ${WAITED} -ge ${MAX_WAIT} ]; then
    log "WARN" "Cluster stop verification timed out after ${MAX_WAIT}s, but stop command succeeded"
fi

# Final log entry
log "INFO" "Nightly shutdown sequence completed"

exit 0
