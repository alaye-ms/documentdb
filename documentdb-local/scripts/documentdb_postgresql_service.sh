#!/bin/bash

set -euo pipefail

readonly ENV_FILE="/etc/documentdb/documentdb-postgresql.env"
readonly RUN_DIR="/var/run/postgresql"

log() {
    echo "[documentdb-postgresql-service] $*"
}

die() {
    echo "[documentdb-postgresql-service] ERROR: $*" >&2
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

run_as_documentdb() {
    if command_exists runuser; then
        runuser -u documentdb -- "$@"
    elif command_exists sudo; then
        sudo -u documentdb "$@"
    else
        local quoted_command=""
        quoted_command="$(printf '%q ' "$@")"
        su -s /bin/bash documentdb -c "${quoted_command}"
    fi
}

load_config() {
    if [[ ! -r "${ENV_FILE}" ]]; then
        log "No self-managed PostgreSQL state file found; nothing to do."
        exit 0
    fi

    # shellcheck disable=SC1090
    . "${ENV_FILE}"

    if [[ "${DOCUMENTDB_MANAGED_POSTGRES:-}" != "true" ]]; then
        log "Managed PostgreSQL is disabled; nothing to do."
        exit 0
    fi

    [[ "${PG_VERSION:-}" =~ ^[0-9]+$ ]] || die "PG_VERSION is missing or invalid in ${ENV_FILE}."
    [[ -n "${DATA_DIR:-}" ]] || die "DATA_DIR is missing from ${ENV_FILE}."
    [[ -d "${DATA_DIR}" ]] || die "Configured PostgreSQL data directory does not exist: ${DATA_DIR}"
}

resolve_pg_ctl() {
    local candidate=""
    local candidates=(
        "/usr/lib/postgresql/${PG_VERSION}/bin/pg_ctl"
        "/usr/pgsql-${PG_VERSION}/bin/pg_ctl"
    )

    for candidate in "${candidates[@]}"; do
        if [[ -x "${candidate}" ]]; then
            printf '%s' "${candidate}"
            return 0
        fi
    done

    die "Unable to find pg_ctl for PostgreSQL ${PG_VERSION}."
}

ensure_runtime_dir() {
    if [[ ! -d "${RUN_DIR}" ]]; then
        mkdir -p "${RUN_DIR}"
        chown documentdb:documentdb "${RUN_DIR}"
        chmod 2775 "${RUN_DIR}"
    fi
}

postgres_is_running() {
    run_as_documentdb "${PG_CTL}" -D "${DATA_DIR}" status >/dev/null 2>&1
}

start_postgres() {
    ensure_runtime_dir

    if postgres_is_running; then
        log "Restarting self-managed PostgreSQL cluster in ${DATA_DIR}."
        run_as_documentdb "${PG_CTL}" -D "${DATA_DIR}" -w restart
    else
        log "Starting self-managed PostgreSQL cluster in ${DATA_DIR}."
        run_as_documentdb "${PG_CTL}" -D "${DATA_DIR}" -l "${DATA_DIR}/pglog.log" -w start
    fi
}

stop_postgres() {
    if postgres_is_running; then
        log "Stopping self-managed PostgreSQL cluster in ${DATA_DIR}."
        run_as_documentdb "${PG_CTL}" -D "${DATA_DIR}" -w stop -m fast
    else
        log "Self-managed PostgreSQL cluster is already stopped."
    fi
}

main() {
    local action="${1:-}"

    [[ "$(id -u)" -eq 0 ]] || die "This helper must run as root."
    [[ "${action}" == "start" || "${action}" == "stop" ]] || die "Usage: $0 <start|stop>"

    load_config
    PG_CTL="$(resolve_pg_ctl)"

    case "${action}" in
        start)
            start_postgres
            ;;
        stop)
            stop_postgres
            ;;
    esac
}

main "$@"
