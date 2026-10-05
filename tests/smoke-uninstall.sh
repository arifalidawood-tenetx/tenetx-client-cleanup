#!/bin/sh
#
# smoke-uninstall.sh — uninstall-complete.sh user-data-loss regression tests
#
# Guards the removal-target table against cli-go/internal/ide/ide.go +
# hooks.Uninstall: a wrong row deletes a user's own hooks/MCP/settings, and a
# missing row leaves the next CLI install believing it is already wired.
#
# Every run happens inside a throwaway HOME with a stub `tenetx` first on PATH,
# so the real host binary (/opt/homebrew/bin/tenetx) is never executed and
# never deleted. A non-dry-run always passes --keep-binary for the same reason:
# list_binaries() hard-codes the host install dirs.
#
# Tests:
#   - wipe-keep-binary: --force --skip-revoke --keep-binary removes all 12
#     agents' TenetX wiring and keeps every user entry
#   - dry-run-binary: --dry-run reports the binary .bak + CLI PATH block and
#     changes nothing
#

set -u

# ============================================================================
# Portable Hang Guard (perl alarm)
# ============================================================================

timeout_guard() {
  _tmo=$1
  shift
  perl -e 'alarm shift; exec @ARGV' "$_tmo" "$@"
}

# ============================================================================
# Test Utilities
# ============================================================================

test_count=0
pass_count=0
fail_count=0
sandbox=""
stub_log=""

pass() {
  test_count=$((test_count + 1))
  pass_count=$((pass_count + 1))
  printf 'ok   - %s\n' "$1"
}

fail() {
  test_count=$((test_count + 1))
  fail_count=$((fail_count + 1))
  printf 'FAIL - %s\n' "$1"
}

# ============================================================================
# Fixture
# ============================================================================

