#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# test_packaging_locally.sh — one-shot orchestrator for building and
# end-to-end-testing all four Track 1 packages (per packaging-design.md
# §4) inside Docker on the developer's workstation. Mirrors what the
# GitHub Actions workflows (build_deb_packages.yml,
# build_rpm_packages.yml) do in CI, but as a single command so a local
# change can be smoke-tested before pushing.
#
# What it does
#   1. Builds the extension DEB/RPM (packaging/build_packages.sh)
#      — this is the only slow step (Rust + C compilation in Docker).
#   2. Builds the gateway DEB/RPM in Docker
#      (packaging/gateway/build_gateway_packages.sh).
#   3. Builds the three "extras" (documentdb-postgresql-tools,
#      documentdb-<N>, documentdb meta) via
#      packaging/build_extra_packages.sh — pure-shell builders, fast.
#   4. Builds the test image which apt/dnf-installs all four packages
#      and runs test-gateway-install-entrypoint{,-rpm}.sh inside.
#
# What it does NOT do
#   - Push anything. All artifacts stay under packaging/ (configurable
#     via --output-dir).
#   - Validate on a real systemd host. The Docker container runs the
#     test entrypoint, which exercises documentdb-setup, register-
#     gateway, the gateway binary, and managed-block writes — but
#     systemd is not present, so the wizard's nohup fallback path is
#     what actually starts the gateway. For full systemd validation,
#     run the produced .deb on an Ubuntu 24.04 VM directly.
#
# Examples
#   # Paved-road combination (recommended for PR validation):
#   ./packaging/test_packaging_locally.sh --os ubuntu24.04 --pg 18
#
#   # Skip building the extension (e.g. you only changed shell scripts
#   # and want a faster smoke test). Re-uses the most recent matching
#   # .deb / .rpm under --output-dir.
#   ./packaging/test_packaging_locally.sh --os ubuntu24.04 --pg 18 \
#       --skip-extension-build
#
#   # RHEL 9, PG 17 (community RPM channel):
#   ./packaging/test_packaging_locally.sh --os rhel9 --pg 17
#
#   # Build artifacts only, no test (still useful for inspection):
#   ./packaging/test_packaging_locally.sh --os ubuntu24.04 --pg 18 \
#       --build-only

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OSS_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── Defaults ────────────────────────────────────────────────────────
OS=""
PG=""
DOCUMENTDB_VERSION=""
OUTPUT_DIR="packaging"
DEFAULT_PG_MAJOR="18"
SKIP_EXTENSION_BUILD=false
SKIP_GATEWAY_BUILD=false
SKIP_EXTRAS_BUILD=false
BUILD_ONLY=false
KEEP_IMAGES=false

# ── Helpers ─────────────────────────────────────────────────────────

