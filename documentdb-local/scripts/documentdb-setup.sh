#!/bin/bash

set -euo pipefail

SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [[ -L "${SCRIPT_SOURCE}" ]]; do
    SCRIPT_DIR="$(cd -P "$(dirname "${SCRIPT_SOURCE}")" && pwd)"
    SCRIPT_SOURCE="$(readlink "${SCRIPT_SOURCE}")"
    [[ "${SCRIPT_SOURCE}" != /* ]] && SCRIPT_SOURCE="${SCRIPT_DIR}/${SCRIPT_SOURCE}"
done
SCRIPT_DIR="$(cd -P "$(dirname "${SCRIPT_SOURCE}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

readonly POSTGRES_CONF_BLOCK_START="# >>> documentdb-setup managed configuration >>>"
readonly POSTGRES_CONF_BLOCK_END="# <<< documentdb-setup managed configuration <<<"
readonly PG_HBA_BLOCK_START="# >>> documentdb-setup managed hba >>>"
readonly PG_HBA_BLOCK_END="# <<< documentdb-setup managed hba <<<"
readonly POSTGRES_SERVICE_ENV_FILE="/etc/documentdb/documentdb-postgresql.env"
readonly DEFAULT_PG_PORT="9712"
readonly DEFAULT_GATEWAY_PORT="10260"
readonly DEFAULT_DATA_DIR="/var/lib/documentdb/data"
readonly PG_SOCKET_DIR="/var/run/postgresql"

VERBOSE=false
USERNAME=""
PASSWORD=""
PASSWORD_FILE=""
TEMP_FILES=()
PG_VERSION="${PG_VERSION:-}"
PG_VERSION_EXPLICIT=false
PG_PORT="${DEFAULT_PG_PORT}"
GATEWAY_PORT="${DEFAULT_GATEWAY_PORT}"
DATA_DIR="${DEFAULT_DATA_DIR}"
DATA_DIR_EXPLICIT=false
SKIP_PG_INIT=false
NO_ENABLE=false
LOAD_SAMPLE_DATA=false
PG_OWNER=""
PG_OWNER_EXPLICIT=false

GATEWAY_BINARY=""
CONFIG_FILE=""
SAMPLE_DATA_DIR=""
INIT_DATA_SCRIPT=""
HAS_WORKING_SYSTEMD=false
CAN_LOAD_SAMPLE_DATA=false
HAS_EXTENDED_RUM=false
EXTENSION_CONTROL_FILE=""
EXTENDED_RUM_CONTROL_FILE=""
PG_BIN_DIR=""
PG_CONFIG=""
INITDB=""
PG_CTL=""
PSQL=""
PG_ISREADY=""
LIVE_CLUSTER_PID=""
LIVE_DATA_DIR=""
LIVE_CONFIG_FILE=""
LIVE_HBA_FILE=""
LIVE_PRELOAD_LIBRARIES=""
PG_CONFIG_CHANGED=false

error() {
    local line_number="$1"
    local exit_code="${2:-1}"
    cleanup_temp_files
    echo "Error on or near line ${line_number}; exiting with status ${exit_code}" >&2
    exit "${exit_code}"
}
trap 'error ${LINENO} $?' ERR
trap cleanup_temp_files EXIT

usage() {
    cat <<'EOF'
Usage: documentdb-setup --username <USER> [--password <PASS> | --password-file <FILE>] [OPTIONS]

Required:
  --username <USER>       MongoDB-compatible username to create

Authentication (choose one):
  --password <PASS>       Password for the user
  --password-file <FILE>  Read the password from a file
                          (can also set DOCUMENTDB_PASSWORD env var)

Options:
  --pg-version <VER>      PostgreSQL version (auto-detected if not specified)
  --pg-port <PORT>        PostgreSQL port (default: 9712)
  --gateway-port <PORT>   Gateway listen port (default: 10260)
  --data-dir <DIR>        PostgreSQL data directory (default: /var/lib/documentdb/data)
  --skip-pg-init          Use an existing PostgreSQL cluster; still rewrites
                          listen_addresses, shared_preload_libraries, and
                          localhost HBA entries while preserving its SSL setting
  --no-enable             Do not start the gateway after setup
  --load-sample-data      Load built-in sample data after setup
  --pg-owner <USER>       PostgreSQL cluster owner (default: auto-detect)
  --verbose               Show detailed output
  -h, --help              Show this help message
EOF
}

log_info() {
    echo "[documentdb-setup] $*"
}

log_warn() {
    echo "[documentdb-setup] WARNING: $*" >&2
}

log_verbose() {
    if [[ "${VERBOSE}" == "true" ]]; then
        echo "[documentdb-setup] $*"
    fi
}

log_success() {
    echo "[documentdb-setup] SUCCESS: $*"
}

die() {
    echo "[documentdb-setup] ERROR: $*" >&2
    exit 1
}

cleanup_temp_files() {
    if (( ${#TEMP_FILES[@]} == 0 )); then
        return 0
    fi

    rm -f "${TEMP_FILES[@]}" 2>/dev/null || true
    TEMP_FILES=()
}

register_temp_file() {
    TEMP_FILES+=("$1")
}

create_temp_file() {
    local target_var="$1"
    local template="${2:-}"
    local created_file=""
    local -n target_ref="${target_var}"

    if [[ -n "${template}" ]]; then
        created_file="$(mktemp "${template}")"
    else
        created_file="$(mktemp)"
    fi

    register_temp_file "${created_file}"
    target_ref="${created_file}"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

trim_whitespace() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "${value}"
}

normalize_whitespace() {
    local value="$1"
    value="$(printf '%s' "${value}" | tr '\t' ' ')"
    value="$(printf '%s' "${value}" | sed -E 's/[[:space:]]+/ /g')"
    value="$(trim_whitespace "${value}")"
    printf '%s' "${value}"
}

strip_wrapping_quotes() {
    local value="$1"
    if [[ "${value}" == \'*\' && "${value}" == *\' ]]; then
        value="${value:1:${#value}-2}"
    elif [[ "${value}" == \"*\" && "${value}" == *\" ]]; then
        value="${value:1:${#value}-2}"
    fi
    printf '%s' "${value}"
}

array_contains() {
    local needle="$1"
    shift || true
    local item=""
    for item in "$@"; do
        if [[ "${item}" == "${needle}" ]]; then
            return 0
        fi
    done
    return 1
}

preserve_file_metadata() {
    local source_file="$1"
    local target_file="$2"
    if [[ -e "${source_file}" ]]; then
        chown --reference="${source_file}" "${target_file}"
        chmod --reference="${source_file}" "${target_file}"
    fi
}

strip_managed_block() {
    local target_file="$1"
    local block_start="$2"
    local block_end="$3"

    if [[ ! -f "${target_file}" ]]; then
        return 0
    fi

    awk -v start="${block_start}" -v end="${block_end}" '
        $0 == start { skip = 1; next }
        $0 == end { skip = 0; next }
        !skip { print }
    ' "${target_file}"
}

rewrite_with_managed_block() {
    local target_file="$1"
    local block_start="$2"
    local block_end="$3"
    local block_content="$4"
    local stripped_file=""
    local temp_file=""

    create_temp_file stripped_file
    create_temp_file temp_file
    strip_managed_block "${target_file}" "${block_start}" "${block_end}" > "${stripped_file}"

    {
        cat "${stripped_file}"
        if [[ -n "${block_content}" ]]; then
            if [[ -s "${stripped_file}" ]]; then
                printf '\n'
            fi
            printf '%s\n' "${block_start}"
            printf '%s\n' "${block_content}"
            printf '%s\n' "${block_end}"
        fi
    } > "${temp_file}"

    preserve_file_metadata "${target_file}" "${temp_file}"
    mv "${temp_file}" "${target_file}"
    rm -f "${stripped_file}"
}

has_line_outside_managed_block() {
    local target_file="$1"
    local block_start="$2"
    local block_end="$3"
    local line_to_find="$4"
    local stripped_file=""

    create_temp_file stripped_file
    strip_managed_block "${target_file}" "${block_start}" "${block_end}" > "${stripped_file}"
    if grep -Fqx "${line_to_find}" "${stripped_file}"; then
        rm -f "${stripped_file}"
        return 0
    fi
    rm -f "${stripped_file}"
    return 1
}

has_normalized_line_outside_managed_block() {
    local target_file="$1"
    local block_start="$2"
    local block_end="$3"
    local line_to_find="$4"
    local stripped_file=""
    local normalized_target=""
    local matched=false

    create_temp_file stripped_file
    strip_managed_block "${target_file}" "${block_start}" "${block_end}" > "${stripped_file}"
    normalized_target="$(normalize_whitespace "${line_to_find}")"

    while IFS= read -r candidate_line; do
        if [[ "$(normalize_whitespace "${candidate_line}")" == "${normalized_target}" ]]; then
            matched=true
            break
        fi
    done < "${stripped_file}"

    rm -f "${stripped_file}"
    if [[ "${matched}" == "true" ]]; then
        return 0
    fi
    return 1
}

update_json_file() {
    local json_file="$1"
    local temp_file=""
    create_temp_file temp_file

    jq \
        --argjson pgport "${PG_PORT}" \
        --argjson gwport "${GATEWAY_PORT}" \
        --arg pguser "documentdb" \
        '.PostgresPort = $pgport
         | .GatewayListenPort = $gwport
         | .PostgresSystemUser = $pguser
         | .PostgresDataUser = $pguser' \
        "${json_file}" > "${temp_file}"

    preserve_file_metadata "${json_file}" "${temp_file}"
    mv "${temp_file}" "${json_file}"
}

resolve_password() {
    if [[ -n "${PASSWORD}" && -n "${PASSWORD_FILE}" ]]; then
        die "Specify only one of --password or --password-file."
    fi

    if [[ -n "${PASSWORD_FILE}" ]]; then
        [[ -r "${PASSWORD_FILE}" ]] || die "--password-file ${PASSWORD_FILE} is not readable."
        PASSWORD="$(< "${PASSWORD_FILE}")"
    elif [[ -z "${PASSWORD}" && -n "${DOCUMENTDB_PASSWORD:-}" ]]; then
        PASSWORD="${DOCUMENTDB_PASSWORD}"
    fi

    [[ -n "${PASSWORD}" ]] || die "--password is required (or use --password-file or set DOCUMENTDB_PASSWORD env var)."
}

create_documentdb_user() {
    local owner="$1"
    local port="$2"
    local username="$3"
    local password="$4"
    local user_bson=""
    local user_bson_file=""

    local password_file=""

    create_temp_file password_file
    printf '%s' "${password}" > "${password_file}"
    chmod 600 "${password_file}"

    user_bson="$(
        jq -cn \
            --arg user "${username}" \
            --rawfile pwd "${password_file}" \
            '{createUser: $user, pwd: $pwd, roles: [{role: "readWriteAnyDatabase", db: "admin"}, {role: "clusterAdmin", db: "admin"}]}'
    )"
    rm -f "${password_file}"

    create_temp_file user_bson_file
    printf '%s' "${user_bson}" > "${user_bson_file}"
    chmod 600 "${user_bson_file}"
    chown "${owner}" "${user_bson_file}"

    run_as_user "${owner}" env "USER_BSON_FILE=${user_bson_file}" "${PSQL}" -p "${port}" -d postgres -X -v ON_ERROR_STOP=1 <<'SQL'
\set user_bson `cat "$USER_BSON_FILE"`
SELECT documentdb_api.create_user(:'user_bson'::documentdb_core.bson);
SQL
}

run_as_user() {
    local target_user="$1"
    shift

    if command_exists runuser; then
        runuser -u "${target_user}" -- "$@"
    elif command_exists sudo; then
        sudo -u "${target_user}" "$@"
    else
        local quoted_command=""
        quoted_command="$(printf '%q ' "$@")"
        su -s /bin/bash "${target_user}" -c "${quoted_command}"
    fi
}

run_as_user_shell() {
    local target_user="$1"
    local shell_command="$2"

    if command_exists runuser; then
        runuser -u "${target_user}" -- bash -lc "${shell_command}"
    elif command_exists sudo; then
        sudo -u "${target_user}" bash -lc "${shell_command}"
    else
        su -s /bin/bash "${target_user}" -c "${shell_command}"
    fi
}

find_listener_pid() {
    local port="$1"
    local pid=""

    if command_exists lsof; then
        pid="$(lsof -tiTCP:"${port}" -sTCP:LISTEN 2>/dev/null | head -n 1 || true)"
    fi

    if [[ -z "${pid}" ]] && command_exists ss; then
        pid="$(ss -ltnp "( sport = :${port} )" 2>/dev/null \
            | grep -oE 'pid=[0-9]+' \
            | head -n 1 \
            | cut -d= -f2 || true)"
    fi

    printf '%s' "${pid}"
}

wait_for_listener_to_clear() {
    local port="$1"
    local timeout_seconds="${2:-30}"
    local attempt=0
    local max_attempts=$(( timeout_seconds * 10 ))

    while (( attempt < max_attempts )); do
        if [[ -z "$(find_listener_pid "${port}")" ]]; then
            return 0
        fi
        sleep 0.1
        attempt=$(( attempt + 1 ))
    done

    return 1
}

listener_looks_like_postgres() {
    local pid="$1"
    local command_name=""
    local command_line=""

    command_name="$(ps -o comm= -p "${pid}" 2>/dev/null | awk '{print $1}' || true)"
    command_line="$(ps -o args= -p "${pid}" 2>/dev/null || true)"

    if [[ "${command_name}" == "postgres" || "${command_name}" == "postmaster" ]]; then
        return 0
    fi

    if [[ "${command_line}" == *postgres* ]]; then
        return 0
    fi

    return 1
}

listener_looks_like_gateway() {
    local pid="$1"
    local exe_path=""
    local command_line=""

    # Prefer /proc/pid/exe which is not truncated
    if [[ -L "/proc/${pid}/exe" ]]; then
        exe_path="$(readlink -f "/proc/${pid}/exe" 2>/dev/null || true)"
        if [[ "$(basename "${exe_path}" 2>/dev/null)" == "documentdb_gateway" ]]; then
            return 0
        fi
    fi

    # Fallback to full command line (args=) which is also not truncated
    command_line="$(ps -o args= -p "${pid}" 2>/dev/null || true)"
    if [[ "$(basename "${command_line%% *}" 2>/dev/null)" == "documentdb_gateway" ]]; then
        return 0
    fi

    return 1
}

resolve_nologin_shell() {
    if [[ -x /usr/sbin/nologin ]]; then
        printf '%s' "/usr/sbin/nologin"
    elif [[ -x /sbin/nologin ]]; then
        printf '%s' "/sbin/nologin"
    else
        printf '%s' "/bin/false"
    fi
}

ensure_documentdb_runtime_user() {
    local nologin_shell=""
    nologin_shell="$(resolve_nologin_shell)"

    if ! getent group documentdb >/dev/null 2>&1; then
        groupadd --system documentdb
    fi

    if ! id -u documentdb >/dev/null 2>&1; then
        useradd \
            --system \
            --no-create-home \
            --home-dir /var/lib/documentdb \
            --shell "${nologin_shell}" \
            --gid documentdb \
            documentdb
    fi

    mkdir -p /var/lib/documentdb
    chown documentdb:documentdb /var/lib/documentdb
    chmod 755 /var/lib/documentdb
}

has_working_systemd() {
    command_exists systemctl && [[ -d /run/systemd/system ]]
}

resolve_gateway_binary() {
    local packaged_path="/usr/bin/documentdb_gateway"
    local repo_path="${REPO_ROOT}/pg_documentdb_gw/target/release-with-symbols/documentdb_gateway"

    if [[ -x "${packaged_path}" ]]; then
        printf '%s' "${packaged_path}"
        return 0
    fi

    if [[ -x "${repo_path}" ]]; then
        printf '%s' "${repo_path}"
        return 0
    fi

    return 1
}

resolve_config_file() {
    local packaged_path="/etc/documentdb/SetupConfiguration.json"
    local repo_path="${REPO_ROOT}/pg_documentdb_gw/SetupConfiguration.json"

    if [[ -f "${packaged_path}" ]]; then
        printf '%s' "${packaged_path}"
        return 0
    fi

    if [[ -f "${repo_path}" ]]; then
        printf '%s' "${repo_path}"
        return 0
    fi

    return 1
}

resolve_sample_data_dir() {
    local packaged_path="/usr/share/documentdb/sample-data"
    local repo_path="${REPO_ROOT}/documentdb-local/sample-data"

    if [[ -d "${packaged_path}" ]]; then
        printf '%s' "${packaged_path}"
        return 0
    fi

    if [[ -d "${repo_path}" ]]; then
        printf '%s' "${repo_path}"
        return 0
    fi

    return 1
}

resolve_init_data_script() {
    local packaged_path="/usr/share/documentdb/scripts/init_documentdb_data.sh"
    local repo_path="${SCRIPT_DIR}/init_documentdb_data.sh"

    if [[ -x "${packaged_path}" ]]; then
        printf '%s' "${packaged_path}"
        return 0
    fi

    if [[ -x "${repo_path}" ]]; then
        printf '%s' "${repo_path}"
        return 0
    fi

    return 1
}

has_systemd_unit_file() {
    local unit_name="$1"

    if [[ "${HAS_WORKING_SYSTEMD}" != "true" ]]; then
        return 1
    fi

    systemctl list-unit-files "${unit_name}" >/dev/null 2>&1
}

persist_self_managed_postgres_state() {
    local temp_file=""

    install -d -m 0755 /etc/documentdb
    create_temp_file temp_file
    chmod 600 "${temp_file}"

    {
        printf 'DOCUMENTDB_MANAGED_POSTGRES=true\n'
        printf 'PG_VERSION=%q\n' "${PG_VERSION}"
        printf 'DATA_DIR=%q\n' "${DATA_DIR}"
    } > "${temp_file}"

    mv "${temp_file}" "${POSTGRES_SERVICE_ENV_FILE}"
    chmod 600 "${POSTGRES_SERVICE_ENV_FILE}"
}

clear_self_managed_postgres_state() {
    rm -f "${POSTGRES_SERVICE_ENV_FILE}"
}

sync_self_managed_postgres_service_state() {
    if [[ "${SKIP_PG_INIT}" == "true" ]]; then
        clear_self_managed_postgres_state
        if has_systemd_unit_file documentdb-postgresql.service; then
            systemctl disable documentdb-postgresql >/dev/null 2>&1 || true
        fi
        return 0
    fi

    persist_self_managed_postgres_state
}

set_postgres_binary_paths() {
    local major_version="$1"
    local candidate_paths=(
        "/usr/lib/postgresql/${major_version}/bin"
        "/usr/pgsql-${major_version}/bin"
    )
    local candidate=""

    for candidate in "${candidate_paths[@]}"; do
        if [[ -x "${candidate}/pg_config" ]]; then
            PG_VERSION="${major_version}"
            PG_BIN_DIR="${candidate}"
            PG_CONFIG="${candidate}/pg_config"
            INITDB="${candidate}/initdb"
            PG_CTL="${candidate}/pg_ctl"
            PSQL="${candidate}/psql"
            PG_ISREADY="${candidate}/pg_isready"
            return 0
        fi
    done

    return 1
}

detect_postgres_installation() {
    local best_with_extension=0
    local best_without_extension=0
    local candidate_path=""
    local candidate_version=""
    local sharedir=""
    local has_extension=false

    if [[ "${PG_VERSION_EXPLICIT}" == "true" ]]; then
        set_postgres_binary_paths "${PG_VERSION}" || die "PostgreSQL ${PG_VERSION} not found in standard Debian or RHEL paths."
        return 0
    fi

    for candidate_path in /usr/lib/postgresql/*/bin /usr/pgsql-*/bin; do
        if [[ ! -x "${candidate_path}/pg_config" ]]; then
            continue
        fi

        candidate_version="$(basename "$(dirname "${candidate_path}")" | sed 's/^pgsql-//')"
        if [[ ! "${candidate_version}" =~ ^[0-9]+$ ]]; then
            continue
        fi

        sharedir="$("${candidate_path}/pg_config" --sharedir)"
        has_extension=false
        if [[ -f "${sharedir}/extension/documentdb.control" ]]; then
            has_extension=true
        fi

        if [[ "${has_extension}" == "true" ]] && (( candidate_version > best_with_extension )); then
            best_with_extension="${candidate_version}"
        fi

        if (( candidate_version > best_without_extension )); then
            best_without_extension="${candidate_version}"
        fi
    done

    if (( best_with_extension > 0 )); then
        set_postgres_binary_paths "${best_with_extension}" || die "Failed to resolve PostgreSQL ${best_with_extension} binaries after detection."
        return 0
    fi

    if (( best_without_extension > 0 )); then
        set_postgres_binary_paths "${best_without_extension}" || die "Failed to resolve PostgreSQL ${best_without_extension} binaries after detection."
        return 0
    fi

    die "PostgreSQL not found. Install PostgreSQL first (for example: apt install postgresql-17)."
}

read_shared_preload_libraries_from_file() {
    local config_path="$1"
    local current_value=""

    if [[ ! -f "${config_path}" ]]; then
        return 0
    fi

    current_value="$(
        awk -F= '
            /^[[:space:]]*#/ { next }
            $0 ~ /^[[:space:]]*shared_preload_libraries[[:space:]]*=/ {
                value=$0
                sub(/^[^=]*=/, "", value)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
                print value
            }
        ' "${config_path}" | tail -n 1
    )"

    current_value="$(strip_wrapping_quotes "${current_value}")"
    printf '%s' "${current_value}"
}