make_fixture() {
  rm -rf "$sandbox"
  mkdir -p "$sandbox"
  stub_log="$sandbox/stub.log"
  : > "$stub_log"

  # Stub CLI: never touch the host binary, just record the invocation.
  mkdir -p "$sandbox/stub"
  cat > "$sandbox/stub/tenetx" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$SANDBOX_STUB_LOG"
exit 0
STUB
  chmod 755 "$sandbox/stub/tenetx"

  # Guard dirs for the 10 agents whose hooks live outside ~/.tenetx
  for d in .claude .cursor .windsurf .copilot .antigravity .qwen .hermes .augment .kiro .vibe; do
    mkdir -p "$sandbox/$d/hooks"
    : > "$sandbox/$d/hooks/tenetx-guard.sh"
    : > "$sandbox/$d/hooks/.tenetx-guard.json"
  done

  # Updater residue + a stray wrapper backup
  mkdir -p "$sandbox/.qwen/hooks/__pycache__"
  : > "$sandbox/.qwen/hooks/__pycache__/tenetx-guard.cpython-312.pyc"
  : > "$sandbox/.qwen/hooks/tenetx-guard.py.old"

  cat > "$sandbox/.qwen/settings.json" <<EOF
{"model":"x","hooks":{"PreToolUse":[{"matcher":".*","hooks":[{"type":"command","command":"$sandbox/.qwen/hooks/tenetx-guard.sh"}]},{"matcher":".*","hooks":[{"type":"command","command":"user.sh"}]}]}}
EOF
  : > "$sandbox/.qwen/settings.json.tenetx-backup.1"
  # A second suffix on the same base: catches a loop that re-globs from the
  # wrong base after its first deletion.
  : > "$sandbox/.qwen/settings.json.tenetx-test-backup.1"
  : > "$sandbox/.qwen/settings.json.pre-tenetx-clean.9"

  cat > "$sandbox/.augment/settings.json" <<EOF
{"model":"x","hooks":{"PreToolUse":[{"matcher":".*","hooks":[{"type":"command","command":"$sandbox/.augment/hooks/tenetx-guard.sh"}]},{"matcher":".*","hooks":[{"type":"command","command":"user.sh"}]}]}}
EOF
  : > "$sandbox/.augment/settings.json.tenetx-backup.1"

  mkdir -p "$sandbox/.codeium/windsurf" "$sandbox/.config/devin"
  cat > "$sandbox/.codeium/windsurf/hooks.json" <<EOF
{"hooks":{"pre_run_command":[{"command":"$sandbox/.windsurf/hooks/tenetx-guard.sh"},{"command":"user.sh"}]}}
EOF
  cat > "$sandbox/.config/devin/config.json" <<EOF
{"version":1,"model":"x","hooks":{"PreToolUse":[{"matcher":".*","hooks":[{"type":"command","command":"$sandbox/.windsurf/hooks/tenetx-guard.sh"}]},{"matcher":".*","hooks":[{"type":"command","command":"user.sh"}]}]}}
EOF

  mkdir -p "$sandbox/.gemini/config"
  cat > "$sandbox/.gemini/config/hooks.json" <<'EOF'
{"tenetx-guard":{"enabled":true},"mine":{"enabled":true}}
EOF

  cat > "$sandbox/.hermes/config.yaml" <<'EOF'
hooks:
  pre_tool_call:
    - command: "user.sh"
    # >>> TENETX GUARD (managed) - do not edit by hand
    - command: "/x/tenetx-guard.sh"
    # <<< TENETX GUARD (managed)
model: x
EOF
  cat > "$sandbox/.hermes/shell-hooks-allowlist.json" <<'EOF'
{"approvals":[{"event":"pre_tool_call","command":"/x/tenetx-guard.sh"},{"event":"pre_tool_call","command":"user.sh"}]}
EOF

  cat > "$sandbox/.vibe/hooks.toml" <<'EOF'
[[hooks]]
name = "mine"
# >>> TENETX MANAGED HOOKS -- do not edit inside this block >>>
[[hooks]]
name = "tenetx-guard-pre-tool"
# <<< TENETX MANAGED HOOKS <<<
EOF

  : > "$sandbox/.kiro/hooks/tenetx-guard.json"
  : > "$sandbox/.kiro/hooks/user.json"

  mkdir -p "$sandbox/Documents/Cline/Hooks"
  printf '%s\n' '# TENETX-CLINE-HOOK — PreToolUse' > "$sandbox/Documents/Cline/Hooks/PreToolUse"
  printf '%s\n' '# user content' > "$sandbox/Documents/Cline/Hooks/Notification"

  # User-owned files that must never be removed
  : > "$sandbox/.claude/hooks/hooks.json"
  : > "$sandbox/.cursor/hooks/hooks.json"   # legacy TenetX wiring (cursor only)

  mkdir -p "$sandbox/.codex/rules" "$sandbox/.agents/skills/tenetx-browser" "$sandbox/.agents/skills/other" "$sandbox/.cache/tenetx"
  : > "$sandbox/.codex/rules/tenetx.rules"
  : > "$sandbox/.agents/skills/tenetx-browser/SKILL.md"
  : > "$sandbox/.agents/skills/other/SKILL.md"
  : > "$sandbox/.cache/tenetx/x"

  cat > "$sandbox/.zshrc" <<'EOF'
export FOO=1

# >>> TENETX_CLI_PATH >>>
export PATH="/sandbox/local/bin:$PATH"
# <<< TENETX_CLI_PATH <<<

# >>> TenetX managed Codex CLI >>>
case "$PATH" in
  "$HOME/.tenetx/bin"|"$HOME/.tenetx/bin:"*) ;;
  *) export PATH="$HOME/.tenetx/bin:$PATH" ;;
esac
# <<< TenetX managed Codex CLI <<<
EOF

  mkdir -p "$sandbox/.local/bin"
  cp "$sandbox/stub/tenetx" "$sandbox/.local/bin/tenetx"
  cp "$sandbox/stub/tenetx" "$sandbox/.local/bin/tenetx.bak"
  cp "$sandbox/stub/tenetx" "$sandbox/.local/bin/tenetx.pr1.bak"

  cp "$(dirname "$0")/../uninstall-complete.sh" "$sandbox/uninstall-complete.sh"
}

run_wipe() {
  # Subshell, not `env`: timeout_guard is a shell function.
  # UNINSTALL_SH=/bin/dash reproduces the Linux /bin/sh path (macOS /bin/sh is
  # bash 3.2, which is laxer about `set -u` and about stray shell globals).
  (
    unset TENETX_CONFIG_DIR TENETX_INSTALL_DIR
    HOME="$sandbox"
    PATH="$sandbox/stub:/usr/bin:/bin"
    SANDBOX_STUB_LOG="$stub_log"
    export HOME PATH SANDBOX_STUB_LOG
    timeout_guard 60 "${UNINSTALL_SH:-sh}" "$sandbox/uninstall-complete.sh" "$@"
  ) 2>&1
}

