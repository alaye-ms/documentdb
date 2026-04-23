#!/bin/bash
# Smoke test the published Copr packages end-to-end inside a fresh container.
#
# Steps performed:
#   1. Launch a container for the requested Copr chroot (Fedora or EL9).
#   2. Enable any external repos required by the chroot (PGDG, EPEL, CRB).
#   3. Enable the Copr repo and install the `documentdb-server` meta-package
#      (which pulls the extension RPM + documentdb-gateway).
#   4. Install mongosh.
#   5. Run `documentdb-setup` to bootstrap PostgreSQL + the gateway.
#   6. Drive a CRUD smoke test against the gateway with mongosh.
#
# Usage:
#   ./packaging/test_copr_install.sh [options]
#
# Options:
#   --copr OWNER/PROJECT      Copr project to enable
#                             (default: xgerman/DocumentDB).
#   --chroot CHROOT           One of fedora-43-x86_64 (default), fedora-42-x86_64,
#                             epel-9-x86_64.
#   --image IMAGE             Override the container image (otherwise inferred
#                             from --chroot).
#   --username NAME           Application MongoDB user (default: cloudsa).
#   --password PASSWORD       Password for the user (default:
#                             DocDbCoprSmoke!23).
#   --keep-container          Do not auto-remove the container; print its id.
#   -h, --help                Show this help.

set -euo pipefail

COPR_PROJECT="xgerman/DocumentDB"
CHROOT="fedora-43-x86_64"
IMAGE=""
USERNAME="cloudsa"
PASSWORD="DocDbCoprSmoke!23"
KEEP_CONTAINER=0
LOCAL_SETUP_OVERLAY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/documentdb-local/scripts/documentdb-setup.sh"
USE_LOCAL_SETUP=1

usage() {
    sed -n '2,30p' "$0"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --copr) shift; COPR_PROJECT="$1" ;;
        --chroot) shift; CHROOT="$1" ;;
        --image) shift; IMAGE="$1" ;;
        --username) shift; USERNAME="$1" ;;
        --password) shift; PASSWORD="$1" ;;
        --keep-container) KEEP_CONTAINER=1 ;;
        --no-local-setup) USE_LOCAL_SETUP=0 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

if [[ ! "${COPR_PROJECT}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    echo "ERROR: --copr value '${COPR_PROJECT}' must be OWNER/PROJECT" >&2
    exit 2
fi

case "${CHROOT}" in
    fedora-43-x86_64) DEFAULT_IMAGE="fedora:43" ;;
    fedora-42-x86_64) DEFAULT_IMAGE="fedora:42" ;;
    epel-9-x86_64)    DEFAULT_IMAGE="rockylinux:9" ;;
    *) echo "ERROR: unsupported --chroot '${CHROOT}'" >&2; exit 2 ;;
esac

IMAGE="${IMAGE:-${DEFAULT_IMAGE}}"

echo "=== Copr install + gateway smoke test ==="
echo "Copr project : ${COPR_PROJECT}"
echo "Chroot       : ${CHROOT}"
echo "Image        : ${IMAGE}"
echo "Username     : ${USERNAME}"

container_args=(--rm)
if (( KEEP_CONTAINER )); then
    container_args=(--name "documentdb-copr-smoke-$$")
fi

if (( USE_LOCAL_SETUP )); then
    if [[ ! -r "${LOCAL_SETUP_OVERLAY}" ]]; then
        echo "ERROR: cannot read local documentdb-setup at ${LOCAL_SETUP_OVERLAY}" >&2
        exit 2
    fi
    container_args+=(-v "${LOCAL_SETUP_OVERLAY}:/tmp/documentdb-setup-overlay.sh:ro")
    OVERLAY_FLAG=1
else
    OVERLAY_FLAG=0
fi

