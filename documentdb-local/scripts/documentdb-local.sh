#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# documentdb-local — explains the public systemd surfaces for the
# stand-alone packages.

set -euo pipefail

readonly PROG="documentdb-local"
readonly FIXED_PUBLIC_TARGET="documentdb-local@18.target"

die() { echo "${PROG}: error: $*" >&2; exit 1; }
log() { echo "[${PROG}] $*"; }

usage() {
    cat <<'EOF'
Usage: documentdb-local <command> [args]

Commands:
  switch-default N    Unsupported. Use documentdb-local@N.target directly.

Options:
  -h, --help          Show this help message

The public day-2 surface is fixed:
  documentdb-local.target -> documentdb-local@18.target

To operate on a non-default major explicitly, use the per-major target:
  sudo systemctl status documentdb-local@17.target

The first-party packages intentionally do not support switching the public
alias in place.
EOF
}

# ── switch-default ──────────────────────────────────────────────────

cmd_switch_default() {
    local new_major="$1"

    [[ "${new_major}" =~ ^[0-9]+$ ]] || die "Major version must be a positive integer."
    die "switch-default is intentionally unsupported. documentdb-local.target stays fixed to ${FIXED_PUBLIC_TARGET}; use documentdb-local@${new_major}.target directly."
}

# ── Main ────────────────────────────────────────────────────────────

if [[ $# -lt 1 ]]; then
    usage
    exit 1
fi

case "$1" in
    switch-default)
        [[ $# -ge 2 ]] || die "switch-default requires a major version argument."
        cmd_switch_default "$2"
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        die "Unknown command: $1. Run '${PROG} --help' for usage."
        ;;
esac
