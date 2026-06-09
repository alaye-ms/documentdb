# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# test_in_docker.ps1 — Windows entry point that delegates to the
# POSIX launcher (oss/packaging/dev-harness/test_in_docker.sh) running
# inside WSL2.
#
# Why delegate to WSL instead of running docker natively on Windows?
#   The packaging orchestrator does NESTED `docker run -v <path>:/x`
#   calls from inside the dev-harness container. For those to work,
#   the path must resolve on the host docker daemon's view of the
#   filesystem. The POSIX launcher achieves this with a "same-path
#   bind mount": $REPO_ROOT inside the harness equals $REPO_ROOT on
#   the host. Windows-style paths (C:\...) can't be bind-mounted at
#   the same path inside a Linux container, which would break the
#   nested bind mounts on Docker Desktop's daemon.
#
#   WSL2 sidesteps the whole problem: paths like /mnt/c/Users/foo/repo
#   resolve cleanly on both sides, and Docker Desktop is already
#   integrated with WSL2 by default (it ships its own WSL distro). So
#   we just hand off to the bash launcher inside a WSL distro the user
#   already has.
#
# Usage
#   .\oss\packaging\dev-harness\test_in_docker.ps1 -Os ubuntu24.04 -Pg 18
#   .\oss\packaging\dev-harness\test_in_docker.ps1 -Shell
#   .\oss\packaging\dev-harness\test_in_docker.ps1 -Pg 17 -ForwardArgs "--keep-images"
#
# Requirements
#   * Docker Desktop 4.x+ with WSL 2 backend (default)
#   * Any WSL distro registered (`wsl -l -q`). If none, install one:
#       wsl --install -d Ubuntu-22.04
#   * The repo must be checked out somewhere accessible from WSL —
#     either on a Windows drive (auto-mounted at /mnt/c/...) or
#     directly inside a WSL distro.

[CmdletBinding()]
param(
    [string]$Os = "ubuntu24.04",
    [string]$Pg = "18",
    [string]$Version = "",
    [string]$Distro = "",
    [switch]$SkipExtensionBuild,
    [switch]$SkipGatewayBuild,
    [switch]$SkipExtrasBuild,
    [switch]$BuildOnly,
    [switch]$KeepImages,
    [switch]$RebuildHarness,
    [switch]$Shell,
    [switch]$HarnessOnly,
    [string[]]$ForwardArgs = @()
)

$ErrorActionPreference = "Stop"

function Write-Log  ($Msg) { Write-Host "[harness-ps] $Msg" -ForegroundColor Cyan }
function Write-Warn ($Msg) { Write-Host "[harness-ps WARN] $Msg" -ForegroundColor Yellow }
function Write-Die  ($Msg) { Write-Host "[harness-ps ERROR] $Msg" -ForegroundColor Red; exit 1 }

# ─── Pre-flight ──────────────────────────────────────────────────────

try { Get-Command wsl -ErrorAction Stop | Out-Null }
catch { Write-Die "wsl.exe not found. Install WSL: 'wsl --install -d Ubuntu-22.04', then re-run." }

$availableDistros = (& wsl -l -q) | ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and ($_ -notmatch '^docker-desktop') }
if (-not $availableDistros) {
    Write-Die "No usable WSL distros installed (Docker Desktop's docker-desktop distro is not suitable). Install one: 'wsl --install -d Ubuntu-22.04'."
}

if ($Distro) {
    if (-not ($availableDistros -contains $Distro)) {
        Write-Die "WSL distro '$Distro' is not installed. Available: $($availableDistros -join ', ')"
    }
    $UseDistro = $Distro
} else {
    $UseDistro = $availableDistros | Select-Object -First 1
    Write-Log "Using WSL distro: $UseDistro (override with -Distro)"
}

# ─── Translate Windows repo path to a WSL path ───────────────────────

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
# Script lives at oss/packaging/dev-harness/, so ../.. → oss/.
$OssRoot   = Resolve-Path (Join-Path $ScriptDir "../..") | Select-Object -ExpandProperty Path
$RepoRoot  = Resolve-Path (Join-Path $OssRoot "..")  | Select-Object -ExpandProperty Path

function Convert-WindowsToWslPath {
    param([string]$WindowsPath)
    $resolved = (Get-Item $WindowsPath).FullName
    if ($resolved -match '^([A-Za-z]):\\(.*)$') {
        $drive = $matches[1].ToLower()
        $rest  = $matches[2] -replace '\\', '/'
        return "/mnt/$drive/$rest"
    }
    Write-Die "Cannot convert path to WSL form: $WindowsPath"
}

$WslRepoRoot     = Convert-WindowsToWslPath $RepoRoot
$WslLauncherPath = "$WslRepoRoot/oss/packaging/dev-harness/test_in_docker.sh"

Write-Log "Repo root (Windows): $RepoRoot"
Write-Log "Repo root (WSL):     $WslRepoRoot"

# ─── Build the inner argv ────────────────────────────────────────────

$InnerArgs = @("--os", $Os, "--pg", $Pg)
if ($Version)            { $InnerArgs += @("--version", $Version) }
if ($SkipExtensionBuild) { $InnerArgs += "--skip-extension-build" }
if ($SkipGatewayBuild)   { $InnerArgs += "--skip-gateway-build" }
if ($SkipExtrasBuild)    { $InnerArgs += "--skip-extras-build" }
if ($BuildOnly)          { $InnerArgs += "--build-only" }
if ($KeepImages)         { $InnerArgs += "--keep-images" }
if ($RebuildHarness)     { $InnerArgs += "--rebuild-harness" }
if ($Shell)              { $InnerArgs += "--shell" }
if ($HarnessOnly)        { $InnerArgs += "--harness-only" }
if ($ForwardArgs.Count -gt 0) { $InnerArgs += $ForwardArgs }

# Quote each arg for safe inclusion in `bash -lc "..."`
$QuotedArgs = ($InnerArgs | ForEach-Object { "'" + ($_ -replace "'", "'\\''") + "'" }) -join ' '

$BashCommand = "exec bash '$WslLauncherPath' $QuotedArgs"

Write-Log "Delegating to WSL distro '$UseDistro':"
Write-Host "    wsl -d $UseDistro -- bash -lc `"$BashCommand`""

# Use --cd so the WSL shell starts in the repo root and any relative
# paths in the launcher resolve correctly.
& wsl -d $UseDistro --cd $WslRepoRoot -- bash -lc $BashCommand
exit $LASTEXITCODE