# The inner script runs entirely inside the container. It receives:
#   $1 = COPR_PROJECT, $2 = CHROOT, $3 = USERNAME, $4 = PASSWORD,
#   $5 = OVERLAY_FLAG ("1" if /tmp/documentdb-setup-overlay.sh should
#        replace the RPM-installed /usr/bin/documentdb-setup)
INNER_SCRIPT='
set -euo pipefail

COPR_PROJECT="$1"
CHROOT="$2"
USERNAME="$3"
PASSWORD="$4"
OVERLAY_FLAG="$5"
GATEWAY_PORT=10260

log() { echo "[copr-smoke] $*"; }
fail() { echo "[copr-smoke] ERROR: $*" >&2; exit 1; }

log "Installing base tooling."
dnf install -y dnf-plugins-core procps-ng iproute findutils

case "${CHROOT}" in
    epel-9-x86_64)
        log "Enabling EPEL, CRB, and PGDG for EL9."
        dnf install -y epel-release
        dnf config-manager --set-enabled crb
        dnf -qy module disable postgresql >/dev/null 2>&1 || true
        dnf install -y --nogpgcheck \
            https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm
        ;;
    fedora-42-x86_64)
        log "Enabling PGDG for Fedora 42."
        dnf install -y --nogpgcheck \
            https://download.postgresql.org/pub/repos/yum/reporpms/F-42-x86_64/pgdg-fedora-repo-latest.noarch.rpm
        ;;
    fedora-43-x86_64)
        log "Using native Fedora 43 PostgreSQL 18 (no external repos required)."
        ;;
esac

log "Enabling Copr project ${COPR_PROJECT}."
dnf copr enable -y "${COPR_PROJECT}"

log "Installing mongosh from MongoDB official yum repo."
cat > /etc/yum.repos.d/mongodb-org-8.0.repo <<REPO
[mongodb-org-8.0]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/redhat/9/mongodb-org/8.0/x86_64/
gpgcheck=1
enabled=1
gpgkey=https://pgp.mongodb.com/server-8.0.asc
REPO
dnf install -y mongodb-mongosh

log "Installing documentdb-server meta-package from Copr."
dnf install -y --nogpgcheck documentdb-server

# Workaround for the currently-published Copr build: the gateway invokes the
# `openssl` CLI to auto-generate self-signed TLS material on first start, but
# does not yet declare a Requires on it (the spec has been updated; this stays
# until the next Copr rebuild).
log "Installing openssl CLI (gateway TLS auto-generation)."
dnf install -y --nogpgcheck openssl

# Workaround for the currently-published Copr build:
#   * On Fedora chroots, the runtime extension dependencies (postgresql-contrib,
#     pgvector, postgis) hang off the `documentdb` subpackage but the published
#     `documentdb-server` meta-package does not yet pull them in (the spec has
#     since been fixed).  Install them directly here so the smoke test can run.
#     Note: we cannot just install the `documentdb` subpackage because the
#     published Fedora build emits both `documentdb` and `postgresql18-documentdb`
#     with overlapping files; that is a separate spec bug.
case "${CHROOT}" in
    fedora-*)
        log "Installing missing runtime deps (postgresql-contrib pgvector postgis libpq-devel)."
        # libpq-devel ships /usr/bin/pg_config, which documentdb-setup needs to
        # detect the Fedora native /usr/bin PostgreSQL layout.
        dnf install -y --nogpgcheck postgresql-contrib pgvector postgis libpq-devel
        ;;
esac

rpm -q documentdb-gateway >/dev/null || fail "documentdb-gateway was not installed"
command -v documentdb_gateway >/dev/null || fail "documentdb_gateway binary missing"
command -v documentdb-setup   >/dev/null || fail "documentdb-setup helper missing"

if [[ "${OVERLAY_FLAG}" == "1" && -r /tmp/documentdb-setup-overlay.sh ]]; then
    log "Overlaying local documentdb-setup over the RPM-installed copy."
    install -m 0755 /tmp/documentdb-setup-overlay.sh /usr/bin/documentdb-setup