merge_shared_preload_libraries() {
    local current_value="$1"
    local cleaned_current=""
    local item=""
    local joined=""
    local -a merged_items=()
    local -a current_items=()
    local -a required_items=(
        "pg_cron"
        "pg_documentdb_core"
        "pg_documentdb"
    )

    if [[ "${HAS_EXTENDED_RUM}" == "true" ]]; then
        required_items+=("pg_documentdb_extended_rum")
    fi

    cleaned_current="$(strip_wrapping_quotes "${current_value}")"
    if [[ -n "${cleaned_current}" ]]; then
        IFS=',' read -r -a current_items <<< "${cleaned_current}"
        for item in "${current_items[@]}"; do
            item="$(trim_whitespace "${item}")"
            [[ -z "${item}" ]] && continue
            if ! array_contains "${item}" "${merged_items[@]}"; then
                merged_items+=("${item}")
            fi
        done
    fi

    for item in "${required_items[@]}"; do
        if ! array_contains "${item}" "${merged_items[@]}"; then
            merged_items+=("${item}")
        fi
    done

    for item in "${merged_items[@]}"; do
        joined+="${joined:+, }${item}"
    done

    printf '%s' "${joined}"
}

build_postgres_conf_block() {
    local merged_preload="$1"
    local ssl_setting="${2:-}"
    local postgres_conf_block=""

    postgres_conf_block=$(
        cat <<EOF
listen_addresses = 'localhost'
port = ${PG_PORT}
shared_preload_libraries = '${merged_preload}'
cron.database_name = 'postgres'
EOF
    )

    if [[ -n "${ssl_setting}" ]]; then
        postgres_conf_block+=$'\n'"ssl = ${ssl_setting}"
    fi

    postgres_conf_block+=$'\n'"documentdb.enableBackgroundWorker = true"
    postgres_conf_block+=$'\n'"documentdb.enableBackgroundWorkerJobs = true"
    postgres_conf_block+=$'\n'"documentdb.indexBuildsScheduledOnBgWorker = false"

    if [[ "${HAS_EXTENDED_RUM}" == "true" ]]; then
        postgres_conf_block+=$'\n'"documentdb.rum_library_load_option = 'require_documentdb_extended_rum'"
        postgres_conf_block+=$'\n'"documentdb.alternate_index_handler_name = 'extended_rum'"
    fi

    printf '%s' "${postgres_conf_block}"
}