log()  { printf '\033[1;36m[test-pkg]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[test-pkg WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[test-pkg ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

warn_if_known_docker_desktop_limits() {
    local server_platform=""

    server_platform="$(docker version --format '{{.Server.Platform.Name}}' 2>/dev/null || true)"
    if printf '%s\n' "${server_platform}" | grep -Fqi 'Docker Desktop'; then
        warn "Docker Desktop can still hide listener PIDs and restrict some sudo-owned-file writes inside the test container even when SYS_PTRACE is requested. Some guard-style checks may still SKIP there; use a rootful Linux Docker host or Ubuntu VM for full Workflow C validation."
    fi
}

add_docker_test_capabilities() {
    local image="$1"
    local -n args_ref="$2"

    args_ref=()
    if docker run --rm --cap-add=SYS_PTRACE --entrypoint /bin/true "${image}" >/dev/null 2>&1; then
        args_ref+=(--cap-add=SYS_PTRACE)
        log "Docker clean-install test will request SYS_PTRACE to improve listener-PID discovery."
    else
        warn "Docker refused SYS_PTRACE for ${image}; listener-PID guard tests may SKIP in this environment."
    fi
}

usage() {
    cat <<'EOF'
Usage: test_packaging_locally.sh --os <OS> --pg <PG_VERSION> [OPTIONS]

Build all four DocumentDB Track 1 packages and run the gateway clean-
install E2E suite inside Docker. The recommended developer-loop pre-PR
check for any changes under oss/documentdb-local/, oss/packaging/,
oss/pg_documentdb_gw/, or the wizard scripts.

Required:
  --os <OS>             One of: deb11, deb12, deb13, ubuntu22.04,
                        ubuntu24.04, rhel8, rhel9.
                        Paved-road default = ubuntu24.04.
  --pg <PG_VERSION>     One of: 15, 16, 17, 18.
                        Paved-road default = 18.

Optional:
  --version <VER>       DocumentDB version string baked into the
                        artifacts (default: read from
                        pg_documentdb_core/documentdb_core.control).
  --output-dir <DIR>    Output directory (relative to oss/) for all
                        produced packages (default: packaging).
  --default-pg-major N  PG major the `documentdb` meta package pins to
                        (default: 18, matches packaging-design.md §9.1).
  --skip-extension-build
                        Re-use the most recent extension .deb/.rpm
                        matching --os and --pg under --output-dir
                        instead of rebuilding. Use when iterating on
                        shell-script / packaging-only changes — saves
                        ~5-10 minutes of Docker-based extension
                        rebuild on every loop.
  --skip-gateway-build  Re-use the most recent gateway .deb/.rpm.
                        Use after a shell-only change (the gateway
                        binary doesn't change).
  --skip-extras-build   Re-use the most recent tools + standalone
                        .deb/.rpm. Use ONLY when you have not touched
                        documentdb-setup.sh, documentdb-tune.sh, etc.
  --build-only          Build packages but skip the Docker test image
                        build + run. Use when you just want artifacts
                        for manual VM testing.
  --keep-images         Don't `docker rmi` the test image at the end.
                        Useful for `docker run -it ... bash` inspection.
  -h, --help            Show this help.

Examples:
  # Paved-road quick check (PR pre-flight):
  ./packaging/test_packaging_locally.sh --os ubuntu24.04 --pg 18

  # Fast iteration on shell-script changes (no extension/gateway rebuild):
  ./packaging/test_packaging_locally.sh --os ubuntu24.04 --pg 18 \
      --skip-extension-build --skip-gateway-build

  # Build only, then `docker run -it ... bash` to poke around:
  ./packaging/test_packaging_locally.sh --os ubuntu24.04 --pg 18 \
      --build-only

Prerequisites (script will check):
  - docker (running daemon, current user in docker group)
  - On RPM matrix: rpmbuild (Ubuntu: `apt install rpm`)
EOF
}

# ── Argument parsing ────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --os)                   OS="$2"; shift 2 ;;
        --pg)                   PG="$2"; shift 2 ;;
        --version)              DOCUMENTDB_VERSION="$2"; shift 2 ;;
        --output-dir)           OUTPUT_DIR="$2"; shift 2 ;;
        --default-pg-major)     DEFAULT_PG_MAJOR="$2"; shift 2 ;;
        --skip-extension-build) SKIP_EXTENSION_BUILD=true; shift ;;
        --skip-gateway-build)   SKIP_GATEWAY_BUILD=true; shift ;;
        --skip-extras-build)    SKIP_EXTRAS_BUILD=true; shift ;;
        --build-only)           BUILD_ONLY=true; shift ;;
        --keep-images)          KEEP_IMAGES=true; shift ;;
        -h|--help)              usage; exit 0 ;;
        *)                      die "Unknown argument: $1 (try --help)" ;;
    esac
done

[[ -n "${OS}" ]] || { usage; die "--os is required."; }
[[ -n "${PG}" ]] || { usage; die "--pg is required."; }

# Validate values before going further so an obvious typo
# (`--os ubunut24.04`) surfaces a clear "Invalid --os" error rather
# than failing later with an inscrutable docker / apt-repo lookup.
case "${OS}" in
    deb11|deb12|deb13|ubuntu22.04|ubuntu24.04) PACKAGE_TYPE="deb" ;;
    rhel8|rhel9)                               PACKAGE_TYPE="rpm" ;;
    *) die "Invalid --os '${OS}' (allowed: deb11, deb12, deb13, ubuntu22.04, ubuntu24.04, rhel8, rhel9)" ;;
esac

case "${PG}" in
    15|16|17|18) ;;
    *) die "Invalid --pg '${PG}' (allowed: 15, 16, 17, 18)" ;;
esac

# Resolve DOCUMENTDB_VERSION the same way the build scripts do — from
# the extension control file — when the operator didn't pass --version.
# Keeping this in lock-step with build_packages.sh's logic means the
# produced artifact filenames line up with the patterns we look for
# below in `find_latest_artifact`.
if [[ -z "${DOCUMENTDB_VERSION}" ]]; then
    control_file="${OSS_ROOT}/pg_documentdb_core/documentdb_core.control"
    [[ -r "${control_file}" ]] \
        || die "Cannot read ${control_file}; pass --version explicitly."
    DOCUMENTDB_VERSION="$(grep -E '^default_version' "${control_file}" \
        | sed -E "s/.*'([0-9]+\.[0-9]+-[0-9]+)'.*/\1/" \
        | tr '-' '.')"
    [[ -n "${DOCUMENTDB_VERSION}" ]] \
        || die "Failed to extract DocumentDB version from ${control_file}."
    log "Resolved --version = ${DOCUMENTDB_VERSION} (from ${control_file})"
