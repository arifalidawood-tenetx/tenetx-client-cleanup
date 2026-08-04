#!/bin/sh
#
# smoke-capture.sh — TENETX_AGENT_CAPTURE enable-agent-capture.sh smoke tests
#
# Tests:
#   - disable-writes-0: Verify disable writes literal 0 (not unset)
#   - pipe-status: Verify status works in piped (non-interactive) contexts
#   - default-status: Verify non-interactive defaults to status (never enable)
#   - single-block: Verify idempotency (block written multiple times = single block)
#   - baked-default quotes: Verify grep handles both '0' and "0" quote styles
#   - no-hook status: Verify status output when no hooks found
#

set -u

# ============================================================================
# Portable Hang Guard (perl alarm)
# ============================================================================

# Wraps a command with a timeout using perl (portable across macOS/Linux)
# Usage: timeout_guard 10 some_command arg1 arg2
timeout_guard() {
  local timeout_secs="$1"
  shift
  perl -e "alarm($timeout_secs); exec { \$ARGV[0] } @ARGV;" "$@"
}

# ============================================================================
# Test Utilities
# ============================================================================

test_count=0
pass_count=0
fail_count=0
test_dir=""

setup_test() {
  test_count=$((test_count + 1))
  test_dir=$(mktemp -d)
  export HOME="$test_dir"
  export TENETX_CAPTURE_ACTION=""
}

teardown_test() {
  rm -rf "$test_dir"
}

pass() {
  local msg="$1"
  pass_count=$((pass_count + 1))
  printf '✓ PASS: %s\n' "$msg"
}

fail() {
  local msg="$1"
  fail_count=$((fail_count + 1))
  printf '✗ FAIL: %s\n' "$msg"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local msg="$3"
  
  if echo "$haystack" | grep -q "$needle"; then
    pass "$msg"
  else
    fail "$msg (expected '$needle' in output)"
    printf '  Output was:\n%s\n' "$haystack" >&2
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local msg="$3"
  
  if ! echo "$haystack" | grep -q "$needle"; then
    pass "$msg"
  else
    fail "$msg (did not expect '$needle' in output)"
    printf '  Output was:\n%s\n' "$haystack" >&2
  fi
}

assert_file_contains() {
  local file="$1"
  local needle="$2"
  local msg="$3"
  
  if [ ! -f "$file" ]; then
    fail "$msg (file not found: $file)"
    return
  fi
  
  if grep -q "$needle" "$file"; then
    pass "$msg"
  else
    fail "$msg (expected '$needle' in $file)"
    printf '  File contents:\n' >&2
    cat "$file" >&2
  fi
}

assert_exit_code() {
  local expected="$1"
  local actual="$2"
  local msg="$3"
  
  if [ "$expected" -eq "$actual" ]; then
    pass "$msg"
  else
    fail "$msg (expected exit $expected, got $actual)"
  fi
}

# ============================================================================
# Test: disable-writes-0
# ============================================================================

test_disable_writes_0() {
  setup_test
  
  local script="$test_dir/enable-agent-capture.sh"
  cp "$(dirname "$0")/../enable-agent-capture.sh" "$script"
  chmod +x "$script"
  
  # Disable
  TENETX_CAPTURE_ACTION=disable timeout_guard 5 "$script" >/dev/null 2>&1
  
  # Verify .profile exists and contains literal 0
  if [ -f "$HOME/.profile" ]; then
    local content
    content=$(cat "$HOME/.profile")
    
    # Check for the marked block with literal 0
    if echo "$content" | grep -q 'export TENETX_AGENT_CAPTURE=0'; then
      pass "disable-writes-0: .profile contains TENETX_AGENT_CAPTURE=0"
    else
      fail "disable-writes-0: .profile missing or has wrong value"
      printf '  Content: %s\n' "$content" >&2
    fi
    
    # Verify not unset (should contain "0", not be empty)
    if ! echo "$content" | grep -q 'export TENETX_AGENT_CAPTURE=$'; then
      pass "disable-writes-0: value is not empty/unset"
    else
      fail "disable-writes-0: value is empty"
    fi
  else
    fail "disable-writes-0: .profile not created"
  fi
  
  teardown_test
}

# ============================================================================
# Test: pipe-status
# ============================================================================

test_pipe_status() {
  setup_test
  
  local script="$test_dir/enable-agent-capture.sh"
  cp "$(dirname "$0")/../enable-agent-capture.sh" "$script"
  chmod +x "$script"
  
  # Enable first
  TENETX_CAPTURE_ACTION=enable timeout_guard 5 "$script" >/dev/null 2>&1
  
  # Run status piped (non-interactive)
  local output
  output=$(TENETX_CAPTURE_ACTION=status timeout_guard 5 "$script" 2>&1 | cat)
  
  # Status should succeed even when piped
  assert_contains "$output" "Process Environment" "pipe-status: output includes Process Environment"
  assert_contains "$output" "1 (enabled)" "pipe-status: shows enabled status"
  
  teardown_test
}

# ============================================================================
# Test: default-status
# ============================================================================