build_desired_hba_block() {
    local hba_file="$1"
    local desired_hba_block=""
    local hba_line=""
    local -a desired_hba_lines=(
        "host    all    all    127.0.0.1/32    trust"
        "host    all    all    ::1/128         trust"
    )

    for hba_line in "${desired_hba_lines[@]}"; do
        if ! has_normalized_line_outside_managed_block "${hba_file}" "${PG_HBA_BLOCK_START}" "${PG_HBA_BLOCK_END}" "${hba_line}"; then
            desired_hba_block+="${desired_hba_block:+$'\n'}${hba_line}"
        fi
    done

    printf '%s' "${desired_hba_block}"
}

apply_managed_postgres_settings() {
    local config_file="$1"
    local hba_file="$2"
    local merged_preload="$3"
    local ssl_setting="${4:-}"
    local warn_on_new_trust_entries="${5:-false}"
    local postgres_conf_block=""
    local desired_hba_block=""

    postgres_conf_block="$(build_postgres_conf_block "${merged_preload}" "${ssl_setting}")"
    rewrite_with_managed_block "${config_file}" "${POSTGRES_CONF_BLOCK_START}" "${POSTGRES_CONF_BLOCK_END}" "${postgres_conf_block}"

    desired_hba_block="$(build_desired_hba_block "${hba_file}")"
    if [[ "${warn_on_new_trust_entries}" == "true" && -n "${desired_hba_block}" ]]; then
        log_warn "Adding localhost trust entries to ${hba_file} so the gateway can connect as the documentdb runtime user."
    fi
    rewrite_with_managed_block "${hba_file}" "${PG_HBA_BLOCK_START}" "${PG_HBA_BLOCK_END}" "${desired_hba_block}"
}

