# Sandbox subcommand-level block list

**Status:** design (approved 2026-04-28)
**Component:** `ultra-sandbox/sandbox-rs`

## Problem

The sandbox daemon's only authorization layer is a top-level command allow-list
(`.ultra_sandbox/command-map.json`). Once a host command is mapped — `podman`,
`adb`, `flutter` — every subcommand is reachable from inside the container.
That is too coarse: an agent that needs `podman ps` and `podman exec` should
not be able to issue `podman rm`, `podman kill`, `podman system prune`, or
`podman volume rm`.

We need subcommand-level control without giving up the simplicity of the
existing mapping mechanism.

## Goals

- Block specific subcommand paths for a mapped command (e.g. forbid
  `podman rm` while keeping the rest of `podman` usable).
- Optionally restrict a mapped command to an explicit allow-list of
  subcommands (e.g. `kubectl get`/`describe`/`logs` only).
- Backwards-compatible: existing setups with no policy file behave exactly as
  today.
- Enforced on the host side (daemon), since the client lives in an untrusted
  container.

## Threat model

The caller is **a cooperating LLM agent that does not know about the
policy**. The policy is a guardrail against the agent accidentally invoking
a destructive command it picked from training data or an upstream
recommendation, not a security boundary against an adversary deliberately
crafting argv to slip past the matcher.

A deliberate adversary inside the container can already do plenty of
damage with the commands that *are* allowed (e.g. write to mounted host
paths). Subcommand blocking does not pretend to be a sandbox in the
security-research sense; it is a misuse-prevention mechanism layered on
top of the existing reachability allow-list.

## Non-goals

- Flag-level pattern matching (`--force`, `-rf`). Flag bypasses are too easy
  (`-f` vs `--force` vs config file vs env var); a sandbox rule that *thinks*
  it blocks `--force` but misses one form is worse than no rule at all. We
  block at the verb level only.
- Allow-list semantics for top-level commands — that is what
  `command-map.json` already does.
- Hot-reload via inotify — the policy file is re-read on every request anyway.
- Atomic-write retrofit for `command-map.json`. Out of scope for this change.
- Per-user / per-container policy files. One policy per workspace, matching
  how `command-map.json` works today.

## Design decisions