fi

# ── Pre-flight checks ───────────────────────────────────────────────

log "Pre-flight: checking required tools."
command -v docker >/dev/null 2>&1 \
    || die "docker not found on PATH. Install Docker Desktop or the Docker engine."
docker info >/dev/null 2>&1 \
    || die "docker daemon is not reachable. Start Docker Desktop or 'sudo systemctl start docker'."
warn_if_known_docker_desktop_limits

if [[ "${PACKAGE_TYPE}" == "rpm" ]] && [[ "${SKIP_EXTRAS_BUILD}" != "true" ]]; then
    command -v rpmbuild >/dev/null 2>&1 \
        || die "rpmbuild not found on PATH. Install it: 'sudo apt install rpm' on Debian/Ubuntu hosts."
fi

abs_output_dir="${OSS_ROOT}/${OUTPUT_DIR}"
mkdir -p "${abs_output_dir}"

log "Configuration:"
log "  OS:                  ${OS} (${PACKAGE_TYPE})"
log "  PostgreSQL major:    ${PG}"
log "  DocumentDB version:  ${DOCUMENTDB_VERSION}"
log "  Output dir:          ${abs_output_dir}"
log "  Default PG major:    ${DEFAULT_PG_MAJOR}"
log "  Skip extension:      ${SKIP_EXTENSION_BUILD}"
log "  Skip gateway:        ${SKIP_GATEWAY_BUILD}"
log "  Skip extras:         ${SKIP_EXTRAS_BUILD}"
log "  Build only (no run): ${BUILD_ONLY}"

# ── Helpers used below ──────────────────────────────────────────────

# find_latest_artifact <pattern>
# Returns the most-recently-modified file under abs_output_dir whose
# basename matches the egrep pattern. Empty stdout + non-zero exit if
# nothing matches; the caller decides whether that is fatal.
find_latest_artifact() {
    local pattern="$1"
    find "${abs_output_dir}" -maxdepth 1 -type f \
        -printf '%T@ %p\n' 2>/dev/null \
        | awk '{ $1=""; print substr($0,2) }' \
        | grep -E "/(${pattern})$" \
        | head -n 1
}

# ── Step 1: build the extension package ─────────────────────────────

if [[ "${SKIP_EXTENSION_BUILD}" == "true" ]]; then
    log "Skipping extension build (--skip-extension-build)."
    if [[ "${PACKAGE_TYPE}" == "deb" ]]; then
        ext_artifact="$(find_latest_artifact "${OS}-postgresql-${PG}-documentdb_${DOCUMENTDB_VERSION}.*\.deb" || true)"
    else
        ext_artifact="$(find_latest_artifact "${OS}-postgresql${PG}-documentdb-${DOCUMENTDB_VERSION}.*\.(x86_64|aarch64)\.rpm" || true)"
    fi
    [[ -n "${ext_artifact}" ]] \
        || die "--skip-extension-build but no matching extension package found in ${abs_output_dir}. Drop the flag to build it."
    log "Reusing: ${ext_artifact}"
else
    log "Building extension package (${OS}, pg${PG}, ${DOCUMENTDB_VERSION})..."
    "${OSS_ROOT}/packaging/build_packages.sh" \
        --os "${OS}" \
        --pg "${PG}" \
        --version "${DOCUMENTDB_VERSION}" \
        --output-dir "${OUTPUT_DIR}"
fi

# ── Step 2: build the gateway package + (optionally) the extras +
#           the test image. build_gateway_packages.sh now does all
#           three when --test-clean-install is set (per the
#           orchestrator update that lands with this change).
# ────────────────────────────────────────────────────────────────────

build_gateway_args=(
    --os "${OS}"
    --pg "${PG}"
    --version "${DOCUMENTDB_VERSION}"
    --output-dir "${OUTPUT_DIR}"
)

if [[ "${SKIP_GATEWAY_BUILD}" == "true" ]]; then
    # When the gateway is skipped, we can't drive the
    # --test-clean-install flow from build_gateway_packages.sh because
    # that script unconditionally rebuilds the gateway binary. Run the
    # extras build (if needed) and the docker test build manually
    # below.
    log "Skipping gateway build (--skip-gateway-build). Will reuse existing artifacts."