resolve_live_cluster_metadata() {
    local port="$1"
    local expected_owner="${2:-}"
    local detected_owner=""
    local server_version_num=""
    local detected_major=""

    LIVE_CLUSTER_PID="$(find_listener_pid "${port}")"
    [[ -n "${LIVE_CLUSTER_PID}" ]] || die "No process is listening on PostgreSQL port ${port}."

    if ! listener_looks_like_postgres "${LIVE_CLUSTER_PID}"; then
        die "Port ${port} is in use by a non-PostgreSQL process."
    fi

    detected_owner="$(ps -o user= -p "${LIVE_CLUSTER_PID}" 2>/dev/null | awk '{print $1}' || true)"
    [[ -n "${detected_owner}" ]] || die "Unable to determine the PostgreSQL process owner on port ${port}."

    if [[ -n "${expected_owner}" && "${expected_owner}" != "${detected_owner}" ]]; then
        die "--pg-owner (${expected_owner}) does not match the running PostgreSQL process owner (${detected_owner}) on port ${port}."
    fi

    PG_OWNER="${detected_owner}"

    LIVE_DATA_DIR="$(
        run_as_user "${PG_OWNER}" "${PSQL}" -p "${port}" -d postgres -X -tA -v ON_ERROR_STOP=1 <<'SQL'
SHOW data_directory;
SQL
    )"
    LIVE_CONFIG_FILE="$(
        run_as_user "${PG_OWNER}" "${PSQL}" -p "${port}" -d postgres -X -tA -v ON_ERROR_STOP=1 <<'SQL'
