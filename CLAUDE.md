# claude-code-yolo

Containerized Claude Code environments using Podman with sandbox command proxying.

## sandbox setup

Build and install the sandbox binary to `~/.local/bin/sandbox` if missing or outdated:

```bash
cd ultra-sandbox/sandbox-rs && cargo build --release && install -m 755 target/release/sandbox ~/.local/bin/sandbox
```

Start the daemon on the host before launching any container:

```bash
sandbox daemon &
```

Map host commands into the container (run from the directory containing `.ultra_sandbox/`):

```bash
cd ultra-sandbox
sandbox map podman
sandbox map adb
sandbox map flutter
```

Then launch the container via the appropriate script:

```bash
bash flutter/sandbox-flutter.sh        # Flutter projects
bash python/sandbox-python.sh          # Python projects
bash ultra-sandbox/ultra-sandbox.sh    # Generic environment
```
