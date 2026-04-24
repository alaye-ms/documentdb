#!/bin/bash
# Full local rebuild of DocumentDB *inside the target Copr chroot*.
#
# This is the most faithful local reproduction of a Copr build: unlike
# `test_copr_srpm.sh` (which only builds the SRPM on fedora:latest) and
# `test_copr_dynamic_br.sh` (which only resolves BuildRequires), this
# script mirrors Copr end to end:
#
#   1. Spin up a container matching the chroot (rockylinux:9 / fedora:42 /
#      fedora:43) with the same external repos Copr uses (EPEL + CRB + PGDG
#      for EL9; PGDG for F42; native for F43).
#   2. Run `make -f .copr/Makefile srpm` inside that container — so macros
#      such as `%?postgresql_default` evaluate for the *target* distro and
#      the resulting SRPM's BuildRequires match what Copr would see.
#   3. `dnf builddep` the freshly-built SRPM.
#   4. `rpmbuild --rebuild` — runs %prep, %build, %install, and %files,
#      which is the only way to catch install-stage errors such as:
#
#         error: File listed twice: /usr/pgsql-18/lib/pg_documentdb.so
#         error: Installed (but unpackaged) file(s) found
#
#      These are the failures reported by Copr build 10363880; the other
#      test scripts in this directory cannot see them because they stop
#      before %install.
#
# Usage
# -----
#   ./packaging/test_copr_rebuild.sh [--chroot CHROOT] [--keep]
#
# --chroot fedora-43-x86_64 (default) | fedora-42-x86_64 | epel-9-x86_64
# --keep   Keep the container on exit for post-mortem
#          (`docker exec -it docdb-rebuild-<chroot> bash`).
#
# The full build takes several minutes per chroot because it compiles the
# C extensions, vendored libbson / pcre2 / pg_cron, and the Rust gateway.
# Output is streamed live.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CHROOT="fedora-43-x86_64"
KEEP=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --chroot) shift; CHROOT="$1" ;;
        --keep)   KEEP=1 ;;
        -h|--help)
            grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'
            exit 0
            ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

case "$CHROOT" in
    fedora-43-x86_64) IMAGE="fedora:43" ;;
    fedora-42-x86_64) IMAGE="fedora:42" ;;
    epel-9-x86_64)    IMAGE="rockylinux:9" ;;
    *) echo "Unsupported chroot: $CHROOT" >&2; exit 2 ;;
esac

echo "[rebuild] chroot=$CHROOT image=$IMAGE source=$script_dir"

CONTAINER_NAME="docdb-rebuild-${CHROOT}"
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

in_container=$(cat <<'EOS'
set -euo pipefail
CHROOT="$1"

echo "--- [rebuild] installing base tooling ---"
dnf install -y --allowerasing dnf-plugins-core rpm-build rpmdevtools curl make >/dev/null

case "$CHROOT" in
    epel-9-x86_64)
        dnf install -y epel-release >/dev/null
        dnf config-manager --set-enabled crb >/dev/null
        dnf -qy module disable postgresql >/dev/null 2>&1 || true
        dnf install -y \
            https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm \
            >/dev/null
        dnf install -y --nogpgcheck cargo cargo-rpm-macros rust git tar gzip >/dev/null
        ;;
    fedora-42-x86_64)
        dnf install -y \
            https://download.postgresql.org/pub/repos/yum/reporpms/F-42-x86_64/pgdg-fedora-repo-latest.noarch.rpm \
            >/dev/null
        dnf install -y --nogpgcheck cargo rust-packaging git tar gzip >/dev/null
        ;;
    fedora-43-x86_64)
        dnf install -y cargo rust-packaging git tar gzip >/dev/null
        ;;
esac

# Copy the source tree out of the read-only mount so root-owned outputs
# (rpmbuild/, packaging/*.src.rpm) do not pollute the host working copy.
mkdir -p /build
cp -a /src/. /build/
cd /build
rm -rf rpmbuild packaging/*.src.rpm

echo "--- [rebuild] building SRPM *in target chroot* via .copr/Makefile ---"
mkdir -p /out
make -f .copr/Makefile srpm outdir=/out 2>&1 | tail -15

SRPM=$(ls /out/*.src.rpm | head -1)
echo "--- [rebuild] SRPM: $SRPM ---"
echo "--- [rebuild] static BuildRequires in this SRPM: ---"
rpm -qp --requires "$SRPM" | sed 's/^/    /'

echo "--- [rebuild] installing static BuildRequires ---"
dnf builddep -y --nogpgcheck "$SRPM" >/dev/null

echo "--- [rebuild] running rpmbuild --rebuild (full build + %install + %files) ---"
set +e
rpmbuild --rebuild --nodeps "$SRPM" 2>&1 | tee /tmp/rebuild.log
rc=${PIPESTATUS[0]}
set -e

echo ""
echo "--- [rebuild] exit code: $rc ---"
if [[ $rc -ne 0 ]]; then
    echo "--- [rebuild] last 80 lines of build log ---"
    tail -80 /tmp/rebuild.log
    echo ""
    echo "--- [rebuild] install/files errors (if any) ---"
    grep -E "error:|File listed twice|Installed \(but unpackaged\)|File not found|aborting|Found.*in installed files" \
        /tmp/rebuild.log | head -40 | sed 's/^/    /'
    echo "[rebuild] RESULT=FAIL ($CHROOT)"
else
    echo "--- [rebuild] produced RPMs: ---"
    ls -la /root/rpmbuild/RPMS/*/*.rpm 2>/dev/null | sed 's/^/    /' | tail -20
    echo "[rebuild] RESULT=PASS ($CHROOT)"
fi
exit "$rc"
EOS
)

docker_opts=(--name "$CONTAINER_NAME" -v "$script_dir:/src:ro")
if [[ "$KEEP" -eq 0 ]]; then
    docker_opts+=(--rm)
fi

docker run "${docker_opts[@]}" \
    "$IMAGE" \
    bash -c "$in_container" _ "$CHROOT"
