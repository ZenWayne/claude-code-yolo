# Ultra-sandbox installer for Windows (PowerShell).
#
# 1. Downloads sandbox.exe from the latest GitHub release.
# 2. Builds the claude_code_base podman image.
# 3. Installs claude-yolo-automate onto $env:Path.
#
# Run from the repo root:
#   .\install.ps1
#
# Env overrides (set before running):
#   $env:INSTALL_DIR      Install destination (default: $env:USERPROFILE\.local\bin)
#   $env:REPO             GitHub repo (default: ZenWayne/ultra-sandbox)
#   $env:RELEASE_TAG      Release tag (default: latest)
#   $env:IMAGE_TAG        Podman image tag (default: claude_code_base)
#   $env:SKIP_SANDBOX     =1 to skip binary download
#   $env:SKIP_IMAGE       =1 to skip image build
#   $env:SKIP_LAUNCHER    =1 to skip launcher install
#
# Note: claude-yolo-automate is a bash script. On native Windows, run it
# from Git Bash, MSYS2, or WSL2. For a pure-bash experience, prefer
# install.sh inside WSL2.

$ErrorActionPreference = 'Stop'

$Repo       = if ($env:REPO)        { $env:REPO }        else { 'ZenWayne/ultra-sandbox' }
$ReleaseTag = if ($env:RELEASE_TAG) { $env:RELEASE_TAG } else { 'latest' }
$InstallDir = if ($env:INSTALL_DIR) { $env:INSTALL_DIR } else { Join-Path $env:USERPROFILE '.local\bin' }
$ImageTag   = if ($env:IMAGE_TAG)   { $env:IMAGE_TAG }   else { 'claude_code_base' }

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Log($msg)  { Write-Host "==> $msg" -ForegroundColor Blue }
function Warn($msg) { Write-Host "[warn] $msg" -ForegroundColor Yellow }
function Die($msg)  { Write-Host "[err] $msg" -ForegroundColor Red; exit 1 }

function Get-Asset {
    switch ($env:PROCESSOR_ARCHITECTURE) {
        'AMD64'  { return 'sandbox-windows-x86_64.exe' }
        'x86_64' { return 'sandbox-windows-x86_64.exe' }
        default  { Die "unsupported Windows arch: $env:PROCESSOR_ARCHITECTURE (build from source: ultra-sandbox/sandbox-rs)" }
    }
}

function Get-ReleaseUrl($asset) {
    if ($ReleaseTag -eq 'latest') {
        return "https://github.com/$Repo/releases/latest/download/$asset"
    }
    return "https://github.com/$Repo/releases/download/$ReleaseTag/$asset"
}

function Ensure-Dir($path) {
    if (-not (Test-Path $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
}

function Check-Path {
    $paths = ($env:Path -split ';') | Where-Object { $_ }
    if ($paths -contains $InstallDir) { return }
    Warn "$InstallDir is not on `$env:Path — add it to your user PATH:"
    Warn "  [Environment]::SetEnvironmentVariable('Path', `"`$env:Path;$InstallDir`", 'User')"
}

function Install-Sandbox {
    $asset = Get-Asset
    $url   = Get-ReleaseUrl $asset
    $dest  = Join-Path $InstallDir 'sandbox.exe'
    $tmp   = "$dest.new.$PID"

    Log "Downloading $asset from $url"
    try {
        Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing
    } catch {
        if (Test-Path $tmp) { Remove-Item -Force $tmp }
        Die "download failed: $($_.Exception.Message)"
    }

    # Atomic replace — works even if the old sandbox.exe is currently running.
    Move-Item -Force $tmp $dest
    Log "Installed sandbox -> $dest"
}

function Build-Image {
    $dockerfileDir = Join-Path $ScriptDir 'ultra-sandbox'
    $dockerfile    = Join-Path $dockerfileDir 'claude_code_base.Dockerfile'
    if (-not (Test-Path $dockerfile)) {
        Die "Dockerfile not found at $dockerfile"
    }

    $engine = $null
    if (Get-Command podman -ErrorAction SilentlyContinue) {
        $engine = 'podman'
    } elseif (Get-Command docker -ErrorAction SilentlyContinue) {
        $engine = 'docker'
        Warn "podman not found, falling back to docker (launcher script still expects podman at runtime)"
    } else {
        Die "need podman (or docker) to build the image. On Windows: install Podman Desktop, then 'podman machine init && podman machine start'."
    }

    $hostUser = $env:USERNAME
    if ($hostUser -eq 'root' -or $hostUser -eq 'Administrator') {
        Die "HOST_USER_NAME must not be 'root'/'Administrator' — run installer as a regular user"
    }

    # Windows has no unix UID/GID; the container runs inside podman-machine,
    # whose user is typically uid/gid 1000. Hardcode that as the default.
    Log "Building image $ImageTag with $engine"
    Push-Location $dockerfileDir
    try {
        $buildArgs = @(
            'build', '-f', 'claude_code_base.Dockerfile',
            '--build-arg', 'HOST_USER_UID=1000',
            '--build-arg', 'HOST_USER_GID=1000',
            '--build-arg', "HOST_USER_NAME=$hostUser",
            '--build-arg', "HTTP_PROXY=$($env:HTTP_PROXY)",
            '--build-arg', "HTTPS_PROXY=$($env:HTTPS_PROXY)",
            '-t', $ImageTag,
            '.'
        )
        & $engine @buildArgs
        if ($LASTEXITCODE -ne 0) { Die "image build failed (exit $LASTEXITCODE)" }
    } finally {
        Pop-Location
    }
    Log "Image built: $ImageTag"
}

function Install-Launcher {
    $src  = Join-Path $ScriptDir 'claude-yolo-automate'
    $dest = Join-Path $InstallDir 'claude-yolo-automate'
    if (-not (Test-Path $src)) { Die "launcher not found at $src" }

    Log "Installing launcher -> $dest"
    Copy-Item -Force $src $dest
    Warn "claude-yolo-automate is a bash script — on native Windows, run it from Git Bash, MSYS2, or WSL2."
}

function Main {
    Ensure-Dir $InstallDir

    if ($env:SKIP_SANDBOX -ne '1') { Install-Sandbox } else { Log "Skipping sandbox download (SKIP_SANDBOX=1)" }
    if ($env:SKIP_IMAGE   -ne '1') { Build-Image     } else { Log "Skipping image build (SKIP_IMAGE=1)"     }
    if ($env:SKIP_LAUNCHER -ne '1') { Install-Launcher } else { Log "Skipping launcher install (SKIP_LAUNCHER=1)" }

    Check-Path

    Log "Done."
    Write-Host ""
    Write-Host "Next steps (from Git Bash / MSYS2 / WSL2):"
    Write-Host "  cd /path/to/your/project"
    Write-Host '  SANDBOX_MAP_PROCESSES="python" claude-yolo-automate'
    Write-Host ""
    Write-Host "Override mapped commands via SANDBOX_MAP_PROCESSES, e.g.:"
    Write-Host '  SANDBOX_MAP_PROCESSES="python npx" claude-yolo-automate'
}

Main
