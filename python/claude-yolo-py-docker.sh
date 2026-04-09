#!/bin/bash

# Helper function to replace 127.0.0.1:10809 with host.docker.internal:10809
replace_proxy() {
    local proxy="$1"
    echo "${proxy//127.0.0.1:10809/host.docker.internal:10809}"
}

# 获取当前目录的绝对路径
WORK_DIR=$(pwd)

# 根据当前目录创建卷名（替换特殊字符，确保合法）
VOLUME_NAME="claude-yolo-$(echo "$WORK_DIR" | sed 's/[^a-zA-Z0-9]/_/g' | tr '[:upper:]' '[:lower:]')"

# 构建 volume 挂载参数（保持相同目录结构）
VOLUME_ARGS=(-v "$WORK_DIR:$WORK_DIR")

# 如果当前目录有 .venv，额外挂载一个空卷覆盖它（容器自己建venv）
if [ -d ".venv" ]; then
    echo "检测到 .venv 目录，已排除（容器将使用独立的虚拟环境：${VOLUME_NAME}_venv）"
    VOLUME_ARGS+=(-v "${VOLUME_NAME}_venv:$WORK_DIR/.venv")
fi

#echo "当前目录挂载到：$WORK_DIR"

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
    -e UV_VENV_CLEAR=1 \
    -w "$WORK_DIR" \
    --entrypoint /home/$USER/.local/bin/claude \
    localhost/claude_code_py:latest \
    --dangerously-skip-permissions "$@"
