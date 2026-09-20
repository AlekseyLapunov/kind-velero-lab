#!/bin/bash

source "$(dirname "$0")/helpers/common.sh"

BACKUP_NAME="demoapp-backup-$(date +%Y%m%d-%H%M%S)"

log_info "Generating dynamic data integrity manifest..."

ORIG_POD=$(kubectl get pods -n "${APP_NAMESPACE}" -l app=demoapp -o jsonpath='{.items[0].metadata.name}')

TABLES=$(kubectl exec -n "${APP_NAMESPACE}" "${ORIG_POD}" -c postgres -- psql -U postgres -d demodb -t -A -c \
    "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE';")

if [ -z "${TABLES}" ]; then
    log_error "No tables found in the database!"
    exit 1
fi

CM_ARGS=()

for t in ${TABLES}; do
    log_info "Processing table: ${t}"
    
    CURRENT_METRICS=$(kubectl exec -n "${APP_NAMESPACE}" "${ORIG_POD}" -c postgres -- psql -U postgres -d demodb -t -A -c \
        "SELECT count(*), coalesce(md5(string_agg(t::text, '' ORDER BY t.*::text)), '') FROM ${t} AS t;")
    
    CURRENT_COUNT=$(echo "${CURRENT_METRICS}" | cut -d'|' -f1)
    CURRENT_HASH=$(echo "${CURRENT_METRICS}" | cut -d'|' -f2)
    
    log_info "Table <${t}> captured - Rows: ${CURRENT_COUNT}, MD5: ${CURRENT_HASH}"
    
    CM_ARGS+=("--from-literal=${t}-rows=${CURRENT_COUNT}")
    CM_ARGS+=("--from-literal=${t}-hash=${CURRENT_HASH}")
done

CM_ARGS+=("--from-literal=backed-up-tables=$(echo ${TABLES} | tr '\n' ' ')")

kubectl create configmap backup-integrity-manifest \
  --namespace="${APP_NAMESPACE}" \
  "${CM_ARGS[@]}" \
  --dry-run=client -o yaml | kubectl apply -f -

log_info "Dynamic integrity manifest saved to ConfigMap. Proceeding to Velero backup..."

log_info "Backup started: ${BACKUP_NAME}"

if ! velero backup create "${BACKUP_NAME}" \
       --include-namespaces "${APP_NAMESPACE}" \
       --default-volumes-to-fs-backup; then
    log_error "Problem sending request to create backup to the Velero API"
    exit 1
fi

log_info "Create backup request was successfully sent to the Velero API"

MAX_ATTEMPTS=60
COUNTER=0
SLEEP_SEC=5
PHASE="Initialized"

while [ $COUNTER -lt $MAX_ATTEMPTS ]; do
    PHASE=$(velero backup get "${BACKUP_NAME}" -o json 2>/dev/null | jq -r '.status.phase' 2>/dev/null || echo "Unknown")
    
    if [ "$PHASE" == "Completed" ] || [ "$PHASE" == "Failed" ] || [ "$PHASE" == "PartiallyFailed" ]; then
        break
    fi
    
    log_info "Current backup status: <${PHASE}>. Waiting ${SLEEP_SEC} seconds..."
    sleep $SLEEP_SEC
    COUNTER=$((COUNTER + 1))
done

if [ "$PHASE" != "Completed" ]; then
    log_error "Backup failed! Resulted in status: <${PHASE}>"
    log_info "Trying to fetch logs from Velero and save them under ${LOGS_DIR} path..."
    velero backup logs "${BACKUP_NAME}" > "${LOGS_DIR}/${BACKUP_NAME}-FAILED.log" || echo "Fetching Velero logs for backup failed"
    exit 1
fi

log_info "Backup was done successfully"

log_info "Trying to save Velero backup logs..."
if velero backup logs "${BACKUP_NAME}" > "${LOGS_DIR}/${BACKUP_NAME}.log"; then
    log_info "Backup log saved: ${LOGS_DIR}/${BACKUP_NAME}.log"
else
    log_warn "Could not fetch Velero backup logs but the status is 'Available'"
fi

log_info "Trying to save Velero detailed backup describe info..."

if velero backup describe "${BACKUP_NAME}" --details > "${LOGS_DIR}/${BACKUP_NAME}-describe-details.log"; then
    log_info "Detailed backup describe info saved: ${LOGS_DIR}/${BACKUP_NAME}-describe-details.log"
else
    log_warn "Could not fetch Velero detailed backup describe info"
fi
