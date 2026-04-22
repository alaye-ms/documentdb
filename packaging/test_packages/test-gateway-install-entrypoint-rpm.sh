#!/bin/bash
set -euo pipefail

readonly USERNAME="cloudsa"
readonly PASSWORD="DocDbPasswordArgCheck123"
readonly PG_PORT="9712"
readonly GATEWAY_PORT="10260"
readonly SETUP_LOG="/tmp/documentdb-setup.log"
readonly POSTGRES_VERSION="${POSTGRES_VERSION:-17}"
TEMP_FILES=()

log() {
    echo "[gateway-rpm-e2e] $*"
}

fail() {
    echo "[gateway-rpm-e2e] ERROR: $*" >&2
    exit 1
}

cleanup() {
    if (( ${#TEMP_FILES[@]} > 0 )); then
        rm -rf "${TEMP_FILES[@]}" 2>/dev/null || true
        TEMP_FILES=()
    fi
}
trap cleanup EXIT

assert_eq() {
    local actual="$1"
    local expected="$2"
    local message="$3"
    if [[ "${actual}" != "${expected}" ]]; then
        fail "${message}: expected '${expected}', got '${actual}'"
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"
    if [[ "${haystack}" != *"${needle}"* ]]; then
        fail "${message}: missing '${needle}' in '${haystack}'"
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"
    if [[ "${haystack}" == *"${needle}"* ]]; then
        fail "${message}: unexpectedly found '${needle}' in '${haystack}'"
    fi
}

assert_file() {
    local path="$1"
    if [[ ! -e "${path}" ]]; then
        fail "Expected file ${path} to exist"
    fi
}

assert_executable() {
    local path="$1"
    if [[ ! -x "${path}" ]]; then
        fail "Expected executable ${path} to exist"
    fi
}

assert_file_contains_regex() {
    local path="$1"
    local regex="$2"
    local message="$3"
    if [[ -r "${path}" ]]; then
        grep -Eq "${regex}" "${path}" || fail "${message}: ${path} did not match ${regex}"
        return 0
    fi

    if command -v sudo >/dev/null 2>&1; then
        sudo grep -Eq "${regex}" "${path}" || fail "${message}: ${path} did not match ${regex}"
        return 0
    fi

    if ! grep -Eq "${regex}" "${path}" 2>/dev/null; then
        fail "${message}: ${path} did not match ${regex}"
    fi
}

register_temp_file() {
    TEMP_FILES+=("$1")
}

create_temp_dir() {
    local target_var="$1"
    local template="${2:-/tmp/documentdb-tempdir.XXXXXX}"
    local created_dir=""

    created_dir="$(mktemp -d "${template}")"
    chmod 700 "${created_dir}"
    register_temp_file "${created_dir}"
    printf -v "${target_var}" '%s' "${created_dir}"
}

create_temp_file() {
    local target_var="$1"
    local template="${2:-}"
    local created_file=""

    if [[ -n "${template}" ]]; then
        created_file="$(mktemp "${template}")"
    else
        created_file="$(mktemp)"
    fi

    chmod 600 "${created_file}"
    register_temp_file "${created_file}"
    printf -v "${target_var}" '%s' "${created_file}"
}

extract_rpm_scriptlet() {
    local target_var="$1"
    local scriptlet_name="$2"
    local package_path="$3"
    local scriptlet_file=""

    create_temp_file scriptlet_file "/tmp/documentdb-rpm-scriptlet.XXXXXX"
    rpm -qp --scripts "${package_path}" | awk -v section="${scriptlet_name}" '
        $0 == section " scriptlet (using /bin/sh):" { capture = 1; next }
        capture && /^[[:alpha:]][[:alpha:]-]* scriptlet \(using .*\):$/ { exit }
        capture { print }
    ' > "${scriptlet_file}"

    [[ -s "${scriptlet_file}" ]] || fail "Failed to extract ${scriptlet_name} from ${package_path}"
    printf -v "${target_var}" '%s' "${scriptlet_file}"
}

run_scriptlet_with_fake_systemctl() {
    local scriptlet_file="$1"
    local scriptlet_arg="$2"
    local systemctl_log="$3"
    local fakebin_dir=""

    create_temp_dir fakebin_dir "/tmp/documentdb-fakebin.XXXXXX"
    cat > "${fakebin_dir}/systemctl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${FAKE_SYSTEMCTL_LOG}"
EOF
    chmod 755 "${fakebin_dir}/systemctl"

    : > "${systemctl_log}"
    env FAKE_SYSTEMCTL_LOG="${systemctl_log}" PATH="${fakebin_dir}:${PATH}" \
        bash "${scriptlet_file}" "${scriptlet_arg}"
}

run_psql() {
    local sql="$1"
    psql \
        -h localhost \
        -p "${PG_PORT}" \
        -U documentdb \
        -d postgres \
        -X \
        -Atqc "${sql}"
}

resolve_pg_config() {
    local candidate="/usr/pgsql-${POSTGRES_VERSION}/bin/pg_config"

    if [[ -x "${candidate}" ]]; then
        printf '%s' "${candidate}"
        return 0
    fi

    if command -v pg_config >/dev/null 2>&1; then
        command -v pg_config
        return 0
    fi

    fail "pg_config was not found for PostgreSQL ${POSTGRES_VERSION}"
}

password_visible_in_process_args() {
    local root_pid="$1"
    local current_pid=""
    local child_pid=""
    local child_ppid=""
    local cmdline=""
    local seen_pids=" ${root_pid} "
    local -a scan_queue=("${root_pid}")

    while (( ${#scan_queue[@]} > 0 )); do
        current_pid="${scan_queue[0]}"
        scan_queue=("${scan_queue[@]:1}")

        if [[ -r "/proc/${current_pid}/cmdline" ]]; then
            cmdline="$(tr '\0' ' ' < "/proc/${current_pid}/cmdline" 2>/dev/null || true)"
        else
            cmdline="$(ps -p "${current_pid}" -o args= 2>/dev/null || true)"
        fi

        if [[ -n "${cmdline}" && "${cmdline}" == *"${PASSWORD}"* ]]; then
            return 0
        fi

        # Walk the full setup process tree so child-process argv leaks are caught too.
        while read -r child_pid child_ppid; do
            [[ -n "${child_pid}" ]] || continue
            if [[ "${child_ppid}" != "${current_pid}" ]]; then
                continue
            fi
            if [[ "${seen_pids}" == *" ${child_pid} "* ]]; then
                continue
            fi
            seen_pids+=" ${child_pid} "
            scan_queue+=("${child_pid}")
        done < <(ps -eo pid=,ppid=)
    done

    return 1
}

create_mongosh_wrapper_script() {
    local _target_var="$1"
    local _wrapper_path=""

    create_temp_file _wrapper_path "/tmp/documentdb-mongosh.XXXXXX.js"
    cat > "${_wrapper_path}" <<'EOF'
const host = process.env.DOCUMENTDB_HOST || 'localhost';
const port = process.env.DOCUMENTDB_PORT;
const username = process.env.DOCUMENTDB_USERNAME;
const password = process.env.DOCUMENTDB_PASSWORD;
const initFile = process.env.DOCUMENTDB_INIT_FILE || '';
const uri = `mongodb://${encodeURIComponent(username)}:${encodeURIComponent(password)}@${host}:${port}/admin?authSource=admin&authMechanism=SCRAM-SHA-256&tls=true&tlsAllowInvalidCertificates=true`;

db = connect(uri);

if (initFile) {
    load(initFile);
}
EOF

    printf -v "${_target_var}" '%s' "${_wrapper_path}"
}

run_mongosh_script() {
    local script_content="$1"
    local output_file="$2"
    local init_file=""
    local wrapper_file=""

    create_temp_file init_file "/tmp/documentdb-mongosh-init.XXXXXX.js"
    printf '%s\n' "${script_content}" > "${init_file}"
    create_mongosh_wrapper_script wrapper_file

    env \
        DOCUMENTDB_HOST="localhost" \
        DOCUMENTDB_PORT="${GATEWAY_PORT}" \
        DOCUMENTDB_USERNAME="${USERNAME}" \
        DOCUMENTDB_PASSWORD="${PASSWORD}" \
        DOCUMENTDB_INIT_FILE="${init_file}" \
        mongosh --quiet --nodb "${wrapper_file}" > "${output_file}" 2>&1
}

verify_package_install() {
    local extension_package_name=""
    local gateway_requires=""
    local setup_help=""

    log "Installing extension and gateway RPM packages."
    extension_package_name="$(rpm -qp --queryformat "%{NAME}\n" /tmp/documentdb.rpm)"
    dnf install -y /tmp/documentdb.rpm /tmp/documentdb_gateway.rpm

    rpm -q "${extension_package_name}" >/dev/null 2>&1 || fail "Extension RPM was not installed successfully"
    rpm -q documentdb_gateway >/dev/null 2>&1 || fail "Gateway RPM was not installed successfully"
    command -v jq >/dev/null 2>&1 || fail "Gateway RPM dependency jq was not installed"

    assert_executable /usr/bin/documentdb_gateway
    assert_executable /usr/bin/documentdb-setup
    assert_file /etc/documentdb/SetupConfiguration.json
    assert_file /lib/systemd/system/documentdb-postgresql.service
    assert_file /lib/systemd/system/documentdb-gateway.service
    assert_file /usr/share/documentdb/scripts/start_oss_server.sh
    assert_file /usr/share/documentdb/scripts/build_and_start_gateway.sh
    assert_executable /usr/share/documentdb/scripts/documentdb_postgresql_service.sh
    assert_file /usr/share/documentdb/scripts/emulator_entrypoint.sh
    assert_file /usr/share/documentdb/scripts/init_documentdb_data.sh
    assert_file /usr/share/documentdb/sample-data/01-users.js

    id documentdb >/dev/null 2>&1 || fail "documentdb runtime user was not created"
    [[ -d /var/lib/documentdb ]] || fail "/var/lib/documentdb was not created"
    [[ "$(stat -c "%U:%G" /var/lib/documentdb)" == "documentdb:documentdb" ]] || fail "/var/lib/documentdb is not owned by documentdb"

    gateway_requires="$(rpm -qpR /tmp/documentdb_gateway.rpm)"
    assert_contains "${gateway_requires}" "jq" "Gateway RPM metadata is missing the jq dependency"
    if printf "%s\n" "${gateway_requires}" | grep -Eq "postgresql(15|16|17|18)-documentdb"; then
        fail "Gateway RPM metadata should not auto-select a DocumentDB extension package"
    fi

    setup_help="$(documentdb-setup --help)"
    printf "%s\n" "${setup_help}" | grep -Fq -- '--password-file <FILE>' \
        || fail "documentdb-setup help did not advertise --password-file"
    printf "%s\n" "${setup_help}" | grep -Fq -- 'localhost HBA entries while preserving its SSL setting' \
        || fail "documentdb-setup help did not explain the --skip-pg-init managed config changes"
}

verify_preun_scriptlet_behaviour() {
    local preun_scriptlet=""
    local systemctl_log=""
    local systemctl_calls=""

    log "Verifying RPM %preun stops services on upgrade and disables them only on removal."
    extract_rpm_scriptlet preun_scriptlet "preuninstall" /tmp/documentdb_gateway.rpm
    create_temp_file systemctl_log "/tmp/documentdb-rpm-preun.XXXXXX.log"

    run_scriptlet_with_fake_systemctl "${preun_scriptlet}" 1 "${systemctl_log}"
    systemctl_calls="$(< "${systemctl_log}")"
    assert_contains "${systemctl_calls}" "stop documentdb-postgresql" "Upgrade %preun did not stop documentdb-postgresql"
    assert_contains "${systemctl_calls}" "stop documentdb-gateway" "Upgrade %preun did not stop documentdb-gateway"
    assert_not_contains "${systemctl_calls}" "disable documentdb-postgresql" "Upgrade %preun should not disable documentdb-postgresql"
    assert_not_contains "${systemctl_calls}" "disable documentdb-gateway" "Upgrade %preun should not disable documentdb-gateway"

    run_scriptlet_with_fake_systemctl "${preun_scriptlet}" 0 "${systemctl_log}"
    systemctl_calls="$(< "${systemctl_log}")"
    assert_contains "${systemctl_calls}" "stop documentdb-postgresql" "Removal %preun did not stop documentdb-postgresql"
    assert_contains "${systemctl_calls}" "stop documentdb-gateway" "Removal %preun did not stop documentdb-gateway"
    assert_contains "${systemctl_calls}" "disable documentdb-postgresql" "Removal %preun did not disable documentdb-postgresql"
    assert_contains "${systemctl_calls}" "disable documentdb-gateway" "Removal %preun did not disable documentdb-gateway"
}

run_documentdb_setup() {
    local setup_pid=""
    local password_file=""
    local -a setup_args=("$@")

    create_temp_file password_file "/tmp/documentdb-password.XXXXXX"
    printf '%s' "${PASSWORD}" > "${password_file}"

    log "Running packaged documentdb-setup."

    documentdb-setup --username "${USERNAME}" --password-file "${password_file}" --verbose "${setup_args[@]}" > "${SETUP_LOG}" 2>&1 &
    setup_pid=$!
    while kill -0 "${setup_pid}" 2>/dev/null; do
        if password_visible_in_process_args "${setup_pid}"; then
            cat "${SETUP_LOG}"
            fail "documentdb-setup exposed the password in process arguments"
        fi
        sleep 0.1
    done

    if ! wait "${setup_pid}"; then
        cat "${SETUP_LOG}"
        fail "documentdb-setup failed"
    fi
    cat "${SETUP_LOG}"

    grep -Fq "[documentdb-setup] SUCCESS: DocumentDB is ready." "${SETUP_LOG}" \
        || fail "documentdb-setup did not report readiness"

    local expected_connstr="mongosh 'mongodb://${USERNAME}:<your-password>@localhost:${GATEWAY_PORT}/?tls=true&tlsAllowInvalidCertificates=true'"
    grep -Fq "${expected_connstr}" "${SETUP_LOG}" \
        || fail "documentdb-setup did not print the expected connection string"

    grep -Fq "Replace <your-password> with the password you provided." "${SETUP_LOG}" \
        || fail "documentdb-setup did not print the password redaction guidance"

    if grep -Fq "mongodb://${USERNAME}:${PASSWORD}@localhost:${GATEWAY_PORT}" "${SETUP_LOG}"; then
        fail "documentdb-setup leaked the plaintext password in its connection output"
    fi
}

verify_gateway_configuration() {
    log "Verifying packaged gateway configuration was updated."
    assert_eq "$(jq -r '.PostgresPort' /etc/documentdb/SetupConfiguration.json)" "${PG_PORT}" "Unexpected PostgresPort"
    assert_eq "$(jq -r '.GatewayListenPort' /etc/documentdb/SetupConfiguration.json)" "${GATEWAY_PORT}" "Unexpected GatewayListenPort"
    assert_eq "$(jq -r '.PostgresSystemUser' /etc/documentdb/SetupConfiguration.json)" "documentdb" "Unexpected PostgresSystemUser"
    assert_eq "$(jq -r '.PostgresDataUser' /etc/documentdb/SetupConfiguration.json)" "documentdb" "Unexpected PostgresDataUser"
}

verify_self_managed_postgres_persistence() {
    log "Verifying self-managed PostgreSQL startup state was persisted for packaged installs."
    assert_file /etc/documentdb/documentdb-postgresql.env
    assert_file_contains_regex /etc/documentdb/documentdb-postgresql.env '^DOCUMENTDB_MANAGED_POSTGRES=true$' "Managed PostgreSQL flag missing"
    assert_file_contains_regex /etc/documentdb/documentdb-postgresql.env '^PG_VERSION=' "Managed PostgreSQL version missing"
    assert_file_contains_regex /etc/documentdb/documentdb-postgresql.env '^DATA_DIR=' "Managed PostgreSQL data dir missing"
}

verify_postgres_state() {
    local preload_libraries
    local hba_file
    local extended_rum_control
    local pg_config_bin

    log "Verifying PostgreSQL settings, HBA, roles, and extensions."
    assert_eq "$(run_psql 'SHOW listen_addresses;')" "localhost" "Unexpected listen_addresses"
    assert_eq "$(run_psql 'SHOW ssl;')" "off" "Unexpected ssl setting"
    assert_eq "$(run_psql 'SHOW cron.database_name;')" "postgres" "Unexpected cron.database_name"
    assert_eq "$(run_psql 'SHOW documentdb.enableBackgroundWorker;')" "on" "Unexpected documentdb.enableBackgroundWorker"
    assert_eq "$(run_psql 'SHOW documentdb.enableBackgroundWorkerJobs;')" "on" "Unexpected documentdb.enableBackgroundWorkerJobs"
    assert_eq "$(run_psql 'SHOW documentdb.indexBuildsScheduledOnBgWorker;')" "off" "Unexpected documentdb.indexBuildsScheduledOnBgWorker"

    preload_libraries="$(run_psql 'SHOW shared_preload_libraries;')"
    assert_contains "${preload_libraries}" "pg_cron" "shared_preload_libraries missing pg_cron"
    assert_contains "${preload_libraries}" "pg_documentdb_core" "shared_preload_libraries missing pg_documentdb_core"
    assert_contains "${preload_libraries}" "pg_documentdb" "shared_preload_libraries missing pg_documentdb"

    hba_file="$(run_psql 'SHOW hba_file;')"
    assert_file_contains_regex "${hba_file}" 'host[[:space:]]+all[[:space:]]+all[[:space:]]+127\.0\.0\.1/32[[:space:]]+trust' "Missing IPv4 localhost HBA entry"
    assert_file_contains_regex "${hba_file}" 'host[[:space:]]+all[[:space:]]+all[[:space:]]+::1/128[[:space:]]+trust' "Missing IPv6 localhost HBA entry"

    assert_eq "$(run_psql "SELECT CASE WHEN rolcanlogin AND rolsuper THEN 'ok' ELSE 'bad' END FROM pg_roles WHERE rolname = 'documentdb';")" "ok" "documentdb role was not created as LOGIN SUPERUSER"
    assert_eq "$(run_psql "SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${USERNAME}') THEN 'ok' ELSE 'missing' END;")" "ok" "Application role was not created"
    assert_eq "$(run_psql "SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'documentdb_core') THEN 'ok' ELSE 'missing' END;")" "ok" "documentdb_core extension missing"
    assert_eq "$(run_psql "SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'documentdb') THEN 'ok' ELSE 'missing' END;")" "ok" "documentdb extension missing"

    pg_config_bin="$(resolve_pg_config)"
    extended_rum_control="$("${pg_config_bin}" --sharedir)/extension/documentdb_extended_rum.control"
    if [[ -f "${extended_rum_control}" ]]; then
        assert_contains "${preload_libraries}" "pg_documentdb_extended_rum" "shared_preload_libraries missing pg_documentdb_extended_rum"
        assert_eq "$(run_psql 'SHOW documentdb.rum_library_load_option;')" "require_documentdb_extended_rum" "Unexpected documentdb.rum_library_load_option"
        assert_eq "$(run_psql 'SHOW documentdb.alternate_index_handler_name;')" "extended_rum" "Unexpected documentdb.alternate_index_handler_name"
        assert_eq "$(run_psql "SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'documentdb_extended_rum') THEN 'ok' ELSE 'missing' END;")" "ok" "documentdb_extended_rum extension missing"
    fi
}

verify_gateway_crud() {
    local mongosh_log="/tmp/mongosh-smoke.log"
    local crud_script=""

    crud_script="$(cat <<'EOF'
const database = db.getSiblingDB("quickStartDatabase");
database.quickStartCollection.deleteMany({});
database.quickStartCollection.insertOne({name: "John Doe", email: "john@email.com"});
const doc = database.quickStartCollection.findOne({name: "John Doe"});
if (!doc || doc.email !== "john@email.com") {
    quit(1);
}
printjson(doc);
EOF
)"

    log "Running mongosh CRUD smoke test through the gateway."
    if ! run_mongosh_script "${crud_script}" "${mongosh_log}"; then
        cat "${mongosh_log}"
        fail "mongosh CRUD smoke test failed"
    fi
    cat "${mongosh_log}"

    grep -Fq 'John Doe' "${mongosh_log}" || fail "mongosh CRUD smoke test did not return the inserted document"
    grep -Fq 'john@email.com' "${mongosh_log}" || fail "mongosh CRUD smoke test did not persist the expected email"
}

verify_sample_data() {
    local sample_log="/tmp/mongosh-sampledata.log"
    local sample_script=""

    sample_script="$(cat <<'EOF'
const database = db.getSiblingDB("sampledb");
const counts = {
    users: database.users.countDocuments(),
    products: database.products.countDocuments(),
    orders: database.orders.countDocuments(),
    analytics: database.analytics.countDocuments(),
};
printjson(counts);
if (Object.values(counts).some((value) => value < 1)) {
    quit(1);
}
EOF
)"

    log "Verifying packaged sample data load through the gateway."
    if ! run_mongosh_script "${sample_script}" "${sample_log}"; then
        cat "${sample_log}"
        fail "Sample data verification failed"
    fi
    cat "${sample_log}"
}

main() {
    verify_preun_scriptlet_behaviour
    verify_package_install
    run_documentdb_setup
    verify_gateway_configuration
    verify_self_managed_postgres_persistence
    verify_postgres_state
    verify_gateway_crud
    run_documentdb_setup --load-sample-data
    verify_sample_data
    log "Gateway RPM clean-install E2E passed."
}

main "$@"
