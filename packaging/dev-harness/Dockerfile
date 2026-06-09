# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# Cross-platform "dev harness" image for the gateway packaging E2E.
#
# Purpose
#   Provides a *single, reproducible* shell environment so the
#   packaging-design.md E2E suite (test_packaging_locally.sh) runs
#   bit-identically on Linux, macOS, WSL, and Windows + Docker Desktop.
#
#   The orchestrator (oss/packaging/test_packaging_locally.sh) and every
#   tool it invokes (build_packages.sh, build_gateway_packages.sh,
#   build_extra_packages.sh) already do all their heavy lifting inside
#   transient `docker build` + `docker run` calls. The host therefore
#   only ever needs:
#       * docker (daemon)
#       * bash + python3 (orchestrator + tests)
#       * rpm/rpmbuild (only for the RPM extras builder)
#
#   This image bundles that minimal "bash + python + docker CLI + rpm"
#   surface and is meant to be run with the host's docker socket
#   bind-mounted in, so `docker build` / `docker run` from inside the
#   harness execute as *siblings* against the host's daemon (i.e. NOT
#   Docker-in-Docker, no --privileged needed).
#
# Path-translation contract
#   Nested `docker run -v <abs>:/x` calls only work when <abs> resolves
#   on the daemon's view of the filesystem. The launcher scripts use
#   the well-known "same-path bind mount" pattern: the repo is mounted
#   at the same absolute path inside the harness as it lives on the
#   host (e.g. /home/foo/repo -> /home/foo/repo). On Windows + Docker
#   Desktop the PowerShell launcher passes the Windows-style host path
#   in $HOST_REPO_ROOT so the orchestrator can hand it to the daemon
#   directly.
#
# What this image is NOT
#   * Not a build cache. cargo / dpkg artifact caches live inside the
#     transient containers; persist them with -v from the launcher if
#     you want.
#   * Not a Docker-in-Docker image. We use the host daemon by sharing
#     /var/run/docker.sock. Means no second daemon to start, no
#     --privileged, no kernel-module surprises.
#   * Not a systemd host. systemd-analyze verify checks unit-file
#     syntax statically — the real "systemctl enable --now" lifecycle
#     still needs a VM. The test entrypoint skips PID-1-only checks
#     cleanly when systemd isn't running.

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# Ubuntu's :slim variants strip /usr/share/doc which breaks dpkg-deb -b
# when our packages ship docs. Pre-empt that for everyone who derives.
RUN if [ -f /etc/dpkg/dpkg.cfg.d/excludes ]; then \
        sed -i '/path-exclude.*doc/d' /etc/dpkg/dpkg.cfg.d/excludes; \
    fi

# Core toolchain. Deliberately small set — everything else (Rust, PG
# build deps, etc.) is installed inside the transient build/test
# containers the orchestrator spawns.
#
#   bash, coreutils, findutils, grep, sed, gawk → shell hygiene
#   ca-certificates, curl, git, jq              → repo/network ops
#   python3                                      → orchestrator + test_gateway.py
#   rpm                                          → rpmbuild for the RPM extras
#   xz-utils, zstd, tar, gzip                   → unpacking *.deb / *.rpm during checks
#   dpkg-dev                                     → dpkg-deb -I / -c during checks
#   sudo                                         → harness scripts that run docker through sudo
#   tini                                         → PID 1 reaper for clean Ctrl-C
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        coreutils \
        curl \
        dpkg-dev \
        findutils \
        gawk \
        git \
        grep \
        gzip \
        jq \
        python3 \
        python3-pip \
        python3-venv \
        rpm \
        sed \
        sudo \
        tar \
        tini \
        xz-utils \
        zstd \
 && rm -rf /var/lib/apt/lists/*

# Install the Docker CLI from Docker's official APT repo so we get a
# current version that matches what Docker Desktop / Engine ships. We
# only need the CLI (no daemon) since we bind-mount the host socket.
# Version is intentionally unpinned — the CLI is forward-compatible
# with older daemons within the same major, and pinning here would
# require frequent maintenance with no real benefit (the harness only
# uses `docker build` and `docker run`, both of which are stable
# across CLI versions).
RUN install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        -o /etc/apt/keyrings/docker.asc \
 && chmod a+r /etc/apt/keyrings/docker.asc \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" \
        > /etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
        docker-ce-cli \
        docker-buildx-plugin \
 && rm -rf /var/lib/apt/lists/*

# Pre-create a non-root user. The launcher scripts pass `--user`
# matching the host UID/GID so artifacts dropped into the bind-mounted
# repo are owned by the host user, not by root.
#
# Ubuntu 24.04 ships with a default `ubuntu` user at UID/GID 1000.
# If our requested HARNESS_UID collides with it, drop the default user
# first so groupadd/useradd can succeed.
ARG HARNESS_UID=1000
ARG HARNESS_GID=1000
RUN set -eu; \
    if getent passwd "${HARNESS_UID}" >/dev/null; then \
        existing_user="$(getent passwd "${HARNESS_UID}" | cut -d: -f1)"; \
        if [ "${existing_user}" != "harness" ]; then \
            userdel -r "${existing_user}" 2>/dev/null || true; \
        fi; \
    fi; \
    if getent group "${HARNESS_GID}" >/dev/null; then \
        existing_group="$(getent group "${HARNESS_GID}" | cut -d: -f1)"; \
        if [ "${existing_group}" != "harness" ]; then \
            groupdel "${existing_group}" 2>/dev/null || true; \
        fi; \
    fi; \
    if ! getent group harness >/dev/null; then \
        groupadd -g "${HARNESS_GID}" harness; \
    fi; \
    if ! getent passwd harness >/dev/null; then \
        useradd -m -u "${HARNESS_UID}" -g harness -s /bin/bash harness; \
    fi; \
    echo 'harness ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/90-harness; \
    chmod 0440 /etc/sudoers.d/90-harness

# The orchestrator expects to talk to a daemon via DOCKER_HOST or the
# default socket. The launcher bind-mounts the host socket; the user
# inside needs to belong to a group whose GID matches the socket
# owner. The launcher resolves this dynamically and reuses the docker
# group we create here as a placeholder.
RUN groupadd -g 998 docker || true \
 && usermod -aG docker harness

ENV HARNESS_HOME=/home/harness
WORKDIR ${HARNESS_HOME}

# Tini reaps any orphaned docker CLI subprocesses cleanly when the
# user Ctrl-Cs out of the launcher.
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["bash"]