SHOW config_file;
SQL
    )"
    LIVE_HBA_FILE="$(
        run_as_user "${PG_OWNER}" "${PSQL}" -p "${port}" -d postgres -X -tA -v ON_ERROR_STOP=1 <<'SQL'
SHOW hba_file;
SQL
    )"
    LIVE_PRELOAD_LIBRARIES="$(
        run_as_user "${PG_OWNER}" "${PSQL}" -p "${port}" -d postgres -X -tA -v ON_ERROR_STOP=1 <<'SQL'
SHOW shared_preload_libraries;
SQL
    )"
    server_version_num="$(
        run_as_user "${PG_OWNER}" "${PSQL}" -p "${port}" -d postgres -X -tA -v ON_ERROR_STOP=1 <<'SQL'
SHOW server_version_num;
SQL
    )"

    if [[ ! "${server_version_num}" =~ ^[0-9]+$ ]]; then
        die "Unable to parse PostgreSQL server_version_num from the running cluster."
    fi

    detected_major="$(( server_version_num / 10000 ))"
    if [[ "${PG_VERSION_EXPLICIT}" == "true" && "${PG_VERSION}" != "${detected_major}" ]]; then
        die "The running PostgreSQL cluster is version ${detected_major}, but --pg-version ${PG_VERSION} was requested."
    fi

    set_postgres_binary_paths "${detected_major}" || die "Unable to resolve PostgreSQL ${detected_major} client binaries for the running cluster."
    refresh_extension_state
    validate_documentdb_extension_installation
    log_verbose "Resolved running PostgreSQL cluster metadata: data_directory=${LIVE_DATA_DIR}, config_file=${LIVE_CONFIG_FILE}, hba_file=${LIVE_HBA_FILE}"
}

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        die "documentdb-setup must be run as root (use sudo)."
    fi
}

validate_required_arguments() {
    [[ -n "${USERNAME}" ]] || die "--username is required."
    resolve_password

    if [[ "${NO_ENABLE}" == "true" && "${LOAD_SAMPLE_DATA}" == "true" ]]; then
        die "--load-sample-data requires a running gateway and cannot be combined with --no-enable."
    fi
}

resolve_runtime_paths() {
    GATEWAY_BINARY="$(resolve_gateway_binary)" || die "Unable to find the gateway binary at /usr/bin/documentdb_gateway or in the repo build output."
    CONFIG_FILE="$(resolve_config_file)" || die "Unable to find SetupConfiguration.json at /etc/documentdb/SetupConfiguration.json or in the repo."
    SAMPLE_DATA_DIR="$(resolve_sample_data_dir)" || true
    INIT_DATA_SCRIPT="$(resolve_init_data_script)" || true
    HAS_WORKING_SYSTEMD=false
    if has_working_systemd; then
        HAS_WORKING_SYSTEMD=true
    fi
}

refresh_extension_state() {
    EXTENSION_CONTROL_FILE="$("${PG_CONFIG}" --sharedir)/extension/documentdb.control"
    EXTENDED_RUM_CONTROL_FILE="$("${PG_CONFIG}" --sharedir)/extension/documentdb_extended_rum.control"

    HAS_EXTENDED_RUM=false
    if [[ -f "${EXTENDED_RUM_CONTROL_FILE}" ]]; then
        HAS_EXTENDED_RUM=true
    fi
}

validate_documentdb_extension_installation() {
    [[ -f "${EXTENSION_CONTROL_FILE}" ]] || die "The DocumentDB extension package is not installed for PostgreSQL ${PG_VERSION} (${EXTENSION_CONTROL_FILE} is missing)."
}

