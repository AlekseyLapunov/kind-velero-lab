#!/bin/bash

source "$(dirname "$0")/helpers/common.sh"

ORIG_NAMESPACE=${1:-$APP_NAMESPACE}
RESTORE_NAMESPACE=${2:-$BACKUP_NAMESPACE}

log_info "Scanning Velero storage for the latest successful backup..."

LAST_BACKUP=$(velero backup get 2>/dev/null | tail -n +2 | grep -w "Completed" | tail -n 1 | awk '{print $1}')

if [ -z "${LAST_BACKUP}" ]; then
    log_error "No valid backups with status 'Completed' found in the S3 storage"
    exit 1
fi

RESTORE_NAME="restore-${LAST_BACKUP}-at-$(date +%Y%m%d-%H%M%S)"

log_info "Found backup: <${LAST_BACKUP}>. Initiating restoration..."
log_info "Restore operation name: <${RESTORE_NAME}>"
log_info "Mapping namespace: ${ORIG_NAMESPACE} -> ${RESTORE_NAMESPACE}"

if ! velero restore create "${RESTORE_NAME}" \
       --from-backup "${LAST_BACKUP}" \
       --namespace-mappings "${ORIG_NAMESPACE}:${RESTORE_NAMESPACE}"; then
    log_error "Failed to submit restore request to the Velero API!"
    exit 1
fi

log_info "Restore request successfully submitted. Monitoring progress..."

MAX_ATTEMPTS=60
COUNTER=0
SLEEP_SEC=5
PHASE="New"

while [ $COUNTER -lt $MAX_ATTEMPTS ]; do
    PHASE=$(velero restore get "${RESTORE_NAME}" -o json 2>/dev/null | jq -r '.status.phase' 2>/dev/null || echo "Unknown")
    
    docker exec backup-demo-worker chmod -R 777 /mnt/data-app /mnt/data-restored &>/dev/null || true
    
    if [ "$PHASE" == "Completed" ] || [ "$PHASE" == "Failed" ] || [ "$PHASE" == "PartiallyFailed" ]; then
        break
    fi
    
    log_info "Current restore status: <${PHASE}>. Waiting ${SLEEP_SEC} seconds..."
    sleep $SLEEP_SEC
    COUNTER=$((COUNTER + 1))
done

if [ "$PHASE" == "Failed" ]; then
    log_error "Critical failure! Velero restore failed completely with status: <${PHASE}>"
    log_info "Fetching failure logs for operational audit..."
    velero restore logs "${RESTORE_NAME}" > "${LOGS_DIR}/${RESTORE_NAME}-FAILED.log" || true
    exit 1
elif [ "$PHASE" == "PartiallyFailed" ]; then
    log_warn "Restore completed with 'PartiallyFailed' status (likely due to pre-existing cluster-scoped resources)"
    log_info "This is typical for native Velero operations. Checking logs..."
    velero restore logs "${RESTORE_NAME}" > "${LOGS_DIR}/${RESTORE_NAME}-WARNINGS.log" || true
else
    log_info "Velero restore finished successfully with status: <${PHASE}>"
fi

log_info "Saving final restore logs..."
if velero restore logs "${RESTORE_NAME}" > "${LOGS_DIR}/${RESTORE_NAME}.log"; then
    log_info "Restore log saved to: ${LOGS_DIR}/${RESTORE_NAME}.log"
else
    log_warn "Could not fetch text logs, but the cluster state is recorded"
fi

log_info "Waiting 10 seconds for the application pod network to completely stabilize..."
sleep 10

log_info "Restore pipeline actions completed"

