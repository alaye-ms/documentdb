# DocumentDB Packaging Dev Harness

This directory contains a single **`Dockerfile`** plus thin launchers
that give every contributor — regardless of host OS — a bit-identical
shell environment for running the gateway packaging E2E suite
described in `oss/packaging/gateway/packaging-design.md`.

## Why this exists

`oss/packaging/test_packaging_locally.sh` orchestrates the full build +
test flow already (extension → gateway → extras → test image → E2E
inside a clean container). It works great on Linux, but the host
shell environment it expects differs subtly between platforms:

| Platform | Bash | rpmbuild | python3 | Notes |
|----------|------|----------|---------|-------|
| Linux    | ✅   | apt/dnf  | ✅      | works out of the box |
| macOS    | ✅   | brew     | ✅      | need to remember `brew install rpm` |
| Windows + WSL | via wsl | apt | ✅      | works, but version of WSL distro varies |
| Windows native | ✗ | n/a   | ✗       | doesn't work — there's no bash |

The dev-harness image bundles the bash + python + rpm + docker-cli
surface that the orchestrator needs, and the launcher scripts handle
the Docker socket bind + path mapping so every host converges on the
same in-container experience.

## What you need on the host

Just **Docker** (Docker Engine on Linux, Docker Desktop on
macOS/Windows). No bash, no rpm, no Rust toolchain — those all live
inside containers the orchestrator spawns.

## Quick start

### Linux / macOS / WSL2

```bash
# From the repo root
./oss/packaging/dev-harness/test_in_docker.sh --os ubuntu24.04 --pg 18
```

That's it. The launcher will:

1. Build the dev-harness image on first invocation (cached after).
2. Run it with the host Docker socket bind-mounted in.
3. Run `test_packaging_locally.sh` inside, forwarding all args.
4. All packages drop into `oss/packaging/` on the host.

### Windows (PowerShell)

```powershell
# From the repo root
.\oss\packaging\dev-harness\test_in_docker.ps1 -Os ubuntu24.04 -Pg 18
```

The PowerShell launcher delegates to WSL2 (which Docker Desktop ships
with anyway) so the same POSIX launcher runs. If you don't have a WSL
distro installed:

```powershell
wsl --install -d Ubuntu-22.04
```

## How it works

```
┌─────────────────────────────────────────────────────────────────┐
│ Host (Linux / macOS / WSL2 / Windows + WSL2)                    │
│                                                                 │
│  ┌─ test_in_docker.sh ──────────────────────────────────────┐   │
│  │  1. docker build oss/packaging/dev-harness  (cached)     │   │
│  │  2. docker run --rm                                      │   │
│  │       -v /var/run/docker.sock:/var/run/docker.sock       │   │
│  │       -v $REPO:$REPO       <-- same-path bind mount      │   │
│  │       --user $UID:$GID                                   │   │
│  │       documentdb-dev-harness:latest                      │   │
│  │       bash test_packaging_locally.sh "$@"                │   │
│  └──────────────────────────────────────────────────────────┘   │
│                              │                                  │
│                              ▼                                  │
│  ┌─ harness container ─────────────────────────────────────┐    │
│  │  bash + python3 + rpm + docker-cli (no daemon)          │    │
│  │                                                         │    │
│  │  $ test_packaging_locally.sh --os ubuntu24.04 --pg 18   │    │
│  │      │                                                  │    │
│  │      └─ docker build/run …  ── talks via /var/run/      │    │
│  │                                  docker.sock to ──────┐ │    │
│  └───────────────────────────────────────────────────────│─┘    │
│                                                          │      │
│  ┌─ host docker daemon (siblings, not nested) ───────────▼─┐    │
│  │  • builds extension image, runs it → drops .deb into    │    │
│  │    $REPO/oss/packaging  (resolvable on host, because    │    │
│  │    $REPO inside == $REPO outside — same-path mount)     │    │
│  │  • builds gateway image, runs it → ditto                │    │
│  │  • builds test image with all 4 DEBs baked in           │    │
│  │  • runs test-gateway-install-entrypoint.sh in it        │    │
│  └─────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

The key trick is the **same-path bind mount**: the repo is mounted at
the same absolute path inside the harness as on the host. So when the
orchestrator (running inside the harness) tells the daemon "please
bind-mount `/home/foo/repo/oss/packaging` into your new container",
the daemon can resolve that path on its filesystem because the path
really exists there.

We use sibling containers (not Docker-in-Docker) by sharing the host
docker socket. No `--privileged`, no second daemon, no kernel
module surprises.

## Launcher flags

The launchers forward unrecognized flags to
`test_packaging_locally.sh`. They also accept a few flags of their
own:

| Flag                | Effect |
|---------------------|--------|
| `--rebuild-harness` | Force `docker build --no-cache` on the harness image. Use after editing `Dockerfile`. |
| `--shell`           | Drop into an interactive bash inside the harness instead of running the orchestrator. Useful for poking around. |
| `--harness-only`    | Print the `docker run` command that *would* be used and exit. No build, no run. |

Forwarded flags (most useful for fast iteration):

| Flag                       | Effect |
|----------------------------|--------|
| `--skip-extension-build`   | Reuse the most recent extension DEB/RPM under `oss/packaging/`. Skips the ~5–10 min Docker build. |
| `--skip-gateway-build`     | Reuse the most recent gateway DEB/RPM. |
| `--skip-extras-build`      | Reuse the most recent tools + standalone packages. |
| `--build-only`             | Build all four packages but don't run the test image. |
| `--keep-images`            | Don't `docker rmi` the test image at the end. Useful for `docker run -it … bash` inspection. |

## Examples

```bash
# Paved-road PR pre-flight
./oss/packaging/dev-harness/test_in_docker.sh --os ubuntu24.04 --pg 18

