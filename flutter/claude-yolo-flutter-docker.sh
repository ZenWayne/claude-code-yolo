#!/bin/bash
# Flutter + Claude YOLO，通过 sandbox 将宿主机命令透传进容器
# 映射命令：podman, adb
#
# 前置条件：
#   1. 编译 sandbox 二进制：
#      cd ultra-sandbox/sandbox && go build -o ../.ultra_sandbox/sandbox .
#   2. 启动 ADB server（宿主机网络模式）：
#      adb kill-server && adb -a nodaemon server &

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ULTRA_SANDBOX_DIR="$(pwd)/.ultra_sandbox"
IMAGE="localhost/claude_code_base:latest"

replace_proxy() {
    local proxy="$1"
    echo "${proxy//127.0.0.1:10809/host.docker.internal:10809}"
}

# ─── 确保 sandbox 二进制存在 ────────────────────────────────
if [ ! -x "$ULTRA_SANDBOX_DIR/sandbox" ]; then
    echo "错误: sandbox 二进制不存在，请先编译："
    echo "  cd ultra-sandbox/sandbox && go build -o ../.ultra_sandbox/sandbox ."
    exit 1
fi

# ─── 确保 daemon 运行中 ──────────────────────────────────────
SANDBOX_SOCKET="$ULTRA_SANDBOX_DIR/daemon.sock"
if [ ! -S "$SANDBOX_SOCKET" ]; then
    echo "启动 sandbox daemon..."
    SANDBOX_SOCKET="$SANDBOX_SOCKET" "$ULTRA_SANDBOX_DIR/sandbox" daemon &
    sleep 0.3
fi

# ─── 映射宿主机命令 ──────────────────────────────────────────
SANDBOX_SOCKET="$SANDBOX_SOCKET" "$ULTRA_SANDBOX_DIR/sandbox" map flutter
SANDBOX_SOCKET="$SANDBOX_SOCKET" "$ULTRA_SANDBOX_DIR/sandbox" map adb
SANDBOX_SOCKET="$SANDBOX_SOCKET" "$ULTRA_SANDBOX_DIR/sandbox" map podman

echo "=== sandbox 已映射: podman, adb ==="

# ─── 自动构建镜像 ────────────────────────────────────────────
if ! podman image exists "$IMAGE" 2>/dev/null; then
    echo "=== 镜像 '$IMAGE' 不存在，正在构建... ==="
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

# ─── 启动容器 ────────────────────────────────────────────────
WORK_DIR=$(pwd)
WORK_DIR_ESCAPED="${WORK_DIR//\//_}"

podman run -it --rm \
    --userns=keep-id \
    --network=host \
    -v "$WORK_DIR:$WORK_DIR" \
    -v "$HOME/.claude":"/home/$USER/.claude" \
    -v "$HOME/.claude.json":"/home/$USER/.claude.json" \
    -v "$HOME/.ssh":"/home/$USER/.ssh:ro" \
    -v "$ULTRA_SANDBOX_DIR":"/ultra_sandbox" \
    -e ANTHROPIC_BASE_URL="$ANTHROPIC_BASE_URL" \
    -e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
    -e DISABLE_AUTOUPDATER=1 \
    -e SANDBOX_SOCKET="/ultra_sandbox/daemon.sock" \
    -e LANG="$LANG" \
    -e LC_ALL="$LC_ALL" \
    -e FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn" \
    -e PUB_HOSTED_URL="https://pub.flutter-io.cn" \
    -e HTTP_PROXY="$(replace_proxy "$HTTP_PROXY")" \
    -e HTTPS_PROXY="$(replace_proxy "$HTTPS_PROXY")" \
    -e NO_PROXY="$NO_PROXY" \
    -e TERM=xterm-256color \
    -e HOME="/home/$USER" \
    -w "$WORK_DIR" \
    "$IMAGE" \
    claude --dangerously-skip-permissions "$@"
