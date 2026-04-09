#!/bin/bash
# Flutter + Claude YOLO with sandbox command proxy
# Mapped commands: flutter, adb, podman

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ULTRA_SANDBOX_DIR="$SCRIPT_DIR/../ultra-sandbox/.ultra_sandbox"
IMAGE="localhost/claude_code_flutter:latest"

replace_proxy() {
    local proxy="$1"
    echo "${proxy//127.0.0.1:10809/host.docker.internal:10809}"
}

# --- Ensure sandbox binary exists -------------------------------------------
if [ ! -x "$ULTRA_SANDBOX_DIR/sandbox" ]; then
    echo "Error: sandbox binary not found. Build it first:"
    echo "  cd ultra-sandbox/sandbox && go build -o ../.ultra_sandbox/sandbox ."
    exit 1
fi

# --- Ensure daemon is running ------------------------------------------------
SANDBOX_SOCKET="$ULTRA_SANDBOX_DIR/daemon.sock"
if [ ! -S "$SANDBOX_SOCKET" ]; then
    echo "Starting sandbox daemon..."
    SANDBOX_SOCKET="$SANDBOX_SOCKET" "$ULTRA_SANDBOX_DIR/sandbox" daemon &
    sleep 0.3
fi

# --- Map host commands -------------------------------------------------------
SANDBOX_SOCKET="$SANDBOX_SOCKET" "$ULTRA_SANDBOX_DIR/sandbox" map flutter
SANDBOX_SOCKET="$SANDBOX_SOCKET" "$ULTRA_SANDBOX_DIR/sandbox" map adb
SANDBOX_SOCKET="$SANDBOX_SOCKET" "$ULTRA_SANDBOX_DIR/sandbox" map podman

echo "=== sandbox mapped: flutter, adb, podman ==="

# --- Auto-build image if missing ---------------------------------------------
if ! podman image exists "$IMAGE" 2>/dev/null; then
    echo "=== Image '$IMAGE' not found, building... ==="
    podman build \
        -f "$SCRIPT_DIR/claude_code_flutter.Dockerfile" \
        --build-arg HOST_USER_UID="$(id -u)" \
        --build-arg HOST_USER_GID="$(id -g)" \
        --build-arg HOST_USER_NAME="$USER" \
        --build-arg HTTP_PROXY="$(replace_proxy "$HTTP_PROXY")" \
        --build-arg HTTPS_PROXY="$(replace_proxy "$HTTPS_PROXY")" \
        -t "$IMAGE" \
        "$SCRIPT_DIR"
fi

# --- Launch container --------------------------------------------------------
WORK_DIR=$(pwd)
WORK_DIR_ESCAPED="${WORK_DIR//\//_}"

podman run -it --rm \
    --userns=keep-id \
    --network=host \
    -v "$WORK_DIR:$WORK_DIR" \
    -v "$HOME/.claude":"/home/$USER/.claude" \
    -v "$HOME/.claude.json":"/home/$USER/.claude.json" \
    -v "$HOME/.ssh":"/home/$USER/.ssh:ro" \
    -v "$HOME/.pub-cache":"/home/$USER/.pub-cache" \
    -v "$HOME/.gradle":"/home/$USER/.gradle" \
    -v "/tmp":"/tmp" \
    -v "flutter_build_${WORK_DIR_ESCAPED}:$WORK_DIR/build" \
    -v "flutter_dart_tool_${WORK_DIR_ESCAPED}:$WORK_DIR/.dart_tool" \
    -v "$ULTRA_SANDBOX_DIR":"/ultra_sandbox" \
    -e ANTHROPIC_BASE_URL="$ANTHROPIC_BASE_URL" \
    -e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
    -e DISABLE_AUTOUPDATER=1 \
    -e SANDBOX_SOCKET="/ultra_sandbox/daemon.sock" \
    -e LANG="$LANG" \
    -e LC_ALL="$LC_ALL" \
    -e FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn" \
    -e PUB_HOSTED_URL="https://pub.flutter-io.cn" \
    -e http_proxy="$(replace_proxy "$http_proxy")" \
    -e https_proxy="$(replace_proxy "$https_proxy")" \
    -e HTTP_PROXY="$(replace_proxy "$HTTP_PROXY")" \
    -e HTTPS_PROXY="$(replace_proxy "$HTTPS_PROXY")" \
    -e NO_PROXY="$NO_PROXY" \
    -e no_proxy="$no_proxy" \
    -e TERM=xterm-256color \
    -e HOME="/home/$USER" \
    -e PATH="/ultra_sandbox:/opt/flutter/bin:/opt/android-sdk/platform-tools:/opt/android-sdk/cmdline-tools/latest/bin:/usr/local/bin:/usr/bin:/bin" \
    -w "$WORK_DIR" \
    "$IMAGE" \
    claude --dangerously-skip-permissions "$@"
