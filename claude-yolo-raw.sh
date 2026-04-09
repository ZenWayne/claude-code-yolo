#!/bin/bash
# Claude Code - raw, no sandbox command mapping

set -e

replace_proxy() {
    local proxy="$1"
    echo "${proxy//127.0.0.1:10809/host.docker.internal:10809}"
}

WORK_DIR=$(pwd)
VOLUME_NAME="claude-yolo-$(echo "$WORK_DIR" | sed 's/[^a-zA-Z0-9]/_/g' | tr '[:upper:]' '[:lower:]')"
VOLUME_ARGS=(-v "$WORK_DIR:$WORK_DIR")

if [ -d ".venv" ]; then
    VOLUME_ARGS+=(-v "${VOLUME_NAME}_venv:$WORK_DIR/.venv")
fi

podman run -it --rm \
    --userns=keep-id \
    --network=host \
    "${VOLUME_ARGS[@]}" \
    -v "$HOME/.claude":"/home/$USER/.claude" \
    -v "$HOME/.claude.json":"/home/$USER/.claude.json" \
    -v "$HOME/.ssh":"/home/$USER/.ssh:ro" \
    -e ANTHROPIC_BASE_URL="$ANTHROPIC_BASE_URL" \
    -e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
    -e DISABLE_AUTOUPDATER=1 \
    -e LANG="$LANG" \
    -e LC_ALL="$LC_ALL" \
    -e http_proxy="$(replace_proxy "$http_proxy")" \
    -e https_proxy="$(replace_proxy "$https_proxy")" \
    -e HTTP_PROXY="$(replace_proxy "$HTTP_PROXY")" \
    -e HTTPS_PROXY="$(replace_proxy "$HTTPS_PROXY")" \
    -e NO_PROXY="$NO_PROXY" \
    -e no_proxy="$no_proxy" \
    -e TERM=xterm-256color \
    -e HOME="/home/$USER" \
    -e PATH="/home/$USER/.local/bin:/usr/local/bin:/usr/bin:/bin" \
    -w "$WORK_DIR" \
    --entrypoint /home/$USER/.local/bin/claude \
    localhost/claude_code_base:latest \
    --dangerously-skip-permissions "$@"
