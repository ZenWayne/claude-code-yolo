# Sandbox Subcommand Block Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a per-mapping deny/allow policy layer to the sandbox daemon so that, e.g., `podman rm` can be blocked while the rest of `podman` stays reachable.

**Architecture:** All changes live in a single Rust file (`ultra-sandbox/sandbox-rs/src/main.rs`). A new `policy.json` file under `.ultra_sandbox/` stores per-command deny/allow rules expressed as token-array prefixes. The daemon reads it on every request and rejects with exit 126 when a request matches a deny rule or misses an active allow-list. A new `sandbox policy {deny|allow|unset|list|clear}` CLI manages the file. Pure logic (path extraction, prefix matching, rule mutation, formatting) is factored into testable functions; the daemon's `handle_client` gets one new check call.

**Tech Stack:** Rust 2021, `serde`, `serde_json` (already in `Cargo.toml`). One new dev-dependency: `tempfile` for filesystem tests.

**Spec:** [`docs/superpowers/specs/2026-04-28-sandbox-subcommand-block-design.md`](../specs/2026-04-28-sandbox-subcommand-block-design.md) (commit `88d098f`)

---

## File Structure

All edits to one file:

- `ultra-sandbox/sandbox-rs/src/main.rs` — additions:
  - **Types:** `CommandPolicy`, `PolicyMap` (alias), `PolicyDenial`, `PolicyListKind`
  - **Persistence:** `policy_path`, `load_policy`, `save_policy`
  - **Pure matching:** `extract_path`, `matches_path`, `check_policy`
  - **Pure mutation:** `add_rule`, `remove_rule`, `clear_command_policy`
  - **Pure formatting:** `format_command_policy`, `format_full_policy`
  - **CLI dispatch:** `run_policy`
  - **Modifications:** `handle_client` (insert policy check after map lookup), `main` (add `"policy"` arm), `usage` (extended help)
  - **Tests:** new `#[cfg(test)] mod tests { ... }` block at end of file

- `ultra-sandbox/sandbox-rs/Cargo.toml` — add `[dev-dependencies] tempfile = "3"`.

The plan is structured so that each task produces a clean compile + green tests. Pure-logic tasks come before I/O tasks; I/O tasks come before CLI; CLI comes before daemon wiring.

---

## Task 1: Baseline + test scaffolding

**Files:**
- Modify: `ultra-sandbox/sandbox-rs/Cargo.toml`
- Modify: `ultra-sandbox/sandbox-rs/src/main.rs` (append at EOF)

- [ ] **Step 1: Confirm clean baseline build**

Run: `cd ultra-sandbox/sandbox-rs && cargo build --release`
Expected: `Finished release [optimized] target(s)` — no errors, no warnings related to our work.

- [ ] **Step 2: Add `tempfile` dev-dependency**

Edit `ultra-sandbox/sandbox-rs/Cargo.toml`. Append after the existing `[target.'cfg(windows)'.dependencies]` block, before `[profile.release]`:

```toml
[dev-dependencies]
tempfile = "3"
```

- [ ] **Step 3: Add empty test module to `main.rs`**

Append to the very end of `ultra-sandbox/sandbox-rs/src/main.rs` (after the closing `}` of `main()`):

```rust
// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    #[allow(unused_imports)]
    use super::*;

    #[test]
    fn smoke() {
        assert_eq!(2 + 2, 4);
    }
}
```

The `#[allow(unused_imports)]` suppresses warnings until later tasks add usages.

- [ ] **Step 4: Run tests**

Run: `cd ultra-sandbox/sandbox-rs && cargo test`
Expected: `test tests::smoke ... ok` and `test result: ok. 1 passed`.

- [ ] **Step 5: Commit**

```bash
git add ultra-sandbox/sandbox-rs/Cargo.toml ultra-sandbox/sandbox-rs/src/main.rs
git commit -m "test(sandbox): scaffold tests module and add tempfile dev-dep"
```

---

## Task 2: `extract_path` — flag-skipping argv parser (TDD)

**Files:**
- Modify: `ultra-sandbox/sandbox-rs/src/main.rs`

This is pure logic with no dependencies on any other new code. Implement test-first.

- [ ] **Step 1: Write the failing tests**

Replace the `smoke` test inside `mod tests` with the suite below. Keep `#[allow(unused_imports)] use super::*;` at the top of the module.

```rust
fn s(parts: &[&str]) -> Vec<String> {
    parts.iter().map(|p| p.to_string()).collect()
}

#[test]
fn extract_path_empty() {
    assert_eq!(extract_path(&[] as &[String]), Vec::<String>::new());
}

#[test]
fn extract_path_simple_positional() {
    assert_eq!(extract_path(&s(&["rm", "myctr"])), s(&["rm", "myctr"]));
}

#[test]
fn extract_path_skips_flag_with_equals() {
    assert_eq!(
        extract_path(&s(&["--log-level=debug", "rm", "myctr"])),
        s(&["rm", "myctr"])
    );
}

#[test]
fn extract_path_skips_flag_and_value() {
    assert_eq!(
        extract_path(&s(&["--log-level", "debug", "rm"])),
        s(&["rm"])
    );
}

#[test]
fn extract_path_double_dash_ends_options() {
    assert_eq!(extract_path(&s(&["--", "rm"])), s(&["rm"]));
}

#[test]
fn extract_path_short_flag_swallows_next_token() {
    // Documented limitation: -f is treated as taking a value, so "rm" is consumed.
    assert_eq!(extract_path(&s(&["-f", "rm"])), Vec::<String>::new());
}

#[test]
fn extract_path_mixed_leading_equals_flag() {
    assert_eq!(
        extract_path(&s(&["--log-level=debug", "system", "prune"])),
        s(&["system", "prune"])
    );
}

#[test]
fn extract_path_equals_flag_in_middle_preserves_path() {
    assert_eq!(
        extract_path(&s(&["system", "--force=true", "prune"])),
        s(&["system", "prune"])
    );
}

#[test]
fn extract_path_bool_flag_in_middle_swallows_next() {
    // Documented limitation: --force is assumed to take a value, so "prune" is consumed.
    assert_eq!(
        extract_path(&s(&["system", "--force", "prune"])),
        s(&["system"])
    );
}
```

