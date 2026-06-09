#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# documentdb-gateway-wrapper — DEV-ONLY dispatch wrapper for the DocumentDB
# gateway. This script is **not** shipped by any package; it exists to let
# the e2e smoke tests exercise the legacy multi-subcommand CLI shape from
# the source tree before the Rust binary grows its own `run`/`--check`/
# `--version` flags (see packaging-design.md §4.3).
#
# In packaging Track 1:
#   - /usr/bin/documentdb-gateway is the Rust daemon binary (runtime only)
#   - PG-side helpers (register-gateway, admin) live in
#     /usr/bin/documentdb-{register-gateway,gateway-admin} and ship in the
#     documentdb-postgresql-tools package.
#
# Subcommands this wrapper dispatches to (dev use only):
#   documentdb-gateway-wrapper.sh run [--config FILE]   → exec the Rust daemon
#   documentdb-gateway-wrapper.sh --check               → connectivity probe
#   documentdb-gateway-wrapper.sh --version             → version info
#   documentdb-gateway-wrapper.sh setup [flags]         → register-gateway
#   documentdb-gateway-wrapper.sh admin <cmd> [flags]   → user management

set -euo pipefail

readonly PROG="documentdb-gateway-wrapper"
readonly DAEMON_BIN="/usr/lib/documentdb/documentdb-gateway-daemon"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Helper scripts may live beside this wrapper (dev) or in /usr/lib/documentdb (packaged).
resolve_helper() {
    local name="$1"
    local candidates=(
        "/usr/lib/documentdb/${name}"
        "${SCRIPT_DIR}/${name}"
    )
    for c in "${candidates[@]}"; do
        if [[ -x "$c" ]]; then
            printf '%s' "$c"
            return 0
        fi
    done
    echo "${PROG}: error: helper '${name}' not found." >&2
    exit 1
}

# Resolve the daemon binary (packaged path or dev-tree path).
resolve_daemon() {
    if [[ -x "${DAEMON_BIN}" ]]; then
        printf '%s' "${DAEMON_BIN}"
        return 0
    fi
    # Dev fallback: look next to this script or in the repo build output.
    local dev_candidates=(
        "${SCRIPT_DIR}/../../pg_documentdb_gw/target/release-with-symbols/documentdb_gateway"
        "${SCRIPT_DIR}/../../pg_documentdb_gw/target/release/documentdb_gateway"
        "${SCRIPT_DIR}/../../pg_documentdb_gw/target/debug/documentdb_gateway"
    )
    for c in "${dev_candidates[@]}"; do
        if [[ -x "$c" ]]; then
            printf '%s' "$c"
            return 0
        fi
    done
    echo "${PROG}: error: daemon binary not found at ${DAEMON_BIN}" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: documentdb-gateway-wrapper.sh <command> [options]

DEV-ONLY: this wrapper is not installed by any package. In production
deployments, the gateway binary lives at /usr/bin/documentdb-gateway and
PG-side helpers live in /usr/bin/documentdb-{register-gateway,gateway-admin}
shipped by the documentdb-postgresql-tools package.

Commands:
  run              Start the gateway daemon (default when invoked by systemd)
  setup            Register the gateway against a local PostgreSQL instance
                   (delegates to documentdb-register-gateway.sh)
  admin <subcmd>   User/role management (create-user, drop-user, list-users,
                   reset-password, check)

Options:
  --check          Connectivity probe (post-install smoke test)
  --version        Print version information
  -h, --help       Show this help message
EOF
}

# ── Main dispatch ───────────────────────────────────────────────────

if [[ $# -lt 1 ]]; then
    usage
    exit 1
fi

case "$1" in
    run)
        shift
        daemon="$(resolve_daemon)"
        exec "${daemon}" "$@"
        ;;
    setup)
        shift
        helper="$(resolve_helper "documentdb-register-gateway.sh")"
        exec bash "${helper}" "$@"
        ;;
    admin)
        shift
        helper="$(resolve_helper "documentdb-gateway-admin.sh")"
        exec bash "${helper}" "$@"
        ;;
    --check)
        shift
        helper="$(resolve_helper "documentdb-gateway-admin.sh")"
        exec bash "${helper}" check "$@"
        ;;
    --version)
        daemon="$(resolve_daemon)"
        exec "${daemon}" --version 2>/dev/null || echo "documentdb-gateway (version unknown)"
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        echo "${PROG}: unknown command '$1'. Run '${PROG} --help' for usage." >&2
        exit 1
        ;;
esac