fi

log "Provisioning DocumentDB via documentdb-setup."
PASSWORD_FILE="$(mktemp)"
chmod 600 "${PASSWORD_FILE}"
printf "%s" "${PASSWORD}" > "${PASSWORD_FILE}"

SETUP_LOG=/tmp/documentdb-setup.log
documentdb-setup \
    --username "${USERNAME}" \
    --password-file "${PASSWORD_FILE}" \
    --verbose \
    > "${SETUP_LOG}" 2>&1 &
SETUP_PID=$!

trap "kill ${SETUP_PID} 2>/dev/null || true" EXIT

# Wait for either readiness banner or process exit.
for _ in $(seq 1 120); do
    if grep -Fq "SUCCESS: DocumentDB is ready." "${SETUP_LOG}" 2>/dev/null; then
        break
    fi
    if ! kill -0 "${SETUP_PID}" 2>/dev/null; then
        break
    fi
    sleep 1
done

if ! grep -Fq "SUCCESS: DocumentDB is ready." "${SETUP_LOG}"; then
    cat "${SETUP_LOG}"
    if [[ -r /var/lib/documentdb/gateway.log ]]; then
        echo "----- /var/lib/documentdb/gateway.log -----"
        cat /var/lib/documentdb/gateway.log
        echo "----- end gateway.log -----"
    fi
    fail "documentdb-setup did not report readiness"
fi
cat "${SETUP_LOG}"

log "Running mongosh CRUD smoke test against the gateway."
WRAPPER=/tmp/mongosh-wrapper.js
INIT=/tmp/mongosh-init.js
LOGFILE=/tmp/mongosh-smoke.log

cat > "${WRAPPER}" <<\JS
const port = process.env.DOCUMENTDB_PORT;
const username = process.env.DOCUMENTDB_USERNAME;
const password = process.env.DOCUMENTDB_PASSWORD;
const initFile = process.env.DOCUMENTDB_INIT_FILE;
const uri = `mongodb://${encodeURIComponent(username)}:${encodeURIComponent(password)}@localhost:${port}/admin?authSource=admin&authMechanism=SCRAM-SHA-256&tls=true&tlsAllowInvalidCertificates=true`;
db = connect(uri);
load(initFile);
JS

cat > "${INIT}" <<\JS
const database = db.getSiblingDB("coprSmokeDb");
database.smoke.deleteMany({});
database.smoke.insertOne({ name: "John Doe", email: "john@email.com" });
const doc = database.smoke.findOne({ name: "John Doe" });
if (!doc || doc.email !== "john@email.com") {
    print("SMOKE_FAIL: unexpected document " + JSON.stringify(doc));
    quit(1);
}
print("SMOKE_OK");
printjson(doc);
JS

env \
    DOCUMENTDB_PORT="${GATEWAY_PORT}" \
    DOCUMENTDB_USERNAME="${USERNAME}" \
    DOCUMENTDB_PASSWORD="${PASSWORD}" \
    DOCUMENTDB_INIT_FILE="${INIT}" \
    mongosh --quiet --nodb "${WRAPPER}" > "${LOGFILE}" 2>&1 \
    || { cat "${LOGFILE}"; fail "mongosh smoke test exited non-zero"; }

cat "${LOGFILE}"
grep -Fq "SMOKE_OK" "${LOGFILE}" || fail "mongosh smoke test did not print SMOKE_OK"
grep -Fq "John Doe" "${LOGFILE}" || fail "mongosh smoke test did not return inserted doc"

log "Copr install + gateway smoke test PASSED."
'

docker run "${container_args[@]}" \
    -e LANG=C.UTF-8 \
    "${IMAGE}" \
    bash -c "${INNER_SCRIPT}" _ "${COPR_PROJECT}" "${CHROOT}" "${USERNAME}" "${PASSWORD}" "${OVERLAY_FLAG}"