- [ ] **Step 2: Run tests, expect compile failure**

Run: `cd ultra-sandbox/sandbox-rs && cargo test`
Expected: compile error like `cannot find function 'extract_path' in this scope`.

- [ ] **Step 3: Implement `extract_path`**

Add this function block to `main.rs`. Place it directly after the `save_command_map` function (around line 248), before the `// Daemon` divider comment. Add a section header comment so the file structure stays readable:

```rust
// ---------------------------------------------------------------------------
// Policy: matching
// ---------------------------------------------------------------------------

fn extract_path(args: &[String]) -> Vec<String> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < args.len() {
        let a = &args[i];
        if a == "--" {
            i += 1;
            while i < args.len() {
                out.push(args[i].clone());
                i += 1;
            }
            break;
        }
        if a.starts_with('-') {
            if a.contains('=') {
                i += 1;
            } else {
                i += 2;
            }
            continue;
        }
        out.push(a.clone());
        i += 1;
    }
    out
}
```

- [ ] **Step 4: Run tests**

Run: `cd ultra-sandbox/sandbox-rs && cargo test extract_path`
Expected: `test result: ok. 9 passed; 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add ultra-sandbox/sandbox-rs/src/main.rs
git commit -m "feat(sandbox): add extract_path argv parser for policy matching"
```

---

## Task 3: `matches_path` — prefix matcher (TDD)

**Files:**
- Modify: `ultra-sandbox/sandbox-rs/src/main.rs`

- [ ] **Step 1: Write failing tests**

Append to `mod tests` (after the `extract_path_*` tests):

```rust
#[test]
fn matches_path_rule_is_prefix_of_path() {
    assert!(matches_path(&s(&["rm"]), &s(&["rm", "myctr"])));
}

#[test]
fn matches_path_exact_equality() {
    assert!(matches_path(&s(&["system", "prune"]), &s(&["system", "prune"])));
}

#[test]
fn matches_path_rule_longer_than_path() {
    assert!(!matches_path(&s(&["system", "prune"]), &s(&["system"])));
}

#[test]
fn matches_path_token_equality_not_substring() {
    assert!(!matches_path(&s(&["rm"]), &s(&["rmi"])));
}

#[test]
fn matches_path_empty_rule_matches_anything() {
    // Defensive: empty rules are dropped on load (Task 5), but if one slips
    // through it would match every path. Lock that behavior in so a future
    // refactor can't silently change it.
    assert!(matches_path(&[] as &[String], &s(&["anything"])));
    assert!(matches_path(&[] as &[String], &[] as &[String]));
}
```

- [ ] **Step 2: Run tests, expect compile failure**

Run: `cd ultra-sandbox/sandbox-rs && cargo test`
Expected: compile error `cannot find function 'matches_path'`.

- [ ] **Step 3: Implement `matches_path`**

Add directly after `extract_path` in `main.rs`:

```rust
fn matches_path(rule: &[String], path: &[String]) -> bool {
    rule.len() <= path.len()
        && rule.iter().zip(path.iter()).all(|(r, p)| r == p)
}
```

- [ ] **Step 4: Run tests**

Run: `cd ultra-sandbox/sandbox-rs && cargo test matches_path`
Expected: `test result: ok. 5 passed`.

- [ ] **Step 5: Commit**

```bash
git add ultra-sandbox/sandbox-rs/src/main.rs
git commit -m "feat(sandbox): add matches_path prefix matcher"
```

---

## Task 4: Policy types and `check_policy` (TDD)

**Files:**
- Modify: `ultra-sandbox/sandbox-rs/src/main.rs`

This task introduces `CommandPolicy`, `PolicyMap`, `PolicyDenial`, then implements `check_policy` against them.

- [ ] **Step 1: Write failing tests**

Append to `mod tests`:

```rust
fn rule(parts: &[&str]) -> Vec<String> {
    s(parts)
}

#[test]
fn check_policy_none_is_ok() {
    assert!(matches!(check_policy(None, &s(&["rm"])), Ok(())));
}

#[test]
fn check_policy_empty_lists_is_ok() {
    let p = CommandPolicy::default();
    assert!(matches!(check_policy(Some(&p), &s(&["rm"])), Ok(())));
}

#[test]
fn check_policy_matching_deny_returns_deny_with_rule() {
    let p = CommandPolicy {
        deny: vec![rule(&["rm"])],
        allow: vec![],
    };
    match check_policy(Some(&p), &s(&["rm", "foo"])) {
        Err(PolicyDenial::Deny(r)) => assert_eq!(r, rule(&["rm"])),
        other => panic!("expected Deny, got {:?}", other),
    }
}

#[test]
fn check_policy_allow_miss_returns_allow_miss() {
    let p = CommandPolicy {
        deny: vec![],
        allow: vec![rule(&["get"]), rule(&["describe"])],
    };
    assert!(matches!(
        check_policy(Some(&p), &s(&["delete", "pods", "foo"])),
        Err(PolicyDenial::AllowMiss)
    ));
}

#[test]
fn check_policy_allow_hit_is_ok() {
    let p = CommandPolicy {
        deny: vec![],
        allow: vec![rule(&["get"])],
    };
    assert!(matches!(
        check_policy(Some(&p), &s(&["get", "pods"])),
        Ok(())
    ));
}

#[test]
fn check_policy_deny_wins_over_allow_match() {
    // Both deny and allow would match. Deny is checked first and must win.
    let p = CommandPolicy {
        deny: vec![rule(&["system", "prune"])],
        allow: vec![rule(&["system"])],
    };
    match check_policy(Some(&p), &s(&["system", "prune", "-a"])) {
        Err(PolicyDenial::Deny(r)) => assert_eq!(r, rule(&["system", "prune"])),
        other => panic!("expected Deny(system prune), got {:?}", other),
    }
}

#[test]
fn check_policy_empty_path_with_active_allow_is_blocked() {
    let p = CommandPolicy {
        deny: vec![],
        allow: vec![rule(&["get"])],
    };
    assert!(matches!(
        check_policy(Some(&p), &[] as &[String]),
        Err(PolicyDenial::AllowMiss)
    ));
}
```