elif [[ "${BUILD_ONLY}" == "true" ]]; then
    log "Building gateway package only (--build-only); test image will not be built."
    "${OSS_ROOT}/packaging/gateway/build_gateway_packages.sh" "${build_gateway_args[@]}"
else
    log "Building gateway package + extras + test image, then running the E2E suite..."
    "${OSS_ROOT}/packaging/gateway/build_gateway_packages.sh" \
        "${build_gateway_args[@]}" \
        --test-clean-install
fi

# ── Step 3: when --skip-gateway-build was used, drive the rest of
#            the flow manually (build extras + test image, then run).
# ────────────────────────────────────────────────────────────────────

if [[ "${SKIP_GATEWAY_BUILD}" == "true" ]] && [[ "${BUILD_ONLY}" != "true" ]]; then
    # 3a. Resolve the existing gateway artifact (must exist or we
    # cannot proceed).
    if [[ "${PACKAGE_TYPE}" == "deb" ]]; then
        gw_artifact="$(find_latest_artifact "${OS}-documentdb-gateway_.*\.deb" || true)"
    else
        gw_artifact="$(find_latest_artifact "documentdb-gateway-${DOCUMENTDB_VERSION}-.*\.(x86_64|aarch64)\.rpm" || true)"
    fi
    [[ -n "${gw_artifact}" ]] \
        || die "--skip-gateway-build but no gateway package found in ${abs_output_dir}. Drop the flag to build it."
    log "Reusing gateway: ${gw_artifact}"

    # 3b. Build (or skip) the extras.
    if [[ "${SKIP_EXTRAS_BUILD}" == "true" ]]; then
        log "Skipping extras build (--skip-extras-build)."
    else
        log "Building extras (tools + stand-alone + meta)..."
        extras_args=(
            --type "${PACKAGE_TYPE}"
            --pg "${PG}"
            --version "${DOCUMENTDB_VERSION}"
            --output-dir "${abs_output_dir}"
            --default-pg-major "${DEFAULT_PG_MAJOR}"
        )
        if [[ "${PACKAGE_TYPE}" == "deb" ]]; then
            extras_args+=(--os-prefix "${OS}")
        fi
        "${OSS_ROOT}/packaging/build_extra_packages.sh" "${extras_args[@]}"
    fi

    # 3c. Manually drive the test docker build + run. Duplicates the
    # tail of build_gateway_packages.sh but is the cleanest way to
    # re-enter the test path when an earlier step was skipped.
    log "Building test image + running E2E suite..."

    if [[ "${PACKAGE_TYPE}" == "deb" ]]; then
        ext_path="$(find_latest_artifact "${OS}-postgresql-${PG}-documentdb_${DOCUMENTDB_VERSION}.*\.deb" || true)"
        gw_path="${gw_artifact}"
        tools_path="$(find_latest_artifact "${OS}-documentdb-postgresql-tools_${DOCUMENTDB_VERSION}_all\.deb" || true)"
        standalone_path="$(find_latest_artifact "${OS}-documentdb-${PG}_${DOCUMENTDB_VERSION}_all\.deb" || true)"
        for var in ext_path gw_path tools_path standalone_path; do
            [[ -n "${!var}" ]] || die "Missing artifact: ${var} not found in ${abs_output_dir}. Drop the matching --skip-* flag."
        done

        # Re-derive the test docker image (matches the mapping in
        # build_gateway_packages.sh).
        case "${OS}" in
            deb11)        TEST_DOCKER_IMAGE="debian:bullseye-slim" ;;
            deb12)        TEST_DOCKER_IMAGE="debian:bookworm-slim" ;;
            deb13)        TEST_DOCKER_IMAGE="debian:trixie-slim" ;;
            ubuntu22.04)  TEST_DOCKER_IMAGE="ubuntu:22.04" ;;
            ubuntu24.04)  TEST_DOCKER_IMAGE="ubuntu:24.04" ;;
        esac

        # Build args expect paths RELATIVE TO oss/ (the build context).
        rel_ext_path="${OUTPUT_DIR}/$(basename "${ext_path}")"
        rel_gw_path="${OUTPUT_DIR}/$(basename "${gw_path}")"
        rel_tools_path="${OUTPUT_DIR}/$(basename "${tools_path}")"
        rel_standalone_path="${OUTPUT_DIR}/$(basename "${standalone_path}")"

        docker build -t documentdb-test-gateway-packages:latest \
            -f "${OSS_ROOT}/packaging/gateway/test/Dockerfile_deb_gateway_test" \
            --build-arg BASE_IMAGE="${TEST_DOCKER_IMAGE}" \
            --build-arg POSTGRES_VERSION="${PG}" \
            --build-arg DEB_PACKAGE_REL_PATH="${rel_ext_path}" \
            --build-arg GATEWAY_PACKAGE_PATH="${rel_gw_path}" \
            --build-arg TOOLS_PACKAGE_REL_PATH="${rel_tools_path}" \
            --build-arg STANDALONE_PACKAGE_REL_PATH="${rel_standalone_path}" \
            "${OSS_ROOT}"
        docker_run_args=()
        add_docker_test_capabilities documentdb-test-gateway-packages:latest docker_run_args
        docker run --rm "${docker_run_args[@]}" documentdb-test-gateway-packages:latest
        [[ "${KEEP_IMAGES}" == "true" ]] \
            || docker rmi documentdb-test-gateway-packages:latest >/dev/null 2>&1 || true
    else
        ext_path="$(find_latest_artifact "${OS}-postgresql${PG}-documentdb-${DOCUMENTDB_VERSION}.*\.(x86_64|aarch64)\.rpm" || true)"
        gw_path="${gw_artifact}"
        tools_path="$(find_latest_artifact "documentdb-postgresql-tools-${DOCUMENTDB_VERSION}-.*\.noarch\.rpm" || true)"
        standalone_path="$(find_latest_artifact "documentdb-${PG}-${DOCUMENTDB_VERSION}-.*\.noarch\.rpm" || true)"
        for var in ext_path gw_path tools_path standalone_path; do
            [[ -n "${!var}" ]] || die "Missing artifact: ${var} not found in ${abs_output_dir}. Drop the matching --skip-* flag."
        done

        case "${OS}" in
            rhel8) DOCKER_IMAGE="rockylinux:8";
                   TEST_DOCKERFILE="${OSS_ROOT}/packaging/test_packages/rhel-8/Dockerfile-rhel8-gateway-test" ;;
            rhel9) DOCKER_IMAGE="rockylinux:9";
                   TEST_DOCKERFILE="${OSS_ROOT}/packaging/test_packages/rhel-9/Dockerfile-rhel9-gateway-test" ;;
        esac

        rel_ext_path="${OUTPUT_DIR}/$(basename "${ext_path}")"
        rel_gw_path="${OUTPUT_DIR}/$(basename "${gw_path}")"
        rel_tools_path="${OUTPUT_DIR}/$(basename "${tools_path}")"
        rel_standalone_path="${OUTPUT_DIR}/$(basename "${standalone_path}")"

        docker build -t documentdb-test-gateway-rpm-packages:latest \
            -f "${TEST_DOCKERFILE}" \
            --build-arg BASE_IMAGE="${DOCKER_IMAGE}" \
            --build-arg POSTGRES_VERSION="${PG}" \
            --build-arg RPM_PACKAGE_REL_PATH="${rel_ext_path}" \
            --build-arg GATEWAY_RPM_PACKAGE_REL_PATH="${rel_gw_path}" \
            --build-arg TOOLS_RPM_PACKAGE_REL_PATH="${rel_tools_path}" \
            --build-arg STANDALONE_RPM_PACKAGE_REL_PATH="${rel_standalone_path}" \
            "${OSS_ROOT}"
        docker_run_args=()
        add_docker_test_capabilities documentdb-test-gateway-rpm-packages:latest docker_run_args
        docker run --rm "${docker_run_args[@]}" --env POSTGRES_VERSION="${PG}" \
            documentdb-test-gateway-rpm-packages:latest
        [[ "${KEEP_IMAGES}" == "true" ]] \
            || docker rmi documentdb-test-gateway-rpm-packages:latest >/dev/null 2>&1 || true
    fi
fi

# ── Summary ─────────────────────────────────────────────────────────

log ""
log "Done. Artifacts under ${abs_output_dir}:"
# shellcheck disable=SC2010  # display-only; filenames are always alphanumeric
ls -1 "${abs_output_dir}" 2>/dev/null \
    | grep -E "(${OS}.*${DOCUMENTDB_VERSION}|documentdb-${PG}-${DOCUMENTDB_VERSION}|documentdb-postgresql-tools-${DOCUMENTDB_VERSION}|documentdb-${DOCUMENTDB_VERSION}|documentdb-gateway-${DOCUMENTDB_VERSION})" \
    | sed 's/^/    /' \
    || true

if [[ "${BUILD_ONLY}" == "true" ]]; then
    log ""
    log "Tip: to run the E2E test against these artifacts later, drop"
    log "     --build-only from this command. To inspect interactively:"
    log "         docker run --rm --cap-add=SYS_PTRACE -it --entrypoint /bin/bash \\"
    log "             documentdb-test-gateway-packages:latest"
fi
