#!/bin/bash

source "$(dirname "$0")/helpers/common.sh"

TARGET_NAMESPACE=${1:-$APP_NAMESPACE}

log_warn "ATTENTION! This script will COMPLETELY DESTROY the namespace: <${TARGET_NAMESPACE}>"
log_warn "All Deployments, Services, Secrets, and Persistent Volumes inside it will be permanently lost"

while true; do
    read -p "Are you absolutely sure you want to proceed with the data erasing? (y/n): " yn
    case $yn in
        [Yy]* )
            log_info "Confirmation received. Starting environment destruction..."
            break
            ;;
        [Nn]* )
            log_info "Operation cancelled. Exiting safely"
            exit 0
            ;;
        * )
            echo "Please answer yes (y) or no (n)."
            ;;
    esac
done

log_info "Executing: kubectl delete namespace ${TARGET_NAMESPACE}..."

if ! kubectl delete namespace "${TARGET_NAMESPACE}"; then
    log_error "Failed to initiate deletion of namespace <${TARGET_NAMESPACE}> via Kubernetes API!"
    exit 1
fi

log_info "Deletion request accepted. Waiting for the namespace to be completely purged from the cluster..."

MAX_ATTEMPTS=30
COUNTER=0
SLEEP_SEC=5
NS_EXISTS=0

while [ $COUNTER -lt $MAX_ATTEMPTS ]; do
    if ! kubectl get namespace "${TARGET_NAMESPACE}" &>/dev/null; then
        NS_EXISTS=1
        break
    fi
    
    log_info "Namespace <${TARGET_NAMESPACE}> is still in 'Terminating' status. Waiting ${SLEEP_SEC} seconds..."
    sleep $SLEEP_SEC
    COUNTER=$((COUNTER + 1))
done

if [ $NS_EXISTS -ne 1 ]; then
    log_error "Timeout reached! Namespace <${TARGET_NAMESPACE}> is stuck in Terminating state. Manual intervention required"
    exit 1
fi

log_info "Namespace <${TARGET_NAMESPACE}> has been completely eradicated from the cluster"
log_info "The crash simulation completed successfully. The cluster is ready for the restore phase"