# list_binaries()/find_tenetx() hard-code /usr/local/bin and /opt/homebrew/bin,
# so a bug in this test could delete the host CLI. Snapshot them (plus the real
# ~/.local/bin) around every run and fail if any byte changed.
host_snapshot() {
  for p in /usr/local/bin/tenetx /opt/homebrew/bin/tenetx \
    "${HOME:-/nonexistent}/.local/bin/tenetx" \
    "${HOME:-/nonexistent}/.local/bin/tenetx".*.bak \
    "${HOME:-/nonexistent}/.local/bin/tenetx.bak"; do
    if [ -e "$p" ]; then
      cksum "$p"
    else
      printf 'absent %s\n' "$p"
    fi
  done
}

# ============================================================================
# Assertion helpers
# ============================================================================

ck_gone() { # label path
  if [ -e "$2" ] || [ -L "$2" ]; then
    fail "$1 (still present: $2)"
  else
    pass "$1"
  fi
}

ck_stay() { # label path
  if [ -e "$2" ]; then
    pass "$1"
  else
    fail "$1 (missing: $2)"
  fi
}

ck_grep() { # label file pattern
  if [ -f "$2" ] && grep -q "$3" "$2" 2>/dev/null; then
    pass "$1"
  else
    fail "$1 (no match for '$3' in $2)"
  fi
}

ck_nogrep() { # label file pattern
  if [ -f "$2" ] && grep -q "$3" "$2" 2>/dev/null; then
    fail "$1 (found '$3' in $2)"
  else
    pass "$1"
  fi
}

# ============================================================================
# Test: wipe-keep-binary
# ============================================================================