(Note: the test prints `{:?}` of `PolicyDenial`; we'll add `Debug` on the enum.)

- [ ] **Step 2: Run tests, expect compile failure**

Run: `cd ultra-sandbox/sandbox-rs && cargo test`
Expected: compile error referencing `CommandPolicy`, `PolicyDenial`, `check_policy`.

- [ ] **Step 3: Add types and `check_policy`**

Add a new section ABOVE the `// Policy: matching` header you added in Task 2 (so the order in the file is types → matching). Place this block immediately after `save_command_map` (around line 248):

```rust
// ---------------------------------------------------------------------------
// Policy: types and persistence
// ---------------------------------------------------------------------------

#[derive(Debug, Default, Serialize, Deserialize)]
struct CommandPolicy {
    #[serde(default)]
    deny: Vec<Vec<String>>,
    #[serde(default)]
    allow: Vec<Vec<String>>,
}

type PolicyMap = HashMap<String, CommandPolicy>;

#[derive(Debug)]
enum PolicyDenial {
    Deny(Vec<String>),
    AllowMiss,
}
```

Then add `check_policy` to the `// Policy: matching` section (after `matches_path`):

```rust
fn check_policy(
    policy: Option<&CommandPolicy>,
    path: &[String],
) -> Result<(), PolicyDenial> {
    let Some(p) = policy else {
        return Ok(());
    };

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
```

- [ ] **Step 4: Run tests**

Run: `cd ultra-sandbox/sandbox-rs && cargo test check_policy`
Expected: `test result: ok. 7 passed`.

- [ ] **Step 5: Commit**

```bash
git add ultra-sandbox/sandbox-rs/src/main.rs
git commit -m "feat(sandbox): add CommandPolicy types and check_policy"
```

---

## Task 5: Persistence — `policy_path`, `load_policy`, `save_policy` (TDD with tempdir)

**Files:**
- Modify: `ultra-sandbox/sandbox-rs/src/main.rs`

The production functions use `sandbox_dir()` for the file path. To keep tests independent, we factor the I/O into helpers that take an explicit path.

- [ ] **Step 1: Write failing tests**

Append to `mod tests`:

```rust
use tempfile::TempDir;

#[test]
fn save_then_load_roundtrip() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("policy.json");

    let mut map = PolicyMap::new();
    map.insert(
        "podman".into(),
        CommandPolicy {
            deny: vec![rule(&["rm"]), rule(&["system", "prune"])],
            allow: vec![],
        },
    );
    map.insert(
        "kubectl".into(),
        CommandPolicy {
            deny: vec![],
            allow: vec![rule(&["get"]), rule(&["describe"])],
        },
    );

    save_policy_at(&path, &map).unwrap();
    let loaded = load_policy_at(&path);

    assert_eq!(loaded.len(), 2);
    let p = loaded.get("podman").unwrap();
    assert_eq!(p.deny, vec![rule(&["rm"]), rule(&["system", "prune"])]);
    assert!(p.allow.is_empty());
    let k = loaded.get("kubectl").unwrap();
    assert!(k.deny.is_empty());
    assert_eq!(k.allow, vec![rule(&["get"]), rule(&["describe"])]);
}

#[test]
fn load_missing_file_returns_empty() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("does-not-exist.json");
    let loaded = load_policy_at(&path);
    assert!(loaded.is_empty());
}

#[test]
fn load_malformed_file_returns_empty() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("policy.json");
    std::fs::write(&path, b"not valid json {{{").unwrap();
    let loaded = load_policy_at(&path);
    assert!(loaded.is_empty());
}

#[test]
fn load_drops_empty_rules_defensively() {
    // Empty rules would match every path; sanitize them out at load time
    // so callers never have to worry about this edge case.
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("policy.json");
    std::fs::write(
        &path,
        br#"{"podman":{"deny":[[],["rm"]],"allow":[[]]}}"#,
    )
    .unwrap();
    let loaded = load_policy_at(&path);
    let p = loaded.get("podman").unwrap();
    assert_eq!(p.deny, vec![rule(&["rm"])]);
    assert!(p.allow.is_empty());
}

#[test]
fn save_uses_atomic_rename() {
    // After save, the .tmp file should not exist (rename consumed it).
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("policy.json");
    let tmp_path = path.with_extension("json.tmp");

    let map = PolicyMap::new();
    save_policy_at(&path, &map).unwrap();

    assert!(path.exists());
    assert!(!tmp_path.exists());
}
```

- [ ] **Step 2: Run tests, expect compile failure**

Run: `cd ultra-sandbox/sandbox-rs && cargo test`
Expected: compile error `cannot find function 'save_policy_at'` / `'load_policy_at'`.

- [ ] **Step 3: Implement persistence**

Add to the `// Policy: types and persistence` section, after the type definitions:

```rust
fn policy_path() -> PathBuf {
    sandbox_dir().join("policy.json")
}

fn load_policy_at(path: &Path) -> PolicyMap {
    let data = match fs::read(path) {
        Ok(d) => d,
        Err(_) => return PolicyMap::new(),
    };
    let mut map: PolicyMap = match serde_json::from_slice(&data) {
        Ok(m) => m,
        Err(e) => {
            eprintln!(
                "sandbox: warning: {} is not valid JSON ({}); ignoring policy",
                path.display(),
                e
            );
            return PolicyMap::new();
        }
    };
    // Drop empty rules defensively — they would match every path.
    for entry in map.values_mut() {
        entry.deny.retain(|r| !r.is_empty());
        entry.allow.retain(|r| !r.is_empty());
    }
    map
}

fn load_policy() -> PolicyMap {
    load_policy_at(&policy_path())
}

fn save_policy_at(path: &Path, map: &PolicyMap) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let tmp = path.with_extension("json.tmp");
    let json = serde_json::to_vec_pretty(map)
        .map_err(|e| io::Error::new(io::ErrorKind::Other, e))?;
    fs::write(&tmp, &json)?;
    fs::rename(&tmp, path)?;
    Ok(())
}

fn save_policy(map: &PolicyMap) -> io::Result<()> {
    save_policy_at(&policy_path(), map)
}
```

- [ ] **Step 4: Run tests**

Run: `cd ultra-sandbox/sandbox-rs && cargo test`
Expected: all 26 tests pass (9 extract_path + 5 matches_path + 7 check_policy + 5 persistence). Confirm `test result: ok. 26 passed`.

(Tip: a malformed-JSON test will print a "warning" line to stderr — that's expected. Run with `cargo test -- --nocapture` if you want to see it.)

- [ ] **Step 5: Commit**

```bash
git add ultra-sandbox/sandbox-rs/src/main.rs
git commit -m "feat(sandbox): persist policy.json with atomic-rename writes"
```

---

## Task 6: Pure mutation helpers — `add_rule`, `remove_rule`, `clear_command_policy` (TDD)

**Files:**
- Modify: `ultra-sandbox/sandbox-rs/src/main.rs`

Factor the rule mutations away from CLI/IO so they're testable. The CLI dispatcher in Task 8 will compose them.

- [ ] **Step 1: Write failing tests**

Append to `mod tests`:

```rust
#[test]
fn add_rule_inserts_into_deny_creating_entry() {
    let mut map = PolicyMap::new();
    add_rule(&mut map, "podman", rule(&["rm"]), PolicyListKind::Deny);
    let p = map.get("podman").unwrap();
    assert_eq!(p.deny, vec![rule(&["rm"])]);
    assert!(p.allow.is_empty());
}

#[test]
fn add_rule_inserts_into_allow() {
    let mut map = PolicyMap::new();
    add_rule(&mut map, "kubectl", rule(&["get"]), PolicyListKind::Allow);
    let p = map.get("kubectl").unwrap();
    assert_eq!(p.allow, vec![rule(&["get"])]);
    assert!(p.deny.is_empty());
}

#[test]
fn add_rule_is_idempotent() {
    let mut map = PolicyMap::new();
    add_rule(&mut map, "podman", rule(&["rm"]), PolicyListKind::Deny);
    add_rule(&mut map, "podman", rule(&["rm"]), PolicyListKind::Deny);
    add_rule(&mut map, "podman", rule(&["rm"]), PolicyListKind::Deny);
    assert_eq!(map.get("podman").unwrap().deny, vec![rule(&["rm"])]);
}

#[test]
fn remove_rule_returns_true_when_present_in_deny() {
    let mut map = PolicyMap::new();
    add_rule(&mut map, "podman", rule(&["rm"]), PolicyListKind::Deny);
    add_rule(&mut map, "podman", rule(&["kill"]), PolicyListKind::Deny);
    assert!(remove_rule(&mut map, "podman", &rule(&["rm"])));
    assert_eq!(map.get("podman").unwrap().deny, vec![rule(&["kill"])]);
}

#[test]
fn remove_rule_returns_true_when_present_in_allow() {
    let mut map = PolicyMap::new();
    add_rule(&mut map, "kubectl", rule(&["get"]), PolicyListKind::Allow);
    assert!(remove_rule(&mut map, "kubectl", &rule(&["get"])));
    assert!(map.get("kubectl").unwrap().allow.is_empty());
}

#[test]
fn remove_rule_returns_false_for_missing_command() {
    let mut map = PolicyMap::new();
    assert!(!remove_rule(&mut map, "podman", &rule(&["rm"])));
}

#[test]
fn remove_rule_returns_false_for_missing_rule() {
    let mut map = PolicyMap::new();
    add_rule(&mut map, "podman", rule(&["rm"]), PolicyListKind::Deny);
    assert!(!remove_rule(&mut map, "podman", &rule(&["kill"])));
}

#[test]
fn clear_command_policy_removes_entry() {
    let mut map = PolicyMap::new();
    add_rule(&mut map, "podman", rule(&["rm"]), PolicyListKind::Deny);
    assert!(clear_command_policy(&mut map, "podman"));
    assert!(map.get("podman").is_none());
}

#[test]
fn clear_command_policy_returns_false_when_absent() {
    let mut map = PolicyMap::new();
    assert!(!clear_command_policy(&mut map, "podman"));
}
```

- [ ] **Step 2: Run tests, expect compile failure**

Run: `cd ultra-sandbox/sandbox-rs && cargo test`
Expected: compile errors for `add_rule`, `remove_rule`, `clear_command_policy`, `PolicyListKind`.

- [ ] **Step 3: Add `PolicyListKind` and the mutation helpers**

In `main.rs`, in the `// Policy: types and persistence` section, add `PolicyListKind` right after `PolicyDenial`:

```rust
#[derive(Debug, Clone, Copy)]
enum PolicyListKind {
    Deny,
    Allow,
}
```

Then add a new section header and the three functions, placed after the `// Policy: matching` block:

```rust
// ---------------------------------------------------------------------------
// Policy: mutation helpers (pure, operate on PolicyMap in memory)
// ---------------------------------------------------------------------------

fn add_rule(map: &mut PolicyMap, cmd: &str, rule: Vec<String>, kind: PolicyListKind) {
    let entry = map.entry(cmd.to_string()).or_default();
    let target = match kind {
        PolicyListKind::Deny => &mut entry.deny,
        PolicyListKind::Allow => &mut entry.allow,
    };
    if !target.contains(&rule) {
        target.push(rule);
    }
}

fn remove_rule(map: &mut PolicyMap, cmd: &str, rule: &[String]) -> bool {
    let Some(entry) = map.get_mut(cmd) else {
        return false;
    };
    let before = entry.deny.len() + entry.allow.len();
    entry.deny.retain(|r| r.as_slice() != rule);
    entry.allow.retain(|r| r.as_slice() != rule);
    let after = entry.deny.len() + entry.allow.len();
    before != after
}

fn clear_command_policy(map: &mut PolicyMap, cmd: &str) -> bool {
    map.remove(cmd).is_some()
}
```

- [ ] **Step 4: Run tests**

Run: `cd ultra-sandbox/sandbox-rs && cargo test`
Expected: `test result: ok. 35 passed` (26 prior + 9 new).

- [ ] **Step 5: Commit**

```bash
git add ultra-sandbox/sandbox-rs/src/main.rs
git commit -m "feat(sandbox): add pure rule-mutation helpers for policy"
```

---

## Task 7: Listing format helpers (TDD)

**Files:**
- Modify: `ultra-sandbox/sandbox-rs/src/main.rs`

Pure functions that produce the human-readable output of `sandbox policy list`.

- [ ] **Step 1: Write failing tests**

Append to `mod tests`:

```rust
#[test]
fn format_command_policy_with_rules() {
    let p = CommandPolicy {
        deny: vec![rule(&["rm"]), rule(&["system", "prune"]), rule(&["volume", "rm"])],
        allow: vec![],
    };
    let out = format_command_policy("podman", Some(&p));
    let expected = "\
podman:
  deny:  rm
         system prune
         volume rm
  allow: (empty)
";
    assert_eq!(out, expected);
}

#[test]
fn format_command_policy_allow_only() {
    let p = CommandPolicy {
        deny: vec![],
        allow: vec![rule(&["get"]), rule(&["describe"])],
    };
    let out = format_command_policy("kubectl", Some(&p));
    let expected = "\
kubectl:
  deny:  (empty)
  allow: get
         describe
";
    assert_eq!(out, expected);
}

#[test]
fn format_command_policy_absent() {
    let out = format_command_policy("missing", None);
    assert_eq!(out, "no policy for missing\n");
}

#[test]
fn format_full_policy_empty() {
    let map = PolicyMap::new();
    assert_eq!(format_full_policy(&map), "no policy configured\n");
}

#[test]
fn format_full_policy_sorted_by_command_name() {
    let mut map = PolicyMap::new();
    add_rule(&mut map, "zsh", rule(&["completion"]), PolicyListKind::Allow);
    add_rule(&mut map, "podman", rule(&["rm"]), PolicyListKind::Deny);
    add_rule(&mut map, "adb", rule(&["shell"]), PolicyListKind::Allow);
    let out = format_full_policy(&map);
    // Commands appear in sorted order, separated by blank lines.
    let adb_pos = out.find("adb:").unwrap();
    let podman_pos = out.find("podman:").unwrap();
    let zsh_pos = out.find("zsh:").unwrap();
    assert!(adb_pos < podman_pos);
    assert!(podman_pos < zsh_pos);
}
```

- [ ] **Step 2: Run tests, expect compile failure**

Run: `cd ultra-sandbox/sandbox-rs && cargo test`
Expected: compile errors for `format_command_policy`, `format_full_policy`.

- [ ] **Step 3: Implement formatters**

Add a new section after the mutation helpers:

```rust
// ---------------------------------------------------------------------------
// Policy: human-readable formatting (for `sandbox policy list`)
// ---------------------------------------------------------------------------

fn format_command_policy(name: &str, policy: Option<&CommandPolicy>) -> String {
    let Some(p) = policy else {
        return format!("no policy for {}\n", name);
    };
    let mut out = String::new();
    out.push_str(name);
    out.push_str(":\n");

    out.push_str("  deny:  ");
    if p.deny.is_empty() {
        out.push_str("(empty)\n");
    } else {
        for (i, r) in p.deny.iter().enumerate() {
            if i > 0 {
                out.push_str("         ");
            }
            out.push_str(&r.join(" "));
            out.push('\n');
        }
    }

    out.push_str("  allow: ");
    if p.allow.is_empty() {
        out.push_str("(empty)\n");
    } else {
        for (i, r) in p.allow.iter().enumerate() {
            if i > 0 {
                out.push_str("         ");
            }
            out.push_str(&r.join(" "));
            out.push('\n');
        }
    }
    out
}

fn format_full_policy(map: &PolicyMap) -> String {
    if map.is_empty() {
        return "no policy configured\n".to_string();
    }
    let mut names: Vec<&String> = map.keys().collect();
    names.sort();
    let mut out = String::new();
    for (i, name) in names.iter().enumerate() {
        if i > 0 {
            out.push('\n');
        }
        out.push_str(&format_command_policy(name, map.get(*name)));
    }
    out
}
```

- [ ] **Step 4: Run tests**

Run: `cd ultra-sandbox/sandbox-rs && cargo test format_`
Expected: 5 passed.

- [ ] **Step 5: Commit**

```bash
git add ultra-sandbox/sandbox-rs/src/main.rs
git commit -m "feat(sandbox): add format helpers for policy list output"
```

---

## Task 8: CLI dispatcher — `run_policy`

**Files:**
- Modify: `ultra-sandbox/sandbox-rs/src/main.rs`

This composes the load → mutate → save → print pipeline. Hard to unit-test the full function (it calls `process::exit`), but its parts are already tested. We add one integration-style test that drives it via an explicit-path variant to lock in argv parsing and exit behavior contracts. The production dispatcher uses the default `policy_path()`.

- [ ] **Step 1: Write failing tests for argv parsing**

Append to `mod tests`. We'll factor `run_policy` so the parsing layer returns a struct, and the file mutation is a separate function — both testable.

```rust
#[test]
fn parse_policy_args_deny() {
    let args = s(&["deny", "podman", "system", "prune"]);
    let op = parse_policy_args(&args).unwrap();
    assert!(matches!(
        op,
        PolicyOp::Add { ref cmd, ref path, kind: PolicyListKind::Deny }
            if cmd == "podman" && path == &rule(&["system", "prune"])
    ));
}

#[test]
fn parse_policy_args_allow() {
    let args = s(&["allow", "kubectl", "get"]);
    let op = parse_policy_args(&args).unwrap();
    assert!(matches!(
        op,
        PolicyOp::Add { ref cmd, ref path, kind: PolicyListKind::Allow }
            if cmd == "kubectl" && path == &rule(&["get"])
    ));
}

#[test]
fn parse_policy_args_unset() {
    let args = s(&["unset", "podman", "rm"]);
    let op = parse_policy_args(&args).unwrap();
    assert!(matches!(
        op,
        PolicyOp::Unset { ref cmd, ref path }
            if cmd == "podman" && path == &rule(&["rm"])
    ));
}

#[test]
fn parse_policy_args_clear() {
    let args = s(&["clear", "podman"]);
    let op = parse_policy_args(&args).unwrap();
    assert!(matches!(op, PolicyOp::Clear { ref cmd } if cmd == "podman"));
}

#[test]
fn parse_policy_args_list_all() {
    let args = s(&["list"]);
    let op = parse_policy_args(&args).unwrap();
    assert!(matches!(op, PolicyOp::List { cmd: None }));
}

#[test]
fn parse_policy_args_list_one() {
    let args = s(&["list", "podman"]);
    let op = parse_policy_args(&args).unwrap();
    assert!(matches!(op, PolicyOp::List { cmd: Some(ref c) } if c == "podman"));
}

#[test]
fn parse_policy_args_deny_without_path_errors() {
    // Spec: Empty path is rejected with exit 1 and a usage message.
    let args = s(&["deny", "podman"]);
    assert!(parse_policy_args(&args).is_err());
}

#[test]
fn parse_policy_args_unknown_verb_errors() {
    let args = s(&["bogus", "podman"]);
    assert!(parse_policy_args(&args).is_err());
}

#[test]
fn parse_policy_args_no_verb_errors() {
    let args = s(&[]);
    assert!(parse_policy_args(&args).is_err());
}
```

- [ ] **Step 2: Run tests, expect compile failure**

Run: `cd ultra-sandbox/sandbox-rs && cargo test`
Expected: errors for `parse_policy_args`, `PolicyOp`.

- [ ] **Step 3: Implement parser + op enum + dispatcher**

Add a new section after the formatters:

```rust
// ---------------------------------------------------------------------------
// Policy: CLI dispatcher
// ---------------------------------------------------------------------------

#[derive(Debug)]
enum PolicyOp {
    Add { cmd: String, path: Vec<String>, kind: PolicyListKind },
    Unset { cmd: String, path: Vec<String> },
    Clear { cmd: String },
    List { cmd: Option<String> },
}

fn parse_policy_args(args: &[String]) -> Result<PolicyOp, String> {
    let verb = args.first().ok_or_else(|| "missing verb".to_string())?;
    match verb.as_str() {
        "deny" | "allow" => {
            let kind = if verb == "deny" {
                PolicyListKind::Deny
            } else {
                PolicyListKind::Allow
            };
            let cmd = args
                .get(1)
                .ok_or_else(|| format!("usage: sandbox policy {} <cmd> <subcmd-path...>", verb))?
                .clone();
            let path: Vec<String> = args.iter().skip(2).cloned().collect();
            if path.is_empty() {
                return Err(format!(
                    "usage: sandbox policy {} <cmd> <subcmd-path...>",
                    verb
                ));
            }
            Ok(PolicyOp::Add { cmd, path, kind })
        }
        "unset" => {
            let cmd = args
                .get(1)
                .ok_or_else(|| "usage: sandbox policy unset <cmd> <subcmd-path...>".to_string())?
                .clone();
            let path: Vec<String> = args.iter().skip(2).cloned().collect();
            if path.is_empty() {
                return Err("usage: sandbox policy unset <cmd> <subcmd-path...>".to_string());
            }
            Ok(PolicyOp::Unset { cmd, path })
        }
        "clear" => {
            let cmd = args
                .get(1)
                .ok_or_else(|| "usage: sandbox policy clear <cmd>".to_string())?
                .clone();
            if args.len() > 2 {
                return Err("usage: sandbox policy clear <cmd>".to_string());
            }
            Ok(PolicyOp::Clear { cmd })
        }
        "list" => {
            let cmd = args.get(1).cloned();
            if args.len() > 2 {
                return Err("usage: sandbox policy list [<cmd>]".to_string());
            }
            Ok(PolicyOp::List { cmd })
        }
        other => Err(format!(
            "sandbox policy: unknown verb '{}' (expected deny|allow|unset|list|clear)",
            other
        )),
    }
}

fn run_policy(args: &[String]) {
    let op = match parse_policy_args(args) {
        Ok(op) => op,
        Err(e) => {
            eprintln!("{}", e);
            process::exit(1);
        }
    };

    let path = policy_path();
    let mut map = load_policy_at(&path);

    match op {
        PolicyOp::Add { cmd, path: rule, kind } => {
            add_rule(&mut map, &cmd, rule, kind);
            if let Err(e) = save_policy_at(&path, &map) {
                eprintln!("sandbox policy: write {}: {}", path.display(), e);
                process::exit(1);
            }
        }
        PolicyOp::Unset { cmd, path: rule } => {
            if !remove_rule(&mut map, &cmd, &rule) {
                eprintln!(
                    "sandbox policy: no such rule for '{}': {}",
                    cmd,
                    rule.join(" ")
                );
                process::exit(1);
            }
            if let Err(e) = save_policy_at(&path, &map) {
                eprintln!("sandbox policy: write {}: {}", path.display(), e);
                process::exit(1);
            }
        }
        PolicyOp::Clear { cmd } => {
            if !clear_command_policy(&mut map, &cmd) {
                eprintln!("sandbox policy: no policy for '{}'", cmd);
                process::exit(1);
            }
            if let Err(e) = save_policy_at(&path, &map) {
                eprintln!("sandbox policy: write {}: {}", path.display(), e);
                process::exit(1);
            }
        }
        PolicyOp::List { cmd: None } => {
            print!("{}", format_full_policy(&map));
        }
        PolicyOp::List { cmd: Some(c) } => {
            print!("{}", format_command_policy(&c, map.get(&c)));
        }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `cd ultra-sandbox/sandbox-rs && cargo test`
Expected: `test result: ok. 49 passed` (40 prior + 9 new). Build also succeeds with no warnings.

- [ ] **Step 5: Commit**

```bash
git add ultra-sandbox/sandbox-rs/src/main.rs
git commit -m "feat(sandbox): add run_policy CLI dispatcher and arg parser"
```

---

## Task 9: Wire `policy` into `main()` and `usage()`

**Files:**
- Modify: `ultra-sandbox/sandbox-rs/src/main.rs` (in `usage()` ~line 699 and `main()` ~line 718)

- [ ] **Step 1: Extend `usage()`**

Find the existing `usage()` function (around line 699). After the line:

```rust
    eprintln!("    --exec PATH  resolve alias to a specific host script/binary path");
```

…and BEFORE `process::exit(1);`, insert:

```rust
    eprintln!("  sandbox policy deny|allow|unset <cmd> <subcmd-path...>  manage per-command policy");
    eprintln!("  sandbox policy list [<cmd>]                              show current policy");
    eprintln!("  sandbox policy clear <cmd>                               drop all rules for cmd");
```

So `usage()` reads as a coherent block.

- [ ] **Step 2: Add `"policy"` arm to `main()`**

In `main()`, the existing `match args[1].as_str()` block has arms `"daemon"`, `"run"`, `"map"`, and a default `_ => usage()`. Add a `"policy"` arm immediately before the default arm:

```rust
        "policy" => {
            let rest: Vec<String> = args.iter().skip(2).cloned().collect();
            run_policy(&rest);
        }
```

The full match should look like:

```rust
    match args[1].as_str() {
        "daemon" => { ... existing ... }
        "run" => { ... existing ... }
        "map" => { ... existing ... }
        "policy" => {
            let rest: Vec<String> = args.iter().skip(2).cloned().collect();
            run_policy(&rest);
        }
        _ => {
            usage();
        }
    }
```

- [ ] **Step 3: Build**

Run: `cd ultra-sandbox/sandbox-rs && cargo build --release`
Expected: clean build, no warnings.

- [ ] **Step 4: Quick smoke test of CLI plumbing (no daemon required)**

```bash
cd ultra-sandbox/sandbox-rs
SANDBOX_DIR=$(mktemp -d) ./target/release/sandbox policy list
# expect: "no policy configured"

SANDBOX_DIR=$(mktemp -d) bash -c '
  ./target/release/sandbox policy deny podman rm
  ./target/release/sandbox policy deny podman system prune
  ./target/release/sandbox policy allow podman ps
  ./target/release/sandbox policy list
'
# expect:
# podman:
#   deny:  rm
#          system prune
#   allow: ps
```

If anything looks wrong, fix it before continuing.

- [ ] **Step 5: Commit**

```bash
git add ultra-sandbox/sandbox-rs/src/main.rs
git commit -m "feat(sandbox): wire 'policy' subcommand into main entry point"
```

---

## Task 10: Daemon enforcement in `handle_client`

**Files:**
- Modify: `ultra-sandbox/sandbox-rs/src/main.rs` (`handle_client`, ~lines 285-320)

This is the smallest code change with the biggest behavioral effect. The block uses `FRAME_STDERR` + `FRAME_EXIT 126` and logs a denial line to daemon stderr.

- [ ] **Step 1: Write a denial-formatting test**

We extract one tiny helper to keep the daemon path lean and unit-testable.

Append to `mod tests`:

```rust
#[test]
fn format_denial_message_for_deny_rule() {
    let denial = PolicyDenial::Deny(rule(&["system", "prune"]));
    let msg = format_denial_message("podman", &denial);
    assert_eq!(msg, "sandbox: 'podman system prune' denied by policy\n");
}

#[test]
fn format_denial_message_for_allow_miss() {
    let denial = PolicyDenial::AllowMiss;
    let path = rule(&["exec", "myctr", "bash"]);
    let msg = format_denial_message_allow_miss("podman", &path);
    assert_eq!(msg, "sandbox: 'podman exec myctr bash' not in allow-list\n");
}

#[test]
fn format_denial_log_line_deny() {
    let argv = s(&["rm", "myctr"]);
    let denial = PolicyDenial::Deny(rule(&["rm"]));
    let line = format_denial_log("podman", &argv, &denial);
    assert_eq!(line, "sandbox daemon: blocked podman rm myctr (deny rule: rm)");
}

#[test]
fn format_denial_log_line_allow_miss() {
    let argv = s(&["exec", "myctr", "bash"]);
    let denial = PolicyDenial::AllowMiss;
    let line = format_denial_log("podman", &argv, &denial);
    assert_eq!(line, "sandbox daemon: blocked podman exec myctr bash (allow-list miss)");
}
```

- [ ] **Step 2: Run tests, expect compile failure**

Run: `cd ultra-sandbox/sandbox-rs && cargo test`
Expected: errors for `format_denial_message`, `format_denial_message_allow_miss`, `format_denial_log`.

- [ ] **Step 3: Implement the formatting helpers**

Add a new section after the CLI dispatcher:

```rust
// ---------------------------------------------------------------------------
// Policy: denial messages (used by handle_client)
// ---------------------------------------------------------------------------

fn format_denial_message(cmd: &str, denial: &PolicyDenial) -> String {
    match denial {
        PolicyDenial::Deny(rule) => {
            format!("sandbox: '{} {}' denied by policy\n", cmd, rule.join(" "))
        }
        // Allow-miss case has no matched rule to print; caller must format
        // with the attempted path. This branch is unreachable in practice but
        // we provide a sensible fallback.
        PolicyDenial::AllowMiss => {
            format!("sandbox: '{}' not in allow-list\n", cmd)
        }
    }
}

fn format_denial_message_allow_miss(cmd: &str, attempted_path: &[String]) -> String {
    if attempted_path.is_empty() {
        format!("sandbox: '{}' not in allow-list\n", cmd)
    } else {
        format!(
            "sandbox: '{} {}' not in allow-list\n",
            cmd,
            attempted_path.join(" ")
        )
    }
}

fn format_denial_log(cmd: &str, argv: &[String], denial: &PolicyDenial) -> String {
    let argv_joined = argv.join(" ");
    let argv_part = if argv_joined.is_empty() {
        String::new()
    } else {
        format!(" {}", argv_joined)
    };
    match denial {
        PolicyDenial::Deny(rule) => format!(
            "sandbox daemon: blocked {}{} (deny rule: {})",
            cmd,
            argv_part,
            rule.join(" ")
        ),
        PolicyDenial::AllowMiss => format!(
            "sandbox daemon: blocked {}{} (allow-list miss)",
            cmd, argv_part
        ),
    }
}
```

- [ ] **Step 4: Run tests**

Run: `cd ultra-sandbox/sandbox-rs && cargo test format_denial`
Expected: 4 passed.

- [ ] **Step 5: Wire enforcement into `handle_client`**

In `handle_client`, modify the section that currently looks like (around line 303-313):

```rust
    // Whitelist check: only mapped commands are allowed.
    let map = load_command_map();
    match map.get(&req.cmd) {
        Some(resolved) => req.cmd = resolved.clone(),
        None => {
            let msg = format!("sandbox: '{}' is not a mapped command\n", req.cmd);
            let _ = write_frame(&mut conn, FRAME_STDERR, msg.as_bytes());
            let _ = write_frame(&mut conn, FRAME_EXIT, &encode_exit(1));
            return Ok(());
        }
    }
```

Replace with:

```rust
    // Whitelist check: only mapped commands are allowed.
    let map = load_command_map();
    let map_key = req.cmd.clone();
    match map.get(&req.cmd) {
        Some(resolved) => req.cmd = resolved.clone(),
        None => {
            let msg = format!("sandbox: '{}' is not a mapped command\n", req.cmd);
            let _ = write_frame(&mut conn, FRAME_STDERR, msg.as_bytes());
            let _ = write_frame(&mut conn, FRAME_EXIT, &encode_exit(1));
            return Ok(());
        }
    }

    // Policy check: deny-list / allow-list per mapped command.
    let policy_map = load_policy();
    let path = extract_path(&req.args);
    if let Err(denial) = check_policy(policy_map.get(&map_key), &path) {
        let user_msg = match &denial {
            PolicyDenial::Deny(_) => format_denial_message(&map_key, &denial),
            PolicyDenial::AllowMiss => format_denial_message_allow_miss(&map_key, &path),
        };
        let log_line = format_denial_log(&map_key, &req.args, &denial);
        eprintln!("{}", log_line);
        let _ = write_frame(&mut conn, FRAME_STDERR, user_msg.as_bytes());
        let _ = write_frame(&mut conn, FRAME_EXIT, &encode_exit(126));
        return Ok(());
    }
```

- [ ] **Step 6: Build**

Run: `cd ultra-sandbox/sandbox-rs && cargo build --release`
Expected: clean build, no warnings.

- [ ] **Step 7: Run all tests**

Run: `cd ultra-sandbox/sandbox-rs && cargo test`
Expected: `test result: ok. 53 passed; 0 failed` (49 prior + 4 denial formatters; the new `handle_client` wiring is exercised by the smoke test in Task 11, not unit tests).

- [ ] **Step 8: Commit**

```bash
git add ultra-sandbox/sandbox-rs/src/main.rs
git commit -m "feat(sandbox): enforce policy in handle_client, exit 126 on block"
```

---

## Task 11: Manual smoke test on real host

**Files:** none. Verification only.

This is the spec's required manual test. Run on the actual host (not inside a container) — it requires the daemon to be running on the real socket path.

- [ ] **Step 1: Install fresh binary**

```bash
cd ultra-sandbox/sandbox-rs && cargo build --release \
  && install -m 755 target/release/sandbox ~/.local/bin/sandbox
```

- [ ] **Step 2: (Re)start the daemon**

If a daemon is already running, kill it and restart so it picks up the new binary:

```bash
pkill -f 'sandbox daemon' || true
sandbox daemon &
disown
```

- [ ] **Step 3: Set up policy in a fresh workspace**

```bash
TESTDIR=$(mktemp -d)
cd "$TESTDIR"
mkdir -p .ultra_sandbox
sandbox map podman                # creates command-map.json + shim
sandbox policy deny podman rm
sandbox policy list podman
# expect:
# podman:
#   deny:  rm
#   allow: (empty)
```

- [ ] **Step 4: Verify deny enforcement**

```bash
podman ps                          # expect: works, lists containers (or whatever podman shows)

podman rm nonexistent_container || echo "exit: $?"
# expect on stderr: sandbox: 'podman rm' denied by policy
# expect: exit 126

podman --log-level=debug rm nonexistent_container || echo "exit: $?"
# expect: also blocked, exit 126 (flag-skipping works)
```

Daemon stderr (the terminal where you started it) should show:
```
sandbox daemon: blocked podman rm nonexistent_container (deny rule: rm)
sandbox daemon: blocked podman --log-level=debug rm nonexistent_container (deny rule: rm)
```

- [ ] **Step 5: Verify unset and clear**

```bash
sandbox policy unset podman rm
sandbox policy list podman
# expect: deny: (empty), allow: (empty)

podman rm nonexistent_container || echo "exit: $?"
# expect: real podman error (because the container doesn't exist), NOT a sandbox block

sandbox policy clear podman
sandbox policy list podman
# expect: no policy for podman
```

- [ ] **Step 6: Verify allow-list mode**

```bash
sandbox policy allow podman ps
sandbox policy allow podman images

podman ps                          # expect: works
podman images                      # expect: works
podman rm nonexistent || echo "exit: $?"
# expect on stderr: sandbox: 'podman rm nonexistent' not in allow-list
# expect: exit 126

sandbox policy clear podman
```

- [ ] **Step 7: Tear down**

```bash
pkill -f 'sandbox daemon' || true
rm -rf "$TESTDIR"
```

- [ ] **Step 8: Update CLAUDE.md if needed**

Read `ultra-sandbox/CLAUDE.md`. If it documents the sandbox commands (it does — see the "sandbox setup" section), add a brief mention of the new `policy` verb after the `map` examples.

Append to the `sandbox setup` section:

```markdown
Block specific subcommands per mapped command:

```bash
sandbox policy deny podman rm
sandbox policy deny podman system prune
sandbox policy allow kubectl get
sandbox policy list
```

See `docs/superpowers/specs/2026-04-28-sandbox-subcommand-block-design.md` for full semantics.
```

- [ ] **Step 9: Commit doc update if you made one**

```bash
git add ultra-sandbox/CLAUDE.md
git commit -m "docs(sandbox): document new 'policy' subcommand in CLAUDE.md"
```

---

## Verification at end

- [ ] All 53 unit tests pass: `cd ultra-sandbox/sandbox-rs && cargo test` → `test result: ok. 53 passed`.
- [ ] Release build is clean and warning-free: `cargo build --release` → no warnings from our new code.
- [ ] Manual smoke test (Task 11) passed on the host.
- [ ] `sandbox policy list` works without a daemon running.
- [ ] No changes to existing public protocol or wire format.
- [ ] `command-map.json` migration: none required; existing files keep working.

---

## Out of scope (deferred per spec)

- Per-command flag schemas / flag-aware bypass resistance.
- Hot reload via inotify.
- Atomic-write retrofit for `command-map.json`.
- Per-user / per-container policy files.
- `--dry-run` mode.

These are explicitly out of scope and should not be added during this implementation.
