#!/bin/bash
# Locally reproduce the per-chroot *dynamic* BuildRequires resolution that
# Copr/mock performs during the rebuild phase.
#
# Background
# ----------
# `./packaging/test_copr_srpm.sh` and `dnf builddep <spec>` only exercise the
# SRPM's *static* BuildRequires (the ones listed in the spec header).  When
# the spec uses `%generate_buildrequires` + `%cargo_generate_buildrequires`
# (Fedora's cargo-rpm-macros), rpmbuild walks the vendored Cargo tree in
# %prep and emits one `BuildRequires: crate(<name>) >= <ver>` line per
# crate.  Those dynamic BRs are what the Copr builder actually tries to
# install; failures like
#
#     nothing provides requested (crate(bson/default) >= 2.7.0 ...)
#
# only surface there.  This script reproduces that step inside a container
# that mirrors each Copr chroot, so dependency-resolution failures can be
# caught before pushing to Copr.
#
# What it does
# ------------
# For the selected chroot:
#   1. Spin up a matching container (rockylinux:9, fedora:42, fedora:43)
#      with the same external repos Copr has configured for the project
#      (EPEL + CRB + PGDG for EL9; PGDG for Fedora 42; native for Fedora 43).
#   2. Install the SRPM and run `rpmbuild -br --nodeps` on the extracted
#      spec.  That executes %generate_buildrequires exactly the way mock
#      does and produces `*.buildreqs.nosrc.rpm` next to the original SRPM.
#   3. Run `dnf builddep --nogpgcheck` against that nosrc.rpm.  This is the
#      moment Copr fails on EL9; the script surfaces the same
#      `nothing provides requested (crate(...))` message locally.
#
# Usage
# -----
#   ./packaging/test_copr_dynamic_br.sh [--chroot CHROOT] [--srpm PATH]
#
# --chroot fedora-43-x86_64 (default) | fedora-42-x86_64 | epel-9-x86_64
# --srpm   Path to an already-built SRPM; default is the most recent
#          `documentdb-*.src.rpm` in packaging/.  If none exists, the
#          script invokes `test_copr_srpm.sh` to build one.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
packaging_dir="$script_dir/packaging"

CHROOT="fedora-43-x86_64"
SRPM=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --chroot)
            shift
            CHROOT="$1"
            ;;
        --srpm)
            shift
            SRPM="$1"
            ;;
        -h|--help)
            grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 2
            ;;
    esac
    shift
done

case "$CHROOT" in
    fedora-43-x86_64) IMAGE="fedora:43" ;;
    fedora-42-x86_64) IMAGE="fedora:42" ;;
    epel-9-x86_64)    IMAGE="rockylinux:9" ;;
    *) echo "Unsupported chroot: $CHROOT" >&2; exit 2 ;;
esac

# Locate or build an SRPM to feed into the container.
if [[ -z "$SRPM" ]]; then
    SRPM="$(ls -t "$packaging_dir"/documentdb-*.src.rpm 2>/dev/null | head -1 || true)"
fi
if [[ -z "$SRPM" || ! -f "$SRPM" ]]; then
    echo "[dyn-br] No SRPM found; building one via test_copr_srpm.sh ..."
    "$script_dir/packaging/test_copr_srpm.sh" >/dev/null
    SRPM="$(ls -t "$packaging_dir"/documentdb-*.src.rpm | head -1)"
fi

echo "[dyn-br] chroot=$CHROOT image=$IMAGE srpm=$SRPM"

# The in-container script: install the SRPM, invoke %generate_buildrequires,
# then try to resolve the resulting dynamic BR set with dnf.
in_container=$(cat <<'EOS'
set -euo pipefail
CHROOT="$1"

echo "--- [dyn-br] installing base build tooling ---"
dnf install -y dnf-plugins-core rpm-build rpmdevtools >/dev/null

case "$CHROOT" in
    epel-9-x86_64)
        dnf install -y epel-release >/dev/null
        dnf config-manager --set-enabled crb >/dev/null
        dnf -qy module disable postgresql >/dev/null 2>&1 || true
        dnf install -y \
            https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm \
            >/dev/null
        # cargo-rpm-macros ships %cargo_generate_buildrequires; it lives in EPEL on EL9.
        dnf install -y --nogpgcheck cargo cargo-rpm-macros rust >/dev/null
        ;;
    fedora-42-x86_64)
        dnf install -y \
            https://download.postgresql.org/pub/repos/yum/reporpms/F-42-x86_64/pgdg-fedora-repo-latest.noarch.rpm \
            >/dev/null
        dnf install -y --nogpgcheck cargo rust-packaging >/dev/null
        ;;
    fedora-43-x86_64)
        dnf install -y cargo rust-packaging >/dev/null
        ;;
esac

rpmdev-setuptree
cp /srpm/*.src.rpm /root/
SRPM_NAME="$(basename /srpm/*.src.rpm)"

echo "--- [dyn-br] installing SRPM (drops sources + spec into rpmbuild tree) ---"
rpm -i "/root/${SRPM_NAME}" 2>&1 | tail -5 || true

SPEC=$(ls /root/rpmbuild/SPECS/*.spec | head -1)
echo "--- [dyn-br] spec=$SPEC ---"

# -br triggers %prep + %generate_buildrequires and stops, emitting
# <name>-<ver>-<rel>.buildreqs.nosrc.rpm with the dynamic BR set.
# --nodeps lets us skip the static BR check (we already validated those).
echo "--- [dyn-br] running rpmbuild -br to generate dynamic BuildRequires ---"
set +e
rpmbuild -br --nodeps "$SPEC" 2>&1 | tee /tmp/genbr.log
rc_genbr=${PIPESTATUS[0]}
set -e
# rpmbuild exits 11 when `-br` stops at the buildrequires stage after
# emitting the nosrc.rpm — that is the *success* path for this script.
# Any other non-zero rc means %prep or %generate_buildrequires itself blew up.
if [[ $rc_genbr -ne 0 && $rc_genbr -ne 11 ]]; then
    echo "--- [dyn-br] %generate_buildrequires itself failed (rc=$rc_genbr) ---"
    exit "$rc_genbr"
fi

NOSRC=$(ls /root/rpmbuild/SRPMS/*.buildreqs.nosrc.rpm 2>/dev/null | head -1 || true)
if [[ -z "$NOSRC" ]]; then
    echo "--- [dyn-br] no buildreqs.nosrc.rpm produced; spec may not use %generate_buildrequires ---"
    exit 0
fi
echo "--- [dyn-br] dynamic BR stub: $NOSRC ---"
echo "--- [dyn-br] dynamic BuildRequires list: ---"
rpm -qp --requires "$NOSRC" | sed 's/^/    /'

echo "--- [dyn-br] resolving dynamic BuildRequires via dnf builddep ---"
set +e
dnf builddep -y --nogpgcheck "$NOSRC" 2>&1 | tee /tmp/builddep.log
rc_bd=${PIPESTATUS[0]}
set -e

if [[ $rc_bd -eq 0 ]]; then
    echo "[dyn-br] RESULT=PASS ($CHROOT)"
else
    echo "[dyn-br] RESULT=FAIL ($CHROOT)  -- missing providers below:"
    grep -E "nothing provides|No match for argument" /tmp/builddep.log | sort -u | sed 's/^/    /'
fi
exit "$rc_bd"
EOS
)

docker run --rm \
    -v "$(dirname "$SRPM"):/srpm:ro" \
    -e CHROOT="$CHROOT" \
    "$IMAGE" \
    bash -c "$in_container" _ "$CHROOT"