preflight_validation() {
    require_root
    validate_required_arguments

    command_exists jq || die "jq is required but not installed. Install with: apt install jq"
    detect_postgres_installation
    resolve_runtime_paths

    refresh_extension_state
    validate_documentdb_extension_installation
    [[ -x "${GATEWAY_BINARY}" ]] || die "The gateway binary was not found at ${GATEWAY_BINARY}."
    [[ -f "${CONFIG_FILE}" ]] || die "The gateway configuration file was not found at ${CONFIG_FILE}."

    CAN_LOAD_SAMPLE_DATA=false
    if [[ "${LOAD_SAMPLE_DATA}" == "true" ]]; then
        if [[ -z "${SAMPLE_DATA_DIR}" || ! -d "${SAMPLE_DATA_DIR}" ]]; then
            die "Sample data loading was requested but no sample-data directory could be resolved."
        fi
        if [[ -z "${INIT_DATA_SCRIPT}" || ! -x "${INIT_DATA_SCRIPT}" ]]; then
            die "Sample data loading was requested but init_documentdb_data.sh is unavailable."
        fi
        if command_exists mongosh; then
            CAN_LOAD_SAMPLE_DATA=true
        else
            die "Sample data loading was requested but mongosh is not installed. Install mongosh and retry."
        fi
    fi

    if [[ "${SKIP_PG_INIT}" == "false" && "${PG_OWNER_EXPLICIT}" == "true" && "${PG_OWNER}" != "documentdb" ]]; then
        die "--pg-owner is only supported for --skip-pg-init or when set to documentdb."
    fi

    if [[ "${NO_ENABLE}" != "true" ]]; then
        local gw_listener_pid=""
        gw_listener_pid="$(find_listener_pid "${GATEWAY_PORT}")"
        if [[ -n "${gw_listener_pid}" ]]; then
            if ! listener_looks_like_gateway "${gw_listener_pid}"; then
                die "Gateway port ${GATEWAY_PORT} is already in use by a non-gateway process (pid ${gw_listener_pid}). Use --gateway-port to specify a different port, or --no-enable to skip gateway startup."
            fi
        fi
    fi

    ensure_documentdb_runtime_user
}

ensure_socket_dir_writable() {
    local dir_group=""

    if [[ ! -d "${PG_SOCKET_DIR}" ]]; then
        mkdir -p "${PG_SOCKET_DIR}"
        chown documentdb:documentdb "${PG_SOCKET_DIR}"
        chmod 2775 "${PG_SOCKET_DIR}"
        return 0
    fi

    # Directory exists (e.g. system PostgreSQL owns it).
    # Ensure documentdb can write sockets by joining the postgres group.
    dir_group="$(stat -c '%G' "${PG_SOCKET_DIR}")"
    if [[ "${dir_group}" == "documentdb" ]]; then
        return 0
    fi

    if [[ "${dir_group}" != "postgres" ]]; then
        die "Socket directory ${PG_SOCKET_DIR} is owned by unexpected group '${dir_group}'. Expected 'postgres' or 'documentdb'."
    fi

    if ! id -nG documentdb 2>/dev/null | grep -qw postgres; then
        log_verbose "Adding documentdb to the postgres group for socket directory access."
        usermod -aG postgres documentdb
    fi
    chmod g+ws "${PG_SOCKET_DIR}"
}

prepare_self_managed_cluster() {
    local existing_data_version=""
    local current_preload=""
    local merged_preload=""

    PG_OWNER="documentdb"
    LIVE_DATA_DIR="${DATA_DIR}"
    LIVE_CONFIG_FILE="${DATA_DIR}/postgresql.conf"
    LIVE_HBA_FILE="${DATA_DIR}/pg_hba.conf"

    if [[ -d "${DATA_DIR}" && ! -f "${DATA_DIR}/PG_VERSION" && -n "$(ls -A "${DATA_DIR}" 2>/dev/null || true)" ]]; then
        die "Data directory ${DATA_DIR} exists but is not a valid PostgreSQL cluster."
    fi

    if [[ -f "${DATA_DIR}/PG_VERSION" ]]; then
        existing_data_version="$(head -n 1 "${DATA_DIR}/PG_VERSION" | cut -d'.' -f1)"
        if [[ "${existing_data_version}" != "${PG_VERSION}" ]]; then
            die "Existing data directory ${DATA_DIR} was initialized for PostgreSQL ${existing_data_version}, not ${PG_VERSION}."
        fi
    else
        mkdir -p "${DATA_DIR}"
        chown -R documentdb:documentdb "${DATA_DIR}"
        chmod 700 "${DATA_DIR}"
        ensure_socket_dir_writable

        log_info "Initializing PostgreSQL cluster in ${DATA_DIR}."
        run_as_user documentdb \
            "${INITDB}" \
            --pgdata="${DATA_DIR}" \
            --username=documentdb \
            --auth-local=trust \
            --auth-host=trust \
            --encoding=UTF8
    fi

    if [[ -n "$(find_listener_pid "${PG_PORT}")" ]]; then
        resolve_live_cluster_metadata "${PG_PORT}" "documentdb"
        if [[ "${LIVE_DATA_DIR}" != "${DATA_DIR}" ]]; then
            die "Port ${PG_PORT} is in use by a different PostgreSQL instance (data_directory: ${LIVE_DATA_DIR}). Use --pg-port to specify a different port, or --skip-pg-init to use the existing cluster."
        fi
        current_preload="${LIVE_PRELOAD_LIBRARIES}"
    else
        current_preload="$(read_shared_preload_libraries_from_file "${LIVE_CONFIG_FILE}")"
    fi

    merged_preload="$(merge_shared_preload_libraries "${current_preload}")"
    if [[ "${current_preload}" != "${merged_preload}" ]]; then
        PG_CONFIG_CHANGED=true
    fi

    apply_managed_postgres_settings "${LIVE_CONFIG_FILE}" "${LIVE_HBA_FILE}" "${merged_preload}" "off" "false"
}

