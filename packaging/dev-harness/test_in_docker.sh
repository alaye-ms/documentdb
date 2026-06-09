#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# test_in_docker.sh — cross-platform entry point for the gateway
# packaging E2E. Wraps test_packaging_locally.sh in a reproducible
# dev-harness container so the only host requirement is `docker`.
#
# Why this exists
#   test_packaging_locally.sh works great on Linux when the host
#   already has `bash`, `python3`, and `rpm` available — but exercising
#   the same flow on macOS, WSL, and Windows + Docker Desktop today
#   means each developer has to maintain a slightly different host
#   environment (rpm on macOS via Homebrew, WSL distros that differ
#   between machines, etc.). This wrapper removes that drift: the
#   dev-harness image (oss/packaging/dev-harness/Dockerfile) bundles
#   the bash + python3 + rpm + docker-cli surface, mounts the host's
#   Docker socket, and runs test_packaging_locally.sh inside.
#
# Usage
#   ./oss/packaging/dev-harness/test_in_docker.sh --os ubuntu24.04 --pg 18
#   ./oss/packaging/dev-harness/test_in_docker.sh --os rhel9       --pg 17
#   ./oss/packaging/dev-harness/test_in_docker.sh --skip-extension-build --pg 18
#
#   Any flag accepted by test_packaging_locally.sh is forwarded
#   verbatim. See `./oss/packaging/test_packaging_locally.sh --help`.
#
# Extra flags (consumed locally, not forwarded)
#   --rebuild-harness   Force a no-cache rebuild of the dev-harness
#                       image (use after editing the Dockerfile).
#   --shell             Drop into an interactive bash inside the
#                       harness instead of running the orchestrator.
#                       Useful for poking around `docker images`,
#                       inspecting cached artifacts, etc.
#   --harness-only      Print the docker run command that *would* be
#                       used and exit. No build, no run.
#
# Path-translation contract
#   Nested `docker run -v <abs>:/x` inside the harness only works if
#   <abs> is a path the *host daemon* can resolve. We mount the repo
#   at the SAME absolute path inside the harness as on the host so
#   $OSS_ROOT inside == $OSS_ROOT outside, and the nested bind mounts
#   resolve on the host. On Windows + Docker Desktop the path
#   translation is opaque; use the .ps1 launcher there.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Script lives at oss/packaging/dev-harness/, so ../.. → oss/.
OSS_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REPO_ROOT="$(cd "${OSS_ROOT}/.." && pwd)"

HARNESS_IMAGE="documentdb-dev-harness:latest"
HARNESS_DOCKERFILE="${OSS_ROOT}/packaging/dev-harness/Dockerfile"

log()  { printf '\033[1;36m[harness]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[harness WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[harness ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

# Parse out the few flags we consume locally; everything else
# passes through to the inner orchestrator.
REBUILD_HARNESS=false
SHELL_MODE=false
HARNESS_ONLY=false
FORWARD_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --rebuild-harness) REBUILD_HARNESS=true; shift ;;
        --shell)           SHELL_MODE=true; shift ;;
        --harness-only)    HARNESS_ONLY=true; shift ;;
        *)                 FORWARD_ARGS+=("$1"); shift ;;
    esac
done

# ─── Pre-flight on the host ──────────────────────────────────────────

command -v docker >/dev/null 2>&1 \
    || die "docker not found on PATH. Install Docker Engine or Docker Desktop."
docker info >/dev/null 2>&1 \
    || die "docker daemon is not reachable. Start Docker Desktop or 'sudo systemctl start docker'."

