#!/bin/sh
# TenetX complete client cleanup — macOS / Linux (shareable one-click).
#
#   # Inventory only (safe default)
#   curl -fsSL <URL>/uninstall-complete.sh | sh
#
#   # Destructive wipe
#   curl -fsSL <URL>/uninstall-complete.sh | sh -s -- --force
#   # or: TENETX_FORCE=1 curl -fsSL <URL>/uninstall-complete.sh | sh
#
# Parity with local-stacks/runners/complete_uninstall.py.
# On Windows use uninstall-complete.ps1 instead.
#
# Flags: --force | --dry-run | --keep-binary | --skip-revoke | --org <slug>
# Env:   TENETX_FORCE=1, TENETX_CONFIG_DIR, TENETX_INSTALL_DIR
set -eu

say() { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
err() { printf 'tenetx uninstall-complete error: %s\n' "$*" >&2; exit 1; }

FORCE=0
DRY_RUN=0
KEEP_BINARY=0
SKIP_REVOKE=0
ORG=""

case "${TENETX_FORCE:-}" in
  1|true|TRUE|yes|YES) FORCE=1 ;;
esac

while [ "$#" -gt 0 ]; do
  case "$1" in
    --force|-f) FORCE=1; shift ;;
    --dry-run) DRY_RUN=1; FORCE=1; shift ;;
    --keep-binary) KEEP_BINARY=1; shift ;;
    --skip-revoke) SKIP_REVOKE=1; shift ;;
    --org)
      [ "$#" -ge 2 ] || err "--org requires a slug"
      ORG="$2"
      shift 2
      ;;
    --help|-h)
      say "Usage: uninstall-complete.sh [--force|--dry-run] [--keep-binary] [--skip-revoke] [--org SLUG]"
      say "  Default (no --force): inventory only."
      say "  TENETX_FORCE=1 is equivalent to --force."
      exit 0
      ;;
    *) err "unknown flag: $1 (try --help)" ;;
  esac
done

os=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$os" in
  darwin|linux) : ;;
  *) err "unsupported OS '$os' — on Windows run uninstall-complete.ps1" ;;
esac

HOME_DIR="${HOME:-}"
[ -n "$HOME_DIR" ] || err "HOME not set"

TENETX_DIR="${TENETX_CONFIG_DIR:-$HOME_DIR/.tenetx}"
HAD_ERROR=0
ACTIONS=0

note() {
  ACTIONS=$((ACTIONS + 1))
  if [ "$DRY_RUN" -eq 1 ]; then
    say "  [dry-run] $*"
  else
    say "  $*"
  fi
}

# Print existing binary paths (deduped). install.sh + Homebrew + which.
list_binaries() {
  {
    if [ -n "${TENETX_INSTALL_DIR:-}" ]; then
      printf '%s\n' "${TENETX_INSTALL_DIR%/}/tenetx"
    fi
    printf '%s\n' /usr/local/bin/tenetx
    printf '%s\n' /opt/homebrew/bin/tenetx
    printf '%s\n' "$HOME_DIR/.local/bin/tenetx"
    if command -v tenetx >/dev/null 2>&1; then
      command -v tenetx
    fi
  } | awk 'NF && !seen[$0]++' | while IFS= read -r p; do
    if [ -e "$p" ] || [ -L "$p" ]; then
      printf '%s\n' "$p"
    fi
  done
}

find_tenetx() {
  if command -v tenetx >/dev/null 2>&1; then
    command -v tenetx
    return 0
  fi
  for c in /usr/local/bin/tenetx /opt/homebrew/bin/tenetx "$HOME_DIR/.local/bin/tenetx"; do
    if [ -x "$c" ]; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  if [ -n "${TENETX_INSTALL_DIR:-}" ] && [ -x "${TENETX_INSTALL_DIR%/}/tenetx" ]; then
    printf '%s\n' "${TENETX_INSTALL_DIR%/}/tenetx"
    return 0
  fi
  return 1
}

