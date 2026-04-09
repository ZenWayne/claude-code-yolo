# claude-code-yolo

Containerized Claude Code environments using Podman with sandbox command proxying.

## sandbox setup

Build the sandbox binary if `.ultra_sandbox/sandbox` is missing or outdated:

```bash
cd ultra-sandbox/sandbox && GOPATH=/tmp/build/gopath GOCACHE=/tmp/build/go-cache go build -o ../.ultra_sandbox/sandbox .
```

Start the daemon on the host before launching any container:

```bash
ultra-sandbox/.ultra_sandbox/sandbox daemon &
```

Map host commands into the container as needed:

```bash
ultra-sandbox/.ultra_sandbox/sandbox map podman
ultra-sandbox/.ultra_sandbox/sandbox map adb
ultra-sandbox/.ultra_sandbox/sandbox map flutter
```

Then launch the container via the appropriate script:

```bash
bash flutter/sandbox-flutter.sh        # Flutter projects
bash python/sandbox-python.sh          # Python projects
bash ultra-sandbox/ultra-sandbox.sh    # Generic environment
```
