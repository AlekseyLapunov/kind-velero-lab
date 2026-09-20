#!/bin/bash

set -euo pipefail

CALLER_BASEDIR="$(cd "$(dirname "$0")" && pwd)"

export LOGS_DIR="${CALLER_BASEDIR}/logs"
export BACKUP_NAMESPACE="app-restored"
export APP_NAMESPACE="app"

mkdir -p "${LOGS_DIR}"

log_info() {
    echo -e "[\033[0;32m$(date '+%Y-%m-%d %H:%M:%S')\033[0m] [INFO] $1"
}

log_warn() {
    echo -e "[\033[0;33m$(date '+%Y-%m-%d %H:%M:%S')\033[0m] [WARN] $1"
}

log_error() {
    echo -e "[\033[0;31m$(date '+%Y-%m-%d %H:%M:%S')\033[0m] [ERROR] $1" >&2
}

error_trap() {
    local exit_code=$?
    local line_number=$1
    if [ $exit_code -ne 0 ]; then
        log_error "Script crashed at line ${line_number}; Exit code: ${exit_code}"
    fi
    exit $exit_code
}

trap 'error_trap $LINENO' ERR