| Decision | Choice |
| --- | --- |
| Per-command policy mode | Both deny-list and allow-list, simultaneously, per mapped command |
| Match granularity | Subcommand path — first N positional words, ignoring flags |
| Flag handling | Skip any token starting with `-`; if it has no `=`, also skip the next token (treated as the flag's value); `--` ends options |
| Combine semantics | Deny is checked first (deny-wins). If allow-list is non-empty, request must also match an allow rule. Empty policy → unrestricted (preserves current behavior) |
| Storage | New file `.ultra_sandbox/policy.json` (separate from `command-map.json`) |
| CLI surface | New `sandbox policy` subcommand with verbs `deny`, `allow`, `unset`, `list`, `clear` |
| Enforcement point | Daemon, in `handle_client`, immediately after the existing command-map lookup |
| Block exit code | 126 (POSIX "command found but not executable / permission denied") |
| Policy file lifecycle | Read fresh on each request; missing/malformed → empty policy |
| Concurrent writes | `save_policy()` writes `policy.json.tmp` then `rename()` (atomic on POSIX) |

## Architecture

```
container             host daemon (sandbox)
─────────             ───────────────────────────
podman shim ──exec──► handle_client()
                        │
                        ├─ load_command_map()      (existing)
                        ├─ map[req.cmd] -> exec    (existing — unmapped → block)
                        │
                        ├─ load_policy()           (NEW)
                        ├─ check_policy(           (NEW)
                        │     map_key=req.cmd,
                        │     args=req.args)
                        │     ├─ extract_path(args) → Vec<String>
                        │     ├─ for rule in deny: if matches_path(rule, path) → Err
                        │     └─ if !allow.is_empty():
                        │           if !allow.iter().any(...) → Err
                        │
                        ├─ on Err(msg):
                        │     write FRAME_STDERR "sandbox: '<cmd> <path>' <msg>\n"
                        │     write FRAME_EXIT 126
                        │     log "sandbox daemon: blocked <cmd> <argv> (...)"
                        │     return
                        │
                        └─ spawn (existing handle_pty / handle_pipe)
```

The map-key passed to `check_policy` is the **alias the client invoked** —
`req.cmd` *before* it is rewritten to the resolved exec path on
`main.rs:306`. This matters because the policy is keyed by the user-facing
name (`podman`), not the resolved binary path (`/usr/bin/podman`). Capture
`req.cmd` into a local `let map_key = req.cmd.clone();` before the rewrite.

## Data format

`.ultra_sandbox/policy.json`:

```json
{
  "podman": {
    "deny":  [["rm"], ["rmi"], ["kill"], ["system", "prune"], ["volume", "rm"]],
    "allow": []
  },
  "kubectl": {
    "deny":  [],
    "allow": [["get"], ["describe"], ["logs"]]
  }
}
```

Rust types:

```rust
#[derive(Default, Serialize, Deserialize)]
struct CommandPolicy {
    #[serde(default)]
    deny:  Vec<Vec<String>>,
    #[serde(default)]
    allow: Vec<Vec<String>>,
}

type PolicyMap = HashMap<String, CommandPolicy>;
```

Path:

```rust
fn policy_path() -> PathBuf {
    sandbox_dir().join("policy.json")
}
```

`#[serde(default)]` on each field means a partial entry like
`{ "deny": [["rm"]] }` parses cleanly — friendly for hand-edits.

Each token array represents an ordered subcommand path. Empty arrays are
not legal as rules and are silently dropped on load (defensive — empty path
would match everything).

## Matching algorithm

### Step 1 — extract subcommand path

```rust
fn extract_path(args: &[String]) -> Vec<String> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < args.len() {
        let a = &args[i];
        if a == "--" {
            i += 1;
            // remaining tokens are positional; collect them all
            while i < args.len() {
                out.push(args[i].clone());
                i += 1;
            }
            break;
        }
        if a.starts_with('-') {
            if a.contains('=') {
                i += 1;            // --flag=value: single token
            } else {
                i += 2;            // --flag [value]: skip flag and assumed value
            }
            continue;
        }
        out.push(a.clone());
        i += 1;
    }
    out
}
```

Examples:

| `args` | extracted path |
| --- | --- |
| `["rm", "myctr"]` | `["rm", "myctr"]` |
| `["--log-level=debug", "rm", "myctr"]` | `["rm", "myctr"]` |
| `["--log-level", "debug", "rm"]` | `["rm"]` |
| `["-f", "rm"]` | `[]` — `-f` is treated as a flag that consumes its next token, so `rm` is swallowed as the flag's value. **Known limitation; see note below.** |
| `["--", "rm"]` | `["rm"]` |
| `[]` | `[]` |

**Known false-negative:** for short bool flags that don't actually take a
value, the algorithm still skips the next token. This means `podman -f rm`
would extract `[]` and not match the `["rm"]` deny rule. This is acceptable:
- Real-world `-f` immediately after the binary name is unusual.
- For a sandbox, the safer drift direction is over-skipping (more rules
  match) rather than under-skipping. Unfortunately our drift is the unsafe
  direction here for *short bool flags before the subcommand*. Users who care
  can express `["rm"]` AND, if needed, also `["-f"]`-style rules — but we're
  not building flag rules, so the recommended mitigation is operator
  awareness: documented in the spec, no code change.
- A more accurate parse would require per-command flag schemas (rejected as
  too much config; see Non-goals).

### Step 2 — prefix match

```rust
fn matches_path(rule: &[String], path: &[String]) -> bool {
    rule.len() <= path.len()
        && rule.iter().zip(path.iter()).all(|(r, p)| r == p)
}

fn check_policy(
    policy: Option<&CommandPolicy>,
    path: &[String],
) -> Result<(), PolicyDenial> {
    let Some(p) = policy else { return Ok(()); };

    for rule in &p.deny {
        if matches_path(rule, path) {
            return Err(PolicyDenial::Deny(rule.clone()));
        }
    }
    if !p.allow.is_empty() {
        let ok = p.allow.iter().any(|rule| matches_path(rule, path));
        if !ok {
            return Err(PolicyDenial::AllowMiss);
        }
    }
    Ok(())
}

enum PolicyDenial {
    Deny(Vec<String>),  // matched deny rule
    AllowMiss,
}
```

### Edge cases

| Case | Behavior |
| --- | --- |
| Policy file missing | Treat as empty `PolicyMap` → no restrictions. |
| Policy file malformed JSON | Log warning to daemon stderr, treat as empty. |
| `policy.json` exists, command not listed | No restrictions (empty `Option<&CommandPolicy>`). |
| Command listed, both `deny` and `allow` empty | Equivalent to not being listed — unrestricted. |
| `path` is empty (e.g. `podman` with no args), allow non-empty | Blocked (no allow rule matches empty path). |
| `path` is empty, only deny rules exist | Allowed (deny rules are non-empty by construction so cannot match empty path). |
| Rule path longer than args | Cannot match (`matches_path` returns false). |
| Token equality is exact, not substring | `["rm"]` does not match `["rmi"]`. |

## CLI UX

New subcommand under `sandbox`:

```
sandbox policy deny  <cmd> <subcmd-path...>
sandbox policy allow <cmd> <subcmd-path...>
sandbox policy unset <cmd> <subcmd-path...>
sandbox policy list  [<cmd>]
sandbox policy clear <cmd>
```

Examples:

```bash
sandbox policy deny  podman rm
sandbox policy deny  podman system prune
sandbox policy deny  podman volume rm
sandbox policy allow kubectl get
sandbox policy allow kubectl describe

sandbox policy list  podman
# podman:
#   deny:  rm
#          system prune
#          volume rm
#   allow: (empty)

sandbox policy unset podman rm
sandbox policy clear podman
```

### Verb behavior

- `deny <cmd> <path...>` — append rule to `policy[cmd].deny`. Idempotent
  (already-present rule is a no-op, exit 0). Creates the entry for `<cmd>`
  if absent.
- `allow <cmd> <path...>` — same as `deny` but on `policy[cmd].allow`.
- `unset <cmd> <path...>` — remove the rule from whichever list it appears
  in. Errors with exit 1 if not found in either list (catches typos).
- `list` — pretty-print current policy. With no `<cmd>`, prints all entries.
  With `<cmd>`, prints just that one (or "no policy for <cmd>" if absent).
  This is for humans; `policy.json` is the machine form.
- `clear <cmd>` — remove the entire entry for `<cmd>`. Hard reset.

### Validation

- `<cmd>` is **not** required to be present in `command-map.json`. Policy
  may be set up before mapping, or kept stable across remaps. Unmapped
  policy is harmless because the daemon checks policy only after a
  successful map lookup.
- `<subcmd-path...>` must be at least one token for `deny`/`allow`/`unset`.
  Empty path is rejected with exit 1 and a usage message.

### Help text

Update `usage()` in `main.rs` to add:

```
sandbox policy deny|allow|unset <cmd> <subcmd-path...>
sandbox policy list [<cmd>]
sandbox policy clear <cmd>
```

## Error UX

When a request is blocked, the client sees:

```
$ podman rm myctr
sandbox: 'podman rm' denied by policy
$ echo $?
126
```

For an allow-list miss:

```
$ podman exec myctr bash
sandbox: 'podman exec' not in allow-list
```

The path printed is the matched-rule prefix for deny denials, and the
extracted-path-truncated-to-a-reasonable-length for allow-miss denials (so
the user can see what they tried).

Daemon stderr logs one line per denial:

```
sandbox daemon: blocked podman rm myctr (deny rule: rm)
sandbox daemon: blocked podman exec myctr bash (allow-list miss)
```

## Concurrency

`save_policy()` uses atomic rename:

```rust
fn save_policy(map: &PolicyMap) -> io::Result<()> {
    let path = policy_path();
    let tmp = path.with_extension("json.tmp");
    fs::write(&tmp, serde_json::to_vec_pretty(map)?)?;
    fs::rename(&tmp, &path)?;
    Ok(())
}
```

This protects concurrent `sandbox policy ...` invocations from clobbering
each other. `load_policy()` itself is read-only and tolerates a missing
file, so the daemon's per-request load is safe against an in-flight write.

## File / code layout

All changes are in a single file: `ultra-sandbox/sandbox-rs/src/main.rs`.

New top-level items (ordered as they would appear, near the existing
command-map section):

```rust
// Policy types
struct CommandPolicy { ... }
type PolicyMap = HashMap<String, CommandPolicy>;
enum PolicyDenial { Deny(Vec<String>), AllowMiss }

// Policy I/O
fn policy_path() -> PathBuf
fn load_policy() -> PolicyMap
fn save_policy(&PolicyMap) -> io::Result<()>

// Matching
fn extract_path(&[String]) -> Vec<String>
fn matches_path(&[String], &[String]) -> bool
fn check_policy(Option<&CommandPolicy>, &[String]) -> Result<(), PolicyDenial>

// CLI
fn run_policy(args: &[String])  // dispatch over deny/allow/unset/list/clear
```

Modifications:

- `handle_client` — after the command-map lookup succeeds, run
  `check_policy` against `load_policy().get(map_key)` and the args. On
  `Err`, send `FRAME_STDERR` + `FRAME_EXIT 126` and log to daemon stderr.
- `main()` — add `"policy"` arm to the match in the entry point.
- `usage()` — extend with the new lines.

No new crate dependencies.

## Testing

Unit tests added under `#[cfg(test)] mod tests` in `main.rs`:

- `extract_path` — eight cases:
  - empty argv
  - simple positional: `["rm", "myctr"]`
  - `--flag=value` skipped
  - `--flag value` skipped
  - `--` ends options
  - leading bool flag `-f` followed by `rm` → extracts `[]` (documents
    the false-negative case from the limitations section)
  - mixed flags and subcommand path: `["--log-level=debug", "system", "prune"]`
    → `["system", "prune"]`
  - flag-with-value-in-middle using `=` form: `["system", "--force=true", "prune"]`
    → `["system", "prune"]` (correct)
  - bool-flag-in-middle false skip: `["system", "--force", "prune"]`
    → `["system"]` (documents that `--force` swallows `prune` as its
    assumed value; this is the same limitation as the leading-`-f` case)
- `matches_path` — five cases:
  - rule prefix matches longer path
  - exact rule equals path
  - rule longer than path → no match
  - token equality is exact (no substring): `["rm"]` ≠ `["rmi"]`
  - empty rule against non-empty path (defensive — should not occur in
    practice since empty rules are dropped on load, but assert behavior is
    "matches everything" so we know to guard)
- `check_policy` — six cases:
  - `None` policy → Ok
  - empty deny + empty allow → Ok
  - matching deny → Err::Deny
  - non-empty allow, no match → Err::AllowMiss
  - non-empty allow, matching allow → Ok
  - both lists, deny matches → Err::Deny (deny wins)

Integration / smoke test (manual, documented for the implementer to run
on the host before declaring done):

```bash
# build & install
cd ultra-sandbox/sandbox-rs && cargo build --release \
  && install -m 755 target/release/sandbox ~/.local/bin/sandbox

# start daemon
sandbox daemon &

# in a workspace
sandbox map podman
sandbox policy deny podman rm

podman ps                              # expect: works
podman rm foo                          # expect: blocked, exit 126
podman --log-level=debug rm foo        # expect: blocked
sandbox policy unset podman rm
podman rm foo                          # expect: works again
sandbox policy clear podman
```

## Implementation phases

Suggested implementation ordering for the implementation-plan stage:

1. Add `CommandPolicy`, `PolicyMap`, `policy_path`, `load_policy`,
   `save_policy` (with atomic rename). Verify load/save round-trips with
   a unit test.
2. Add `extract_path`, `matches_path`, `check_policy`, `PolicyDenial`. Add
   unit tests.
3. Add `run_policy` for the CLI verbs (`deny`/`allow`/`unset`/`list`/`clear`).
   Wire into `main()` and `usage()`.
4. Wire enforcement into `handle_client` (capture `map_key` before rewrite,
   then call `check_policy` after the existing whitelist lookup).
5. Run the manual smoke test on a real host.

## Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| Bool flags adjacent to a subcommand can cause under-matching, because the algorithm assumes every non-`=` flag takes the next token as its value (`podman -f rm` extracts `[]`; `podman system --force prune` extracts `["system"]`) | Documented limitation. Threat model is preventing **accidental** destructive calls from a cooperating LLM agent that does not know about the policy, not preventing adversarial bypasses — a deliberate caller who knows the algorithm can craft `--bogus-flag rm foo` and slip past. Realistic accidental argvs (like `podman rm foo`, `podman --log-level=debug rm foo`, `podman system prune`) are all blocked correctly. Broader bypass resistance would require per-command flag schemas (out of scope). |
| User edits `policy.json` by hand and writes invalid JSON | Daemon logs warning and treats as empty (degrades open). Trade-off: a typo could silently disable all policy. Operator must check daemon stderr after edits. Mitigated by `sandbox policy list` (validates parse). |
| Concurrent `sandbox policy` writes | Atomic-rename on save. |
| `command-map.json` rewrite changes alias resolution but policy keyed by alias | Intentional: policy is keyed by alias (the user-facing name), so remapping the *exec* doesn't invalidate the policy. |
| Policy disabled across all mappings until the user remembers it exists | This is a configuration-discoverability problem, not a code one. `sandbox policy list` is the discovery tool. |