test_wipe_keep_binary() {
  make_fixture
  out=$(run_wipe --force --skip-revoke --keep-binary)
  ec=$?
  if [ "$ec" -ne 0 ]; then
    printf '%s\n' "$out" | tail -20
    fail "wipe --force --keep-binary exits 0 (got $ec)"
  else
    pass "wipe --force --keep-binary exits 0"
  fi
  if printf '%s' "$out" | grep -q 'COMPLETE-UNINSTALL OK'; then
    pass "wipe reports COMPLETE-UNINSTALL OK"
  else
    printf '%s\n' "$out" | tail -20
    fail "wipe reports COMPLETE-UNINSTALL OK"
  fi

  # Isolation precondition: the stub, not the host binary, is what the script finds.
  resolved=$(env -u TENETX_CONFIG_DIR -u TENETX_INSTALL_DIR HOME="$sandbox" \
    PATH="$sandbox/stub:/usr/bin:/bin" sh -c 'command -v tenetx')
  if [ "$resolved" = "$sandbox/stub/tenetx" ]; then
    pass "tenetx resolves to the sandbox stub"
  else
    fail "tenetx resolves to the sandbox stub (got '$resolved')"
  fi

  # -- guard files removed from every agent --
  for d in .claude .cursor .windsurf .copilot .antigravity .qwen .hermes .augment .kiro .vibe; do
    ck_gone "guard removed: $d/hooks/tenetx-guard.sh" "$sandbox/$d/hooks/tenetx-guard.sh"
    ck_gone "guard removed: $d/hooks/.tenetx-guard.json" "$sandbox/$d/hooks/.tenetx-guard.json"
  done

  # -- residue --
  ck_gone "updater bytecode removed" "$sandbox/.qwen/hooks/__pycache__/tenetx-guard.cpython-312.pyc"
  ck_gone "wrapper backup removed" "$sandbox/.qwen/hooks/tenetx-guard.py.old"
  ck_gone "cli backup removed: settings.json.tenetx-backup.1" "$sandbox/.qwen/settings.json.tenetx-backup.1"
  ck_gone "cli backup removed: settings.json.tenetx-test-backup.1" "$sandbox/.qwen/settings.json.tenetx-test-backup.1"
  ck_gone "cli backup removed: settings.json.pre-tenetx-clean.9" "$sandbox/.qwen/settings.json.pre-tenetx-clean.9"
  ck_gone "cli backup removed: augment settings.json.tenetx-backup.1" "$sandbox/.augment/settings.json.tenetx-backup.1"
  ck_gone "kiro hook definition removed" "$sandbox/.kiro/hooks/tenetx-guard.json"
  ck_gone "cline dispatch removed" "$sandbox/Documents/Cline/Hooks/PreToolUse"
  ck_gone "codex rules removed" "$sandbox/.codex/rules/tenetx.rules"
  ck_gone "codex browser skill removed" "$sandbox/.agents/skills/tenetx-browser"
  ck_gone "cache removed" "$sandbox/.cache/tenetx"
  ck_gone "legacy cursor hooks.json removed" "$sandbox/.cursor/hooks/hooks.json"

  # -- wiring scrubbed --
  ck_nogrep "qwen hook wiring scrubbed" "$sandbox/.qwen/settings.json" 'tenetx-guard'
  ck_nogrep "augment hook wiring scrubbed" "$sandbox/.augment/settings.json" 'tenetx-guard'
  ck_nogrep "windsurf codeium wiring scrubbed" "$sandbox/.codeium/windsurf/hooks.json" 'tenetx-guard'
  ck_nogrep "devin config wiring scrubbed" "$sandbox/.config/devin/config.json" 'tenetx-guard'
  ck_nogrep "gemini top-level key scrubbed" "$sandbox/.gemini/config/hooks.json" 'tenetx-guard'
  ck_nogrep "hermes managed block stripped" "$sandbox/.hermes/config.yaml" 'TENETX GUARD'
  ck_nogrep "hermes allowlist scrubbed" "$sandbox/.hermes/shell-hooks-allowlist.json" 'tenetx-guard'
  ck_nogrep "vibe managed block stripped" "$sandbox/.vibe/hooks.toml" 'TENETX MANAGED HOOKS'
  ck_nogrep "zshrc Codex CLI block stripped" "$sandbox/.zshrc" 'TenetX managed Codex CLI'

  # -- user content preserved --
  ck_grep "qwen keeps user hook" "$sandbox/.qwen/settings.json" 'user.sh'
  ck_grep "qwen keeps model" "$sandbox/.qwen/settings.json" '"model"'
  ck_grep "augment keeps user hook" "$sandbox/.augment/settings.json" 'user.sh'
  ck_grep "windsurf keeps user hook" "$sandbox/.codeium/windsurf/hooks.json" 'user.sh'
  ck_grep "devin keeps user hook" "$sandbox/.config/devin/config.json" 'user.sh'
  ck_grep "gemini keeps user key" "$sandbox/.gemini/config/hooks.json" '"mine"'
  ck_grep "hermes keeps user hook" "$sandbox/.hermes/config.yaml" 'command: "user.sh"'
  ck_grep "hermes keeps model" "$sandbox/.hermes/config.yaml" 'model: x'
  ck_grep "hermes allowlist keeps user row" "$sandbox/.hermes/shell-hooks-allowlist.json" 'user.sh'
  ck_grep "vibe keeps user hook" "$sandbox/.vibe/hooks.toml" 'name = "mine"'
  ck_stay "kiro keeps user hook" "$sandbox/.kiro/hooks/user.json"
  ck_stay "cline keeps user hook" "$sandbox/Documents/Cline/Hooks/Notification"
  ck_stay "other agents skill kept" "$sandbox/.agents/skills/other/SKILL.md"
  ck_stay "claude user hooks.json kept" "$sandbox/.claude/hooks/hooks.json"
  ck_grep "zshrc keeps user export" "$sandbox/.zshrc" 'export FOO=1'

  # -- --keep-binary preserves the binary, its backups and the CLI PATH block --
  ck_stay "binary kept" "$sandbox/.local/bin/tenetx"
  ck_stay "binary .bak kept" "$sandbox/.local/bin/tenetx.bak"
  ck_stay "binary version .bak kept" "$sandbox/.local/bin/tenetx.pr1.bak"
  ck_grep "CLI PATH block kept" "$sandbox/.zshrc" 'TENETX_CLI_PATH'

  # -- product CLI invoked for uninstall, never for logout --
  ck_grep "stub saw uninstall" "$stub_log" '^uninstall'
  ck_nogrep "stub saw no logout" "$stub_log" 'logout'
  ck_gone "TENETX_DIR wiped" "$sandbox/.tenetx"
}

# ============================================================================
# Test: dry-run-binary
# ============================================================================

