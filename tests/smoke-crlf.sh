#!/bin/sh
#
# smoke-crlf.sh — line-ending and shell-syntax regression tests
#
# Guards the release-asset failure where uninstall-complete.sh was uploaded
# with CRLF line terminators: `set -eu\r` makes sh exit 2 with
# "set: -: invalid option" on line 16 of the piped script.
#
# Tests:
#   - no-cr: every *.sh in the repo has zero carriage-return bytes
#   - sh-syntax: every *.sh passes `sh -n`
#   - exec-piped: uninstall-complete.sh runs to completion when invoked
#     non-interactively (dry-run) without "invalid option"
#

set -u

# ============================================================================
# Portable Hang Guard (perl alarm)
# ============================================================================

# Wraps a command with a timeout using perl (portable across macOS/Linux)
# Usage: timeout_guard 10 some_command arg1 arg2
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
test_dir=""

setup_test() {
  test_dir=$(mktemp -d "${TMPDIR:-/tmp}/tx-crlf-test.XXXXXX")
}

teardown_test() {
  rm -rf "$test_dir"
}

pass() {
  pass_count=$((pass_count + 1))
  printf 'ok   - %s\n' "$1"
}

fail() {
  fail_count=$((fail_count + 1))
  printf 'FAIL - %s\n' "$1"
}

# ============================================================================
# Helpers
# ============================================================================

# Files tracked by git. Falls back to a glob when not in a git repo.
repo_sh_files() {
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git ls-files '*.sh'
  else
    find . -name '*.sh' -not -path './.git/*'
  fi
}

# ============================================================================
# Test: no-cr
# ============================================================================

test_no_cr() {
  test_count=$((test_count + 1))
  setup_test
  ok=1
  for f in $(repo_sh_files); do
    if tr -dc '\r' < "$f" | grep -q .; then
      printf 'FAIL - %s contains CR bytes\n' "$f"
      ok=0
    fi
  done
  if [ "$ok" -eq 1 ]; then
    pass "all tracked *.sh files have zero CR bytes"
  else
    fail "tracked *.sh files contain CR bytes"
  fi
  teardown_test
}

# ============================================================================
# Test: sh-syntax
# ============================================================================

test_sh_syntax() {
  test_count=$((test_count + 1))
  setup_test
  ok=1
  for f in $(repo_sh_files); do
    if ! sh -n "$f" 2>/dev/null; then
      printf 'FAIL - %s fails sh -n\n' "$f"
      ok=0
    fi
  done
  if [ "$ok" -eq 1 ]; then
    pass "all tracked *.sh files pass sh -n"
  else
    fail "some tracked *.sh files fail sh -n"
  fi
  teardown_test
}

# ============================================================================
# Test: exec-piped
# ============================================================================

test_exec_piped() {
  test_count=$((test_count + 1))
  setup_test
  # --dry-run is non-destructive; run with a throwaway HOME so inventory is
  # empty and nothing outside /tmp is touched.
  out=$(
    HOME="$test_dir" \
    timeout_guard 30 sh uninstall-complete.sh --dry-run 2>&1
  )
  ec=$?
  if [ "$ec" -ne 0 ]; then
    printf 'FAIL - uninstall-complete.sh --dry-run exit=%s\n%s\n' "$ec" "$out"
    fail "uninstall-complete.sh --dry-run exits 0"
  elif printf '%s' "$out" | grep -q 'invalid option'; then
    fail "uninstall-complete.sh --dry-run hits set: invalid option (CRLF)"
  elif printf '%s' "$out" | grep -qE 'Dry-run only|COMPLETE-UNINSTALL OK'; then
    pass "uninstall-complete.sh --dry-run completes (exit 0, dry-run marker)"
  else
    fail "uninstall-complete.sh --dry-run completed but missing OK marker"
  fi
  teardown_test
}

# ============================================================================
# Main
# ============================================================================

main() {
  test_no_cr
  test_sh_syntax
  test_exec_piped

  printf '\n%d tests, %d passed, %d failed\n' \
    "$test_count" "$pass_count" "$fail_count"

  if [ "$fail_count" -ne 0 ]; then
    exit 1
  fi
}

main "$@"