inventory() {
  label="$1"
  say ""
  say "=== inventory $label ==="
  say "HOME=$HOME_DIR"
  if [ -d "$TENETX_DIR" ]; then
    n=$(find "$TENETX_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
    say "TENETX_DIR=$TENETX_DIR exists=yes files=$n"
    find "$TENETX_DIR" -type f 2>/dev/null | head -40 | while IFS= read -r f; do
      say "  $f"
    done
  else
    say "TENETX_DIR=$TENETX_DIR exists=no"
  fi

  say "binaries:"
  bins=$(list_binaries || true)
  if [ -z "$bins" ]; then
    say "  (none)"
  else
    printf '%s\n' "$bins" | while IFS= read -r b; do
      [ -n "$b" ] || continue
      say "  $b"
    done
  fi
  if command -v tenetx >/dev/null 2>&1; then
    say "tenetx on PATH=$(command -v tenetx)"
  else
    say "tenetx on PATH=no"
  fi

  for pair in \
    "claude_code|$HOME_DIR/.claude/hooks" \
    "cursor|$HOME_DIR/.cursor/hooks" \
    "windsurf|$HOME_DIR/.windsurf/hooks" \
    "codex|$TENETX_DIR/hooks/codex" \
    "copilot|$HOME_DIR/.copilot/hooks"
  do
    name=${pair%%|*}
    hooks=${pair#*|}
    found=""
    for g in tenetx-guard.py tenetx-guard.sh tenetx-guard.cmd .tenetx-guard.json .update-state.json; do
      if [ -e "$hooks/$g" ]; then
        found="$found $hooks/$g"
      fi
    done
    for sub in versions current; do
      if [ -e "$hooks/$sub" ]; then
        found="$found $hooks/$sub"
      fi
    done
    if [ -n "$found" ]; then
      say "IDE $name:$found"
    fi
  done
}

run_product_cli() {
  tenetx_bin=""
  tenetx_bin=$(find_tenetx || true)
  if [ -z "$tenetx_bin" ]; then
    warn "tenetx not on PATH and binary missing — skip product logout/uninstall"
    return 0
  fi

  if [ "$SKIP_REVOKE" -eq 0 ]; then
    note "cli: $tenetx_bin logout --revoke"
    if [ "$DRY_RUN" -eq 0 ]; then
      "$tenetx_bin" logout --revoke || warn "logout --revoke exit $? (continuing)"
    fi
  fi

  if [ -n "$ORG" ]; then
    note "cli: $tenetx_bin uninstall --org $ORG"
    if [ "$DRY_RUN" -eq 0 ]; then
      "$tenetx_bin" uninstall --org "$ORG" || warn "uninstall exit $? (continuing)"
    fi
  else
    note "cli: $tenetx_bin uninstall"
    if [ "$DRY_RUN" -eq 0 ]; then
      "$tenetx_bin" uninstall || warn "uninstall exit $? (continuing)"
    fi
  fi
}

scrub_json_hooks() {
  path="$1"
  [ -f "$path" ] || return 0
  if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 missing — skip JSON scrub $path"
    return 0
  fi
  note "json-scrub: $path (hooks)"
  [ "$DRY_RUN" -eq 0 ] || return 0
  python3 - "$path" <<'PY' || warn "JSON hooks scrub failed: $path"
import json, shutil, sys
from pathlib import Path
path = Path(sys.argv[1])
try:
    data = json.loads(path.read_text(encoding="utf-8"))
except Exception as e:
    print(f"skip: {e}", file=sys.stderr)
    sys.exit(0)
if not isinstance(data, dict):
    sys.exit(0)

def is_tx(cmd):
    return isinstance(cmd, str) and "tenetx-guard" in cmd.lower()

def scrub_hooks(hooks):
    changed = False
    if not isinstance(hooks, dict):
        return False
    for key, val in list(hooks.items()):
        if isinstance(val, list):
            new_arr = []
            for item in val:
                if isinstance(item, dict) and is_tx(item.get("command")):
                    changed = True
                    continue
                if isinstance(item, dict) and isinstance(item.get("hooks"), list):
                    nested = []
                    for h in item["hooks"]:
                        if isinstance(h, dict) and is_tx(h.get("command")):
                            changed = True
                            continue
                        nested.append(h)
                    if not nested:
                        changed = True
                        continue
                    item = dict(item)
                    item["hooks"] = nested
                new_arr.append(item)
            hooks[key] = new_arr
        elif isinstance(val, dict) and is_tx(val.get("command")):
            del hooks[key]
            changed = True
    return changed

changed = False
hooks = data.get("hooks")
if isinstance(hooks, dict):
    changed = scrub_hooks(hooks) or changed
if not changed:
    sys.exit(0)
backup = path.with_name(path.name + ".tenetx-complete-uninstall-backup")
if not backup.exists():
    shutil.copy2(path, backup)
path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
}

scrub_json_mcp() {
  path="$1"
  [ -f "$path" ] || return 0
  if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 missing — skip MCP scrub $path"
    return 0
  fi
  note "json-scrub: $path (mcp)"
  [ "$DRY_RUN" -eq 0 ] || return 0
  python3 - "$path" <<'PY' || warn "JSON mcp scrub failed: $path"
import json, shutil, sys
from pathlib import Path
path = Path(sys.argv[1])
MARKERS = ("tenetx_proxy_token=", ".tenetx/", ".tenetx.", "tenetx-ask")
try:
    data = json.loads(path.read_text(encoding="utf-8"))
except Exception as e:
    print(f"skip: {e}", file=sys.stderr)
    sys.exit(0)
if not isinstance(data, dict):
    sys.exit(0)
servers = data.get("mcpServers")
if not isinstance(servers, dict):
    sys.exit(0)
changed = False
for name in list(servers.keys()):
    nl = name.lower().strip()
    if nl.startswith("tenetx") or nl.endswith("(tenetx)"):
        del servers[name]
        changed = True
        continue
    try:
        text = json.dumps(servers[name]).lower()
    except Exception:
        continue
    if any(m in text for m in MARKERS):
        del servers[name]
        changed = True
if not changed:
    sys.exit(0)
backup = path.with_name(path.name + ".tenetx-complete-uninstall-backup")
if not backup.exists():
    shutil.copy2(path, backup)
path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
}

remove_guard_dir() {
  hooks="$1"
  [ -d "$hooks" ] || return 0
  for g in tenetx-guard.py tenetx-guard.sh tenetx-guard.cmd .tenetx-guard.json .update-state.json; do
    p="$hooks/$g"
    if [ -e "$p" ]; then
      note "delete: $p"
      if [ "$DRY_RUN" -eq 0 ]; then
        rm -f "$p" || { warn "delete failed $p"; HAD_ERROR=1; }
      fi
    fi
  done
  for sub in versions current; do
    p="$hooks/$sub"
    if [ -e "$p" ]; then
      note "rmtree: $p"
      if [ "$DRY_RUN" -eq 0 ]; then
        rm -rf "$p" || { warn "rmtree failed $p"; HAD_ERROR=1; }
      fi
    fi
  done
  legacy="$hooks/hooks.json"
  if [ -e "$legacy" ]; then
    note "delete: $legacy (legacy hooks.json under hooks/)"
    if [ "$DRY_RUN" -eq 0 ]; then
      rm -f "$legacy" || { warn "delete failed $legacy"; HAD_ERROR=1; }
    fi
  fi
}

hard_wipe() {
  remove_guard_dir "$HOME_DIR/.claude/hooks"
  scrub_json_hooks "$HOME_DIR/.claude/settings.json"
  scrub_json_mcp "$HOME_DIR/.claude.json"

  remove_guard_dir "$HOME_DIR/.cursor/hooks"
  scrub_json_hooks "$HOME_DIR/.cursor/hooks.json"
  scrub_json_mcp "$HOME_DIR/.cursor/mcp.json"

  remove_guard_dir "$HOME_DIR/.windsurf/hooks"
  scrub_json_hooks "$HOME_DIR/.windsurf/mcp.json"
  scrub_json_mcp "$HOME_DIR/.windsurf/mcp.json"

  remove_guard_dir "$TENETX_DIR/hooks/codex"
  scrub_json_hooks "$HOME_DIR/.codex/hooks.json"

  remove_guard_dir "$HOME_DIR/.copilot/hooks"
  scrub_json_hooks "$HOME_DIR/.copilot/hooks/notification-hooks.json"

  toml="$HOME_DIR/.codex/config.toml"
  if [ -f "$toml" ] && command -v python3 >/dev/null 2>&1; then
    note "toml-scrub: $toml"
    if [ "$DRY_RUN" -eq 0 ]; then
      python3 - "$toml" <<'PY' || warn "codex toml scrub failed"
import re, shutil, sys
from pathlib import Path
path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
MARKERS = ("tenetx_proxy_token=", ".tenetx/", ".tenetx.", "tenetx-ask")
parts = re.split(r"(?=^\s*\[)", text, flags=re.MULTILINE)
kept, removed = [], 0
for part in parts:
    m = re.match(r"^\s*\[([^\]]+)\]", part)
    if not m:
        kept.append(part)
        continue
    header = m.group(1).strip().lower()
    body_l = part.lower()
    is_mcp = header.startswith("mcp_servers.")
    tenetxish = (
        "tenetx" in header
        or header.endswith("(tenetx)")
        or any(x in body_l for x in MARKERS)
    )
    if is_mcp and tenetxish:
        removed += 1
        continue
    kept.append(part)
if removed == 0:
    sys.exit(0)
backup = path.with_name(path.name + ".tenetx-complete-uninstall-backup")
if not backup.exists():
    shutil.copy2(path, backup)
path.write_text("".join(kept), encoding="utf-8")
PY
    fi
  elif [ -f "$toml" ]; then
    warn "python3 missing — skip codex toml scrub"
  fi

  if [ -e "$TENETX_DIR" ]; then
    note "rmtree: $TENETX_DIR (full ~/.tenetx wipe)"
    if [ "$DRY_RUN" -eq 0 ]; then
      rm -rf "$TENETX_DIR" || { warn "rmtree $TENETX_DIR failed"; HAD_ERROR=1; }
    fi
  fi
}

remove_binaries() {
  if [ "$KEEP_BINARY" -eq 1 ]; then
    warn "--keep-binary: leaving CLI binary"
    return 0
  fi
  bins=$(list_binaries || true)
  [ -n "$bins" ] || return 0
  # Avoid pipeline subshell so HAD_ERROR sticks
  old_ifs=$IFS
  IFS='
'
  for b in $bins; do
    IFS=$old_ifs
    [ -n "$b" ] || continue
    note "delete: $b"
    if [ "$DRY_RUN" -eq 0 ]; then
      if ! rm -f "$b" 2>/dev/null; then
        warn "delete failed $b (try sudo if under /usr/local/bin)"
        HAD_ERROR=1
      fi
    fi
  done
  IFS=$old_ifs
}

check_residuals() {
  fail=0
  if [ -d "$TENETX_DIR" ]; then
    n=$(find "$TENETX_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
    if [ "$n" != "0" ]; then
      say "residual: $TENETX_DIR still has $n files"
      fail=1
    fi
  fi
  if [ "$KEEP_BINARY" -eq 0 ]; then
    bins=$(list_binaries || true)
    if [ -n "$bins" ]; then
      printf '%s\n' "$bins" | while IFS= read -r b; do
        [ -n "$b" ] || continue
        say "residual binary: $b"
      done
      fail=1
    fi
  fi
  for hooks in \
    "$HOME_DIR/.claude/hooks" \
    "$HOME_DIR/.cursor/hooks" \
    "$HOME_DIR/.windsurf/hooks" \
    "$HOME_DIR/.copilot/hooks"
  do
    for g in tenetx-guard.py tenetx-guard.sh tenetx-guard.cmd .tenetx-guard.json .update-state.json; do
      if [ -e "$hooks/$g" ]; then
        say "residual guard: $hooks/$g"
        fail=1
      fi
    done
  done
  return "$fail"
}

# --- main ---
inventory before

if [ "$FORCE" -eq 0 ]; then
  say ""
  say "Inventory only — no changes made."
  say "Re-run with --force (or TENETX_FORCE=1) to wipe:"
  say "  curl -fsSL <URL>/uninstall-complete.sh | sh -s -- --force"
  say "  # or locally:"
  say "  sh uninstall-complete.sh --force"
  exit 0
fi

say ""
say "--- product CLI ---"
run_product_cli

say ""
say "--- hard wipe ---"
hard_wipe
remove_binaries

say ""
say "--- actions noted: $ACTIONS ---"

inventory after

if [ "$DRY_RUN" -eq 1 ]; then
  say ""
  say "Dry-run only — no changes applied."
  exit 0
fi

if [ "$HAD_ERROR" -ne 0 ]; then
  say ""
  say "COMPLETE-UNINSTALL INCOMPLETE — errors during wipe"
  exit 1
fi

if ! check_residuals; then
  say ""
  say "COMPLETE-UNINSTALL INCOMPLETE — residuals remain"
  exit 1
fi

say ""
say "COMPLETE-UNINSTALL OK"
exit 0