# RHEL 9 matrix (rpmbuild is in the harness — no host install needed)
./oss/packaging/dev-harness/test_in_docker.sh --os rhel9 --pg 18

# Iterate on a wizard shell-script change (skips the slow C/Rust rebuild)
./oss/packaging/dev-harness/test_in_docker.sh --os ubuntu24.04 --pg 18 \
    --skip-extension-build --skip-gateway-build

# Build artifacts only, then inspect them on the host
./oss/packaging/dev-harness/test_in_docker.sh --os ubuntu24.04 --pg 18 --build-only
ls oss/packaging/

# Poke around interactively
./oss/packaging/dev-harness/test_in_docker.sh --shell

# Force-rebuild the harness image (after editing Dockerfile)
./oss/packaging/dev-harness/test_in_docker.sh --rebuild-harness --build-only --pg 18
```

## What the harness does NOT do

* **Not Docker-in-Docker** — uses the host daemon via socket. No
  `--privileged`, no second daemon.
* **Not a build cache** — Rust/dpkg caches live in transient
  containers. If you want to persist them across runs, add another
  `-v` for `~/.cargo` etc. in your local fork of the launcher.
* **Not a systemd host** — the test entrypoint statically verifies
  unit files with `systemd-analyze verify` (which doesn't need PID 1),
  but a real `systemctl enable --now documentdb-local.target` lifecycle
  test still requires a VM. Use a real Ubuntu 24.04 / RHEL 9 VM for
  that.
* **Not for CI** — CI runs the same scripts directly. This harness is
  for the developer inner loop.

## Troubleshooting

### "docker daemon is not reachable"
On Linux, ensure `docker` is running and you're in the `docker`
group (or use `sudo`). On macOS/Windows, start Docker Desktop.

### "permission denied on /var/run/docker.sock" inside the harness
The launcher passes `--group-add` with the GID of the host socket.
If your host uses a non-standard GID, edit the launcher or run with
`--user 0:0` (root inside harness).

### "no space left on device" during repeated rebuilds
The harness image is small (~250 MB), but the inner build images
(Rust + PG dev headers) are large (~3 GB each). Periodically clean:
```bash
docker image prune -a
docker builder prune -a
```

### Nested bind mount fails with "invalid mount config"
This means the same-path mount assumption broke. Verify with:
```bash
./oss/packaging/dev-harness/test_in_docker.sh --shell
$ ls /home/foo/your/repo/oss/packaging  # should show contents
$ docker run --rm -v /home/foo/your/repo:/x alpine ls /x/oss/packaging
```
If the second command fails, your host daemon can't see the host
path; check Docker Desktop's "File sharing" config (macOS / Windows).

### Windows: "wsl.exe not found"
Install WSL: `wsl --install -d Ubuntu-22.04` and re-launch.
