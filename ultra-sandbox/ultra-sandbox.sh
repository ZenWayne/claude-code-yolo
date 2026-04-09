#!/bin/bash

# Ultra Sandbox - Generic containerized development environment
# Usage: ultra-sandbox.sh [command]
# If no command provided, starts an interactive bash shell

# Helper function to replace 127.0.0.1:10809 with host.docker.internal:10809
replace_proxy() {
    local proxy="$1"
    echo "${proxy//127.0.0.1:10809/host.docker.internal:10809}"
}

# Get current directory
WORK_DIR=$(pwd)

# Build volume mount arguments
VOLUME_ARGS=(-v "$WORK_DIR:$WORK_DIR")

echo "Current directory mounted to: $WORK_DIR"

# .ultra_sandbox dir: lives next to this script, holds sandbox binary + shims + daemon socket
ULTRA_SANDBOX_DIR="$(dirname "$(realpath "$0")")/.ultra_sandbox"
mkdir -p "$ULTRA_SANDBOX_DIR"

# Command provided - execute it
podman run -it --rm \
    --userns=keep-id \
    --network=host \
    "${VOLUME_ARGS[@]}" \
    -v "$HOME/.ssh":"/home/$USER/.ssh:ro" \
    -v "$ULTRA_SANDBOX_DIR":"/ultra_sandbox" \
    -e LANG="$LANG" \
    -e LC_ALL="$LC_ALL" \
    -e http_proxy="$(replace_proxy "$http_proxy")" \
    -e https_proxy="$(replace_proxy "$https_proxy")" \
    -e HTTP_PROXY="$(replace_proxy "$HTTP_PROXY")" \
    -e HTTPS_PROXY="$(replace_proxy "$HTTPS_PROXY")" \
    -e PATH="/ultra_sandbox:$HOME/.local/bin/:$PATH" \
    -e SANDBOX_SOCKET="/ultra_sandbox/daemon.sock" \
    -e NO_PROXY="$NO_PROXY" \
    -e no_proxy="$no_proxy" \
    -e TERM=xterm-256color \
    -e HOME="/home/$USER" \
    -w "$WORK_DIR" \
    localhost/claude_code_base:latest \
    "$@"