# Resolve the host docker socket. Docker Desktop on macOS exposes it
# at the standard /var/run/docker.sock symlink; Linux is the same. On
# rootless setups (uncommon for this workflow) the user might have
# DOCKER_HOST set to a unix path — honor it.
HOST_DOCKER_SOCKET="/var/run/docker.sock"
if [[ "${DOCKER_HOST:-}" =~ ^unix:// ]]; then
    HOST_DOCKER_SOCKET="${DOCKER_HOST#unix://}"
fi
[[ -S "${HOST_DOCKER_SOCKET}" ]] \
    || die "Host docker socket ${HOST_DOCKER_SOCKET} is not a socket. Are you on a rootless setup? Try setting DOCKER_HOST."

# Map the host UID/GID into the harness so the artifacts dropped into
# the bind-mounted repo are owned by the invoking user, not by root.
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

# The GID of the host's docker socket — we add the harness user to a
# group with that GID so it can talk to the daemon without sudo.
DOCKER_GID="$(stat -c '%g' "${HOST_DOCKER_SOCKET}" 2>/dev/null || stat -f '%g' "${HOST_DOCKER_SOCKET}")"

# ─── Build the harness image (cached) ────────────────────────────────

build_args=(
    --build-arg "HARNESS_UID=${HOST_UID}"
    --build-arg "HARNESS_GID=${HOST_GID}"
)

needs_build=false
if [[ "${REBUILD_HARNESS}" == "true" ]]; then
    needs_build=true
    build_args+=(--no-cache)
elif ! docker image inspect "${HARNESS_IMAGE}" >/dev/null 2>&1; then
    needs_build=true
else
    # Cheap freshness check: rebuild if the Dockerfile is newer than
    # the image. Avoids serving a stale layer when someone edited the
    # harness deps.
    img_created="$(docker image inspect -f '{{.Created}}' "${HARNESS_IMAGE}" 2>/dev/null || echo 1970-01-01)"
    img_epoch="$(date -d "${img_created}" +%s 2>/dev/null || echo 0)"
    df_epoch="$(stat -c '%Y' "${HARNESS_DOCKERFILE}" 2>/dev/null \
                || stat -f '%m' "${HARNESS_DOCKERFILE}")"
    if (( df_epoch > img_epoch )); then
        log "Dockerfile changed since last build — rebuilding ${HARNESS_IMAGE}."
        needs_build=true
    fi
fi

if [[ "${needs_build}" == "true" ]]; then
    log "Building dev-harness image ${HARNESS_IMAGE} (uid=${HOST_UID} gid=${HOST_GID})"
    docker build "${build_args[@]}" \
        -t "${HARNESS_IMAGE}" \
        -f "${HARNESS_DOCKERFILE}" \
        "${OSS_ROOT}/packaging/dev-harness"
fi

# ─── Compose `docker run` ────────────────────────────────────────────

docker_run=(
    docker run --rm
    --user "${HOST_UID}:${HOST_GID}"
    --group-add "${DOCKER_GID}"
    --workdir "${OSS_ROOT}"
    -v "${HOST_DOCKER_SOCKET}:/var/run/docker.sock"
    # Same-path mount: $REPO_ROOT inside == $REPO_ROOT outside. This
    # is what makes nested bind mounts work — when the orchestrator
    # later does `docker run -v ${OSS_ROOT}/packaging:/output`, the
    # path resolves on the host daemon's filesystem because the host
    # actually has that directory at that path.
    -v "${REPO_ROOT}:${REPO_ROOT}"
    # Some inner image-build steps invoke `git rev-parse` for metadata;
    # mount git config if the user has one.
    -e "HOME=${HARNESS_HOME:-/home/harness}"
    # Tell the orchestrator how the harness sees the repo, in case it
    # ever needs to disambiguate (it currently uses BASH_SOURCE which
    # is correct under the same-path mount).
    -e "HARNESS_REPO_ROOT=${REPO_ROOT}"
)

if [[ -t 0 ]]; then
    docker_run+=(-i -t)
elif [[ "${SHELL_MODE}" == "true" ]]; then
    docker_run+=(-i -t)
fi

docker_run+=("${HARNESS_IMAGE}")

if [[ "${SHELL_MODE}" == "true" ]]; then
    docker_run+=("bash")
else
    docker_run+=(
        "bash" "${OSS_ROOT}/packaging/test_packaging_locally.sh" "${FORWARD_ARGS[@]}"
    )
fi

if [[ "${HARNESS_ONLY}" == "true" ]]; then
    log "Would run:"
    printf '    %q ' "${docker_run[@]}"
    printf '\n'
    exit 0
fi

log "Launching harness:"
printf '    %q ' "${docker_run[@]}"
printf '\n'

exec "${docker_run[@]}"