test_dry_run_binary() {
  make_fixture
  out=$(run_wipe --dry-run --skip-revoke)
  ec=$?
  if [ "$ec" -ne 0 ]; then
    printf '%s\n' "$out" | tail -20
    fail "dry-run exits 0 (got $ec)"
  else
    pass "dry-run exits 0"
  fi

  if printf '%s' "$out" | grep -qF "delete: $sandbox/.local/bin/tenetx.bak"; then
    pass "dry-run lists tenetx.bak deletion"
  else
    fail "dry-run lists tenetx.bak deletion"
  fi
  if printf '%s' "$out" | grep -qF "delete: $sandbox/.local/bin/tenetx.pr1.bak"; then
    pass "dry-run lists tenetx.pr1.bak deletion"
  else
    fail "dry-run lists tenetx.pr1.bak deletion"
  fi
  if printf '%s' "$out" | grep -qF "strip-block: $sandbox/.zshrc (# >>> TENETX_CLI_PATH >>>)"; then
    pass "dry-run lists CLI PATH block strip"
  else
    fail "dry-run lists CLI PATH block strip"
  fi

  ck_stay "dry-run kept tenetx.bak" "$sandbox/.local/bin/tenetx.bak"
  ck_stay "dry-run kept tenetx.pr1.bak" "$sandbox/.local/bin/tenetx.pr1.bak"
  ck_grep "dry-run kept CLI PATH block" "$sandbox/.zshrc" 'TENETX_CLI_PATH'
  ck_stay "dry-run kept guard file" "$sandbox/.qwen/hooks/tenetx-guard.sh"
  ck_grep "dry-run kept Codex CLI block" "$sandbox/.zshrc" 'TenetX managed Codex CLI'
}

# ============================================================================
# Test: wipe-default (no --keep-binary)
# ============================================================================

# list_binaries() hard-codes /usr/local/bin and /opt/homebrew/bin, so the
# default path can only be run where neither exists (a Linux container, or a
# machine with no system-wide tenetx). Never enable this on the dev Mac.
host_has_system_tenetx() {
  [ -e /usr/local/bin/tenetx ] || [ -e /opt/homebrew/bin/tenetx ]
}

test_wipe_default() {
  if host_has_system_tenetx; then
    printf 'skip - wipe-default (host has /usr/local/bin/tenetx or /opt/homebrew/bin/tenetx)\n'
    return 0
  fi
  make_fixture
  out=$(run_wipe --force --skip-revoke)
  ec=$?
  if [ "$ec" -ne 0 ]; then
    printf '%s\n' "$out" | tail -20
    fail "default wipe exits 0 (got $ec)"
  else
    pass "default wipe exits 0"
  fi
  if printf '%s' "$out" | grep -q 'COMPLETE-UNINSTALL OK'; then
    pass "default wipe reports COMPLETE-UNINSTALL OK"
  else
    printf '%s\n' "$out" | tail -20
    fail "default wipe reports COMPLETE-UNINSTALL OK"
  fi

  ck_gone "default wipe removed binary" "$sandbox/.local/bin/tenetx"
  ck_gone "default wipe removed tenetx.bak" "$sandbox/.local/bin/tenetx.bak"
  ck_gone "default wipe removed tenetx.pr1.bak" "$sandbox/.local/bin/tenetx.pr1.bak"
  ck_nogrep "default wipe stripped CLI PATH block" "$sandbox/.zshrc" 'TENETX_CLI_PATH'
  ck_grep "default wipe kept user export" "$sandbox/.zshrc" 'export FOO=1'
  ck_gone "default wipe removed guard file" "$sandbox/.qwen/hooks/tenetx-guard.sh"
  ck_gone "default wipe removed TENETX_DIR" "$sandbox/.tenetx"
  ck_grep "stub saw uninstall" "$stub_log" '^uninstall'
}

# ============================================================================
# Main
# ============================================================================

main() {
  sandbox=$(mktemp -d "${TMPDIR:-/tmp}/tx-uninstall-test.XXXXXX")
  trap 'rm -rf "$sandbox"' EXIT INT TERM

  host_before=$(host_snapshot)

  test_wipe_keep_binary
  printf '\n'
  test_dry_run_binary
  printf '\n'
  test_wipe_default

  if [ "$(host_snapshot)" = "$host_before" ]; then
    pass "host CLI binaries untouched"
  else
    fail "host CLI binaries changed — test isolation is broken"
  fi

  printf '\n%d assertions, %d passed, %d failed\n' \
    "$test_count" "$pass_count" "$fail_count"

  if [ "$fail_count" -ne 0 ]; then
    exit 1
  fi
}

main "$@"