prepare_existing_cluster() {
    local merged_preload=""

    if [[ -z "$(find_listener_pid "${PG_PORT}")" ]]; then
        die "--skip-pg-init requires an existing PostgreSQL cluster that is already running on port ${PG_PORT}."
    fi

    resolve_live_cluster_metadata "${PG_PORT}" "${PG_OWNER}"

    if [[ "${DATA_DIR_EXPLICIT}" == "true" && "${DATA_DIR}" != "${LIVE_DATA_DIR}" ]]; then
        die "--data-dir (${DATA_DIR}) does not match the existing cluster data directory (${LIVE_DATA_DIR})."
    fi

    DATA_DIR="${LIVE_DATA_DIR}"
    merged_preload="$(merge_shared_preload_libraries "${LIVE_PRELOAD_LIBRARIES}")"
    if [[ "${LIVE_PRELOAD_LIBRARIES}" != "${merged_preload}" ]]; then
        PG_CONFIG_CHANGED=true
    fi

    apply_managed_postgres_settings "${LIVE_CONFIG_FILE}" "${LIVE_HBA_FILE}" "${merged_preload}" "" "true"
}

wait_for_postgres() {
    local attempt=""
    for attempt in $(seq 1 60); do
        if "${PG_ISREADY}" -h localhost -p "${PG_PORT}" >/dev/null 2>&1; then
            log_verbose "PostgreSQL became ready on attempt ${attempt}."
            return 0
        fi
        sleep 1
    done

    die "PostgreSQL did not become ready on localhost:${PG_PORT} within 60 seconds."
}

start_or_restart_postgres() {
    if [[ "${SKIP_PG_INIT}" == "true" ]]; then
        log_info "Restarting the existing PostgreSQL cluster in ${LIVE_DATA_DIR}."
        if run_as_user "${PG_OWNER}" "${PG_CTL}" -D "${LIVE_DATA_DIR}" status >/dev/null 2>&1; then
            run_as_user "${PG_OWNER}" "${PG_CTL}" -D "${LIVE_DATA_DIR}" -w restart
        else
            run_as_user "${PG_OWNER}" "${PG_CTL}" -D "${LIVE_DATA_DIR}" -w start
        fi
    else
        log_info "Starting the self-managed PostgreSQL cluster in ${DATA_DIR}."
        ensure_socket_dir_writable

        if run_as_user documentdb "${PG_CTL}" -D "${DATA_DIR}" status >/dev/null 2>&1; then
            if [[ "${PG_CONFIG_CHANGED}" == "true" ]]; then
                log_info "Configuration changed; restarting PostgreSQL to apply new settings."
            fi
            run_as_user documentdb "${PG_CTL}" -D "${DATA_DIR}" -w restart
        else
            run_as_user documentdb "${PG_CTL}" -D "${DATA_DIR}" -l "${DATA_DIR}/pglog.log" -w start
        fi
    fi

    wait_for_postgres
}

create_required_extensions_and_users() {
    log_info "Creating required extensions and roles."

    run_as_user "${PG_OWNER}" "${PSQL}" -p "${PG_PORT}" -d postgres -X -v ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS documentdb CASCADE;
SQL

    if [[ "${HAS_EXTENDED_RUM}" == "true" ]]; then
        run_as_user "${PG_OWNER}" "${PSQL}" -p "${PG_PORT}" -d postgres -X -v ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS documentdb_extended_rum CASCADE;
SQL
    fi

    run_as_user "${PG_OWNER}" "${PSQL}" -p "${PG_PORT}" -d postgres -X -v ON_ERROR_STOP=1 <<'SQL'
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'documentdb') THEN
        CREATE ROLE documentdb LOGIN SUPERUSER;
    ELSE
        ALTER ROLE documentdb WITH LOGIN SUPERUSER;
    END IF;
END $$;
SQL

    if run_as_user "${PG_OWNER}" "${PSQL}" -p "${PG_PORT}" -d postgres -X -tA -v ON_ERROR_STOP=1 -v role_name="${USERNAME}" <<'SQL' | grep -q '^1$'; then
SELECT 1 FROM pg_roles WHERE rolname = :'role_name';
SQL
        log_info "Application user ${USERNAME} already exists; skipping create_user."
        return 0
    fi

    create_documentdb_user "${PG_OWNER}" "${PG_PORT}" "${USERNAME}" "${PASSWORD}"
}

update_gateway_configuration() {
    log_info "Updating gateway configuration at ${CONFIG_FILE}."
    update_json_file "${CONFIG_FILE}"
}

wait_for_gateway_ready() {
    local attempt=""
    for attempt in $(seq 1 60); do
        if (echo >/dev/tcp/127.0.0.1/"${GATEWAY_PORT}") >/dev/null 2>&1; then
            log_verbose "Gateway became ready on attempt ${attempt}."
            return 0
        fi
        sleep 1
    done

    die "The gateway did not become ready on localhost:${GATEWAY_PORT} within 60 seconds."
}

stop_gateway_process() {
    local pid="$1"
    local port="$2"

    kill "${pid}"
    if wait_for_listener_to_clear "${port}" 30; then
        return 0
    fi

    log_warn "Process ${pid} did not stop after SIGTERM; sending SIGKILL."
    kill -KILL "${pid}" 2>/dev/null || true
    if ! wait_for_listener_to_clear "${port}" 10; then
        log_warn "Process ${pid} did not stop even after SIGKILL."
        return 1
    fi
}

