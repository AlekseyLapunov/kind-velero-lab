#!/bin/bash

source "$(dirname "$0")/helpers/common.sh"

RESTORE_NAMESPACE=${1:-$BACKUP_NAMESPACE}

log_info "=== Starting restored data integrity audit ==="
log_info "Target Namespace: <${RESTORE_NAMESPACE}>"

log_info "Verifying Kubernetes resources status..."
if ! kubectl get pvc,pods,svc -n "${RESTORE_NAMESPACE}" &>/dev/null; then
    log_error "Some infrastructure components are missing in namespace <${RESTORE_NAMESPACE}>"
    exit 1
fi

POD_NAME=$(kubectl get pods -n "${RESTORE_NAMESPACE}" -l app=demoapp -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -z "${POD_NAME}" ]; then
    log_error "Could not find any active PostgreSQL pods with label 'app=demoapp' in namespace <${RESTORE_NAMESPACE}>"
    exit 1
fi

log_info "Active database pod located: <${POD_NAME}>. Initializing SQL query layer..."

log_info "Fetching dynamic integrity manifest from restored ConfigMap..."

if ! kubectl get configmap backup-integrity-manifest -n "${RESTORE_NAMESPACE}" &>/dev/null; then
    log_error "Critical error: backup-integrity-manifest ConfigMap was not found in restored namespace!"
    exit 1
fi

BACKED_UP_TABLES=$(kubectl get configmap backup-integrity-manifest -n "${RESTORE_NAMESPACE}" -o jsonpath='{.data.backed-up-tables}')

if [ -z "${BACKED_UP_TABLES}" ]; then
    log_error "Critical error: backed-up-tables metadata is missing in ConfigMap!"
    exit 1
fi

INTEGRITY_FAILED=0

for TARGET_TABLE in ${BACKED_UP_TABLES}; do
    log_info "Validating data integrity for table: ${TARGET_TABLE}"

    START_TIME=$(date +%s%N)

    DB_METRICS=$(kubectl exec -n "${RESTORE_NAMESPACE}" "${POD_NAME}" -c postgres -- psql -U postgres -d demodb -t -A -c \
        "SELECT count(*), coalesce(md5(string_agg(t::text, '' ORDER BY t.*::text)), '') FROM ${TARGET_TABLE} AS t;" 2>/dev/null)

    END_TIME=$(date +%s%N)
    DURATION=$(( (END_TIME - START_TIME) / 1000000 ))

    if [ -z "${DB_METRICS}" ]; then
        log_error "Database connection failed or target table <${TARGET_TABLE}> does not exist in restored DB!"
        INTEGRITY_FAILED=1
        continue
    fi

    ROW_COUNT=$(echo "${DB_METRICS}" | cut -d'|' -f1)
    ACTUAL_HASH=$(echo "${DB_METRICS}" | cut -d'|' -f2)

    log_info "Verification query executed in: ${DURATION} ms"

    EXPECTED_ROW_COUNT=$(kubectl get configmap backup-integrity-manifest -n "${RESTORE_NAMESPACE}" -o jsonpath="{.data.${TARGET_TABLE}-rows}")
    EXPECTED_HASH=$(kubectl get configmap backup-integrity-manifest -n "${RESTORE_NAMESPACE}" -o jsonpath="{.data.${TARGET_TABLE}-hash}")

    log_info "=== Audit Metrics for <${TARGET_TABLE}> ==="
    log_info "Restored Rows: ${ROW_COUNT} | Expected: ${EXPECTED_ROW_COUNT}"
    log_info "Restored MD5:  ${ACTUAL_HASH} | Expected: ${EXPECTED_HASH}"
    log_info "=========================================="

    if [ "${ROW_COUNT}" -ne "${EXPECTED_ROW_COUNT}" ]; then
        log_error "Integrity crash: Row count mismatch for table <${TARGET_TABLE}>!"
        INTEGRITY_FAILED=1
    fi

    if [ "${ACTUAL_HASH}" != "${EXPECTED_HASH}" ]; then
        log_error "Integrity crash: MD5 checksum mismatch for table <${TARGET_TABLE}>!"
        INTEGRITY_FAILED=1
    fi
done

if [ "${INTEGRITY_FAILED}" -eq 1 ]; then
    log_error "=== Verification verdict: FAILED ==="
    log_error "The restored dataset does NOT match the control reference. Backup is unvalidated!"
    exit 1
else
    log_info "=== Verification verdict: SUCCESS ==="
    log_info "Data integrity verified. The restored table matches the control dataset."
fi

exit 0