test_default_status() {
  setup_test
  
  local script="$test_dir/enable-agent-capture.sh"
  cp "$(dirname "$0")/../enable-agent-capture.sh" "$script"
  chmod +x "$script"
  
  # Run with no args, piped (should default to status, not enable)
  local output
  output=$(echo "" | timeout_guard 5 "$script" 2>&1)
  
  # Should show status (Process Environment, Shell-RC, etc.), not enable message
  assert_contains "$output" "Status" "default-status: shows status output"
  assert_not_contains "$output" "Enabling TENETX_AGENT_CAPTURE" "default-status: does not enable"
  assert_not_contains "$output" "enabled (value: 1)" "default-status: does not show enable success"
  
  teardown_test
}

# ============================================================================
# Test: single-block
# ============================================================================

test_single_block() {
  setup_test
  
  local script="$test_dir/enable-agent-capture.sh"
  cp "$(dirname "$0")/../enable-agent-capture.sh" "$script"
  chmod +x "$script"
  
  # Enable multiple times
  TENETX_CAPTURE_ACTION=enable timeout_guard 5 "$script" >/dev/null 2>&1
  TENETX_CAPTURE_ACTION=enable timeout_guard 5 "$script" >/dev/null 2>&1
  TENETX_CAPTURE_ACTION=enable timeout_guard 5 "$script" >/dev/null 2>&1
  
  # Count how many times the marked block appears
  local profile_content
  if [ -f "$HOME/.profile" ]; then
    profile_content=$(cat "$HOME/.profile")
    local block_count
    block_count=$(echo "$profile_content" | grep -c '# >>> TENETX_AGENT_CAPTURE >>>' || echo 0)
    
    if [ "$block_count" -eq 1 ]; then
      pass "single-block: idempotent write, only one block"
    else
      fail "single-block: found $block_count blocks, expected 1"
      printf '  Content: %s\n' "$profile_content" >&2
    fi
  else
    fail "single-block: .profile not created"
  fi
  
  teardown_test
}

# ============================================================================
# Test: baked-default quote styles
# ============================================================================

test_baked_default_quotes() {
  setup_test
  
  local script="$test_dir/enable-agent-capture.sh"
  cp "$(dirname "$0")/../enable-agent-capture.sh" "$script"
  chmod +x "$script"
  
  # Create a fake guard hook with both quote styles
  mkdir -p "$HOME/.claude/hooks"
  cat > "$HOME/.claude/hooks/tenetx-guard.py" <<'HOOK'
# Test hook with single-quoted default
os.environ.get("TENETX_AGENT_CAPTURE", '0') == "1"
HOOK
  
  # Run status
  local output
  output=$(TENETX_CAPTURE_ACTION=status timeout_guard 5 "$script" 2>&1)
  
  # Should detect baked default even with single quotes
  assert_contains "$output" "baked default" "baked-default quotes: detects single-quoted style"
  
  # Now test double-quoted style
  cat > "$HOME/.claude/hooks/tenetx-guard.py" <<'HOOK'
# Test hook with double-quoted default
os.environ.get("TENETX_AGENT_CAPTURE", "1") == "1"
HOOK
  
  output=$(TENETX_CAPTURE_ACTION=status timeout_guard 5 "$script" 2>&1)
  assert_contains "$output" "baked default" "baked-default quotes: detects double-quoted style"
  
  teardown_test
}

# ============================================================================
# Test: no-hook status honesty
# ============================================================================

test_no_hook_status() {
  setup_test
  
  local script="$test_dir/enable-agent-capture.sh"
  cp "$(dirname "$0")/../enable-agent-capture.sh" "$script"
  chmod +x "$script"
  
  # Run status with no hooks installed
  local output
  output=$(TENETX_CAPTURE_ACTION=status timeout_guard 5 "$script" 2>&1)
  
  # Should warn about no hooks, but still show status
  assert_contains "$output" "No guard hooks found" "no-hook status: warns about missing hooks"
  assert_contains "$output" "Process Environment" "no-hook status: still shows process env"
  assert_contains "$output" "Shell-RC Files" "no-hook status: still shows shell-rc files"
  
  teardown_test
}

# ============================================================================
# Test: non-interactive default status (explicit)
# ============================================================================

test_non_interactive_default() {
  setup_test
  
  local script="$test_dir/enable-agent-capture.sh"
  cp "$(dirname "$0")/../enable-agent-capture.sh" "$script"
  chmod +x "$script"
  
  # Run with no args and no TTY (simulates piped context)
  local output
  output=$(echo | timeout_guard 5 "$script" 2>&1)
  
  # Should default to status
  assert_contains "$output" "Status" "non-interactive default: defaults to status"
  
  teardown_test
}

# ============================================================================
# Main
# ============================================================================

main() {
  printf '\n%s smoke-capture.sh — TENETX_AGENT_CAPTURE tests\n' "$(printf '\033[1m')"
  printf '%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n' "$(printf '\033[0m')"
  
  # Run all tests
  test_disable_writes_0
  test_pipe_status
  test_default_status
  test_single_block
  test_baked_default_quotes
  test_no_hook_status
  test_non_interactive_default
  
  # Summary
  printf '\n%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n' "$(printf '\033[0m')"
  printf 'Tests run: %d | Passed: %d | Failed: %d\n\n' "$test_count" "$pass_count" "$fail_count"
  
  if [ "$fail_count" -eq 0 ]; then
    printf '%s✓ All tests passed\n' "$(printf '\033[32m')"
    printf '%s\n' "$(printf '\033[0m')"
    exit 0
  else
    printf '%s✗ %d test(s) failed\n' "$(printf '\033[31m')" "$fail_count"
    printf '%s\n' "$(printf '\033[0m')"
    exit 1
  fi
}

main "$@"