start_gateway() {
    local existing_gateway_pid=""

    if [[ "${NO_ENABLE}" == "true" ]]; then
        log_info "Skipping gateway startup because --no-enable was requested."
        return 0
    fi

    if [[ "${HAS_WORKING_SYSTEMD}" == "true" ]] && systemctl list-unit-files documentdb-gateway.service >/dev/null 2>&1; then
        # If a manually-started gateway is occupying the port, stop it before
        # handing control to systemd to avoid a port conflict.
        existing_gateway_pid="$(find_listener_pid "${GATEWAY_PORT}")"
        if [[ -n "${existing_gateway_pid}" ]]; then
            if ! systemctl is-active --quiet documentdb-gateway; then
                # Listener exists but systemd doesn't own it — stop the manual process
                log_info "Stopping manually started gateway (pid ${existing_gateway_pid}) before systemd takeover."
                if ! stop_gateway_process "${existing_gateway_pid}" "${GATEWAY_PORT}"; then
                    die "Gateway port ${GATEWAY_PORT} is still in use after stopping process ${existing_gateway_pid}."
                fi
            fi
        fi

        log_info "Starting the gateway with systemd."
        systemctl enable documentdb-gateway >/dev/null
        if systemctl is-active --quiet documentdb-gateway; then
            systemctl restart documentdb-gateway
        else
            systemctl start documentdb-gateway
        fi
        wait_for_gateway_ready
        return 0
    fi

    existing_gateway_pid="$(find_listener_pid "${GATEWAY_PORT}")"
    if [[ -n "${existing_gateway_pid}" ]]; then
        if ! listener_looks_like_gateway "${existing_gateway_pid}"; then
            die "Port ${GATEWAY_PORT} is already in use by a non-gateway process."
        fi

        log_info "Restarting the manually managed gateway process on port ${GATEWAY_PORT}."
        if ! stop_gateway_process "${existing_gateway_pid}" "${GATEWAY_PORT}"; then
            die "Gateway port ${GATEWAY_PORT} is still in use after stopping process ${existing_gateway_pid}."
        fi
    else
        log_info "Starting the gateway without systemd."
    fi

    local escaped_binary escaped_config
    escaped_binary="$(printf '%q' "${GATEWAY_BINARY}")"
    escaped_config="$(printf '%q' "${CONFIG_FILE}")"
    run_as_user_shell documentdb "cd /var/lib/documentdb && nohup ${escaped_binary} ${escaped_config} > /var/lib/documentdb/gateway.log 2>&1 &"
    wait_for_gateway_ready
}

load_sample_data_if_requested() {
    local -a init_args=()

    if [[ "${LOAD_SAMPLE_DATA}" != "true" ]]; then
        return 0
    fi

    if [[ "${CAN_LOAD_SAMPLE_DATA}" != "true" ]]; then
        die "Sample data loading was requested but mongosh is unavailable."
    fi

    log_info "Loading packaged sample data from ${SAMPLE_DATA_DIR}."
    init_args=(
        --port "${GATEWAY_PORT}"
        --username "${USERNAME}"
        --password "${PASSWORD}"
        --data-path "${SAMPLE_DATA_DIR}"
    )
    if [[ "${VERBOSE}" == "true" ]]; then
        init_args+=(--verbose)
    fi

    "${INIT_DATA_SCRIPT}" "${init_args[@]}"
}

print_completion_message() {
    if [[ "${NO_ENABLE}" == "true" ]]; then
        log_success "DocumentDB PostgreSQL setup is complete."
        echo "Start the gateway manually when ready:"
        if [[ "${HAS_WORKING_SYSTEMD}" == "true" ]] && systemctl list-unit-files documentdb-gateway.service >/dev/null 2>&1; then
            echo "  sudo systemctl enable --now documentdb-gateway"
        else
            echo "  sudo -u documentdb ${GATEWAY_BINARY} ${CONFIG_FILE}"
        fi
        return 0
    fi

    log_success "DocumentDB is ready."
    echo "Connect with:"
    echo "  mongosh 'mongodb://${USERNAME}:<your-password>@localhost:${GATEWAY_PORT}/?tls=true&tlsAllowInvalidCertificates=true'"
    echo "  Replace <your-password> with the password you provided."
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --username)
                [[ $# -ge 2 ]] || die "--username requires a value."
                USERNAME="$2"
                shift 2
                ;;
            --password)
                [[ $# -ge 2 ]] || die "--password requires a value."
                PASSWORD="$2"
                shift 2
                ;;
            --password-file)
                [[ $# -ge 2 ]] || die "--password-file requires a value."
                PASSWORD_FILE="$2"
                shift 2
                ;;
            --pg-version)
                [[ $# -ge 2 ]] || die "--pg-version requires a value."
                PG_VERSION="$2"
                PG_VERSION_EXPLICIT=true
                shift 2
                ;;
            --pg-port)
                [[ $# -ge 2 ]] || die "--pg-port requires a value."
                PG_PORT="$2"
                shift 2
                ;;
            --gateway-port)
                [[ $# -ge 2 ]] || die "--gateway-port requires a value."
                GATEWAY_PORT="$2"
                shift 2
                ;;
            --data-dir)
                [[ $# -ge 2 ]] || die "--data-dir requires a value."
                DATA_DIR="$2"
                DATA_DIR_EXPLICIT=true
                shift 2
                ;;
            --skip-pg-init)
                SKIP_PG_INIT=true
                shift
                ;;
            --no-enable)
                NO_ENABLE=true
                shift
                ;;
            --load-sample-data)
                LOAD_SAMPLE_DATA=true
                shift
                ;;
            --pg-owner)
                [[ $# -ge 2 ]] || die "--pg-owner requires a value."
                PG_OWNER="$2"
                PG_OWNER_EXPLICIT=true
                shift 2
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "Unknown argument: $1"
                ;;
        esac
    done

    [[ "${PG_PORT}" =~ ^[0-9]+$ ]] || die "--pg-port must be numeric."
    [[ "${GATEWAY_PORT}" =~ ^[0-9]+$ ]] || die "--gateway-port must be numeric."
    if (( PG_PORT < 1 || PG_PORT > 65535 )); then
        die "--pg-port must be between 1 and 65535."
    fi
    if (( GATEWAY_PORT < 1 || GATEWAY_PORT > 65535 )); then
        die "--gateway-port must be between 1 and 65535."
    fi
    if (( PG_PORT < 1024 )); then
        log_warn "Port ${PG_PORT} is a privileged port; non-root services may fail to bind."
    fi
    if (( GATEWAY_PORT < 1024 )); then
        log_warn "Port ${GATEWAY_PORT} is a privileged port; non-root services may fail to bind."
    fi
}

main() {
    parse_arguments "$@"
    preflight_validation

    log_info "Using PostgreSQL ${PG_VERSION} binaries in ${PG_BIN_DIR}."
    log_info "Using gateway binary ${GATEWAY_BINARY}."
    log_info "Using gateway config ${CONFIG_FILE}."

    if [[ "${SKIP_PG_INIT}" == "true" ]]; then
        prepare_existing_cluster
    else
        prepare_self_managed_cluster
    fi

    start_or_restart_postgres
    create_required_extensions_and_users
    update_gateway_configuration
    sync_self_managed_postgres_service_state
    start_gateway
    load_sample_data_if_requested
    print_completion_message
}

main "$@"
