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
# Covers all 12 CLI agents (cli-go/internal/ide/ide.go Slugs) + run.sh build-cli
# PATH block/.bak.
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

# Return 0 when the path exists as a file OR a (possibly dangling) symlink.
path_exists() {
  [ -e "$1" ] || [ -L "$1" ]
}

del_file() {
  _p="$1"
  _why="${2:-}"
  path_exists "$_p" || return 0
  if [ -n "$_why" ]; then
    note "delete: $_p ($_why)"
  else
    note "delete: $_p"
  fi
  if [ "$DRY_RUN" -eq 0 ]; then
    rm -f "$_p" || { warn "delete failed $_p"; HAD_ERROR=1; }
  fi
}

del_tree() {
  _t="$1"
  _why="${2:-}"
  path_exists "$_t" || return 0
  if [ -n "$_why" ]; then
    note "rmtree: $_t ($_why)"
  else
    note "rmtree: $_t"
  fi
  if [ "$DRY_RUN" -eq 0 ]; then
    rm -rf "$_t" || { warn "rmtree failed $_t"; HAD_ERROR=1; }
  fi
}

# Remove the markers' block (inclusive) from a text file, leaving every other
# line — including the user's own entries — byte-identical.
strip_marker_block() {
  path="$1"
  begin="$2"
  end="$3"
  [ -f "$path" ] || return 0
  grep -qF "$begin" "$path" 2>/dev/null || return 0
  grep -qF "$end" "$path" 2>/dev/null || return 0
  note "strip-block: $path ($begin)"
  [ "$DRY_RUN" -eq 0 ] || return 0
  backup="$path.tenetx-complete-uninstall-backup"
  [ -e "$backup" ] || cp -p "$path" "$backup" || warn "backup failed $path"
  tmp="$path.tenetx-strip.$$"
  if awk -v s="$begin" -v e="$end" '
    {t=$0; sub(/^[ \t]+/,"",t); sub(/[ \t\r]+$/,"",t)}
    !skip && t==s {skip=1; next}
    skip && t==e {skip=0; next}
    !skip {print}
  ' "$path" > "$tmp" && mv "$tmp" "$path"; then
    :
  else
    rm -f "$tmp"
    warn "strip-block failed $path"
    HAD_ERROR=1
  fi
}

# Scrub a JSON file with a non-hooks shape: "toplevel" drops the top-level
# "tenetx-guard" key (Antigravity), "approvals" drops allowlist rows whose
# command is ours (Hermes shell-hooks-allowlist.json).
scrub_json_misc() {
  path="$1"
  mode="$2"
  [ -f "$path" ] || return 0
  if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 missing — skip JSON scrub $path"
    return 0
  fi
  note "json-scrub: $path ($mode)"
  [ "$DRY_RUN" -eq 0 ] || return 0
  python3 - "$path" "$mode" <<'PY' || warn "JSON scrub failed: $path"
import json, shutil, sys
from pathlib import Path
path = Path(sys.argv[1])
mode = sys.argv[2]
try:
    data = json.loads(path.read_text(encoding="utf-8"))
except Exception as e:
    print(f"skip: {e}", file=sys.stderr)
    sys.exit(0)
if not isinstance(data, dict):
    sys.exit(0)
changed = False
if mode == "toplevel":
    if "tenetx-guard" in data:
        del data["tenetx-guard"]
        changed = True
elif mode == "approvals":
    approvals = data.get("approvals")
    if isinstance(approvals, list):
        kept = [
            a for a in approvals
            if not (isinstance(a, dict) and "tenetx-guard" in str(a.get("command", "")).lower())
        ]
        if len(kept) != len(approvals):
            data["approvals"] = kept
            changed = True
if not changed:
    sys.exit(0)
backup = path.with_name(path.name + ".tenetx-complete-uninstall-backup")
if not backup.exists():
    shutil.copy2(path, backup)
path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
}

# Cline registers hooks by FILE PRESENCE, so ownership is the file's content
# marker. Two discovery roots; the CLI writes only the first.
remove_cline_dispatch() {
  case "$os" in
    darwin|linux) : ;;
    *) return 0 ;;
  esac
  for d in "$HOME_DIR/Documents/Cline/Hooks" "$HOME_DIR/.cline/hooks"; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      [ -f "$f" ] || continue
      if grep -q 'TENETX-CLINE-HOOK' "$f" 2>/dev/null; then
        del_file "$f" "cline dispatch"
      fi
    done
  done
}

# CLI backup residue (cli-go/internal/uninstall/cleanup.go Backups). Our own
# *.tenetx-complete-uninstall-backup and fix-agent-hooks' *.tenetx-bak-* are the
# operators' rollback points and are deliberately kept.
remove_cli_backups() {
  for base in "$@"; do
    for suf in ".tenetx-backup.*" ".tenetx-test-backup.*" ".pre-tenetx-clean.*" ".backup-tenetx-*"; do
      for b in "$base"$suf; do
        del_file "$b"
      done
    done
  done
}

RC_FILES="$HOME_DIR/.zshrc $HOME_DIR/.zprofile $HOME_DIR/.bashrc $HOME_DIR/.bash_profile $HOME_DIR/.profile"
CLI_PATH_MARK_START='# >>> TENETX_CLI_PATH >>>'
CLI_PATH_MARK_END='# <<< TENETX_CLI_PATH <<<'
CODEX_CLI_MARK_START='# >>> TenetX managed Codex CLI >>>'
CODEX_CLI_MARK_END='# <<< TenetX managed Codex CLI <<<'
HERMES_MARK_START='# >>> TENETX GUARD (managed) - do not edit by hand'
HERMES_MARK_END='# <<< TENETX GUARD (managed)'
VIBE_MARK_START='# >>> TENETX MANAGED HOOKS -- do not edit inside this block >>>'
VIBE_MARK_END='# <<< TENETX MANAGED HOOKS <<<'

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
    "copilot|$HOME_DIR/.copilot/hooks" \
    "antigravity|$HOME_DIR/.antigravity/hooks" \
    "qwen_code|$HOME_DIR/.qwen/hooks" \
    "hermes|$HOME_DIR/.hermes/hooks" \
    "augment_code|$HOME_DIR/.augment/hooks" \
    "kiro|$HOME_DIR/.kiro/hooks" \
    "cline|$TENETX_DIR/hooks/cline" \
    "vibe_code|$HOME_DIR/.vibe/hooks"
  do
    name=${pair%%|*}
    hooks=${pair#*|}
    found=""
    for g in tenetx-guard.py tenetx-guard.sh tenetx-guard.cmd tenetx-guard.ps1 .tenetx-guard.json .update-state.json; do
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

remove_guard_files_in() {
  dir="$1"
  [ -d "$dir" ] || return 0
  for g in tenetx-guard.py tenetx-guard.sh tenetx-guard.cmd tenetx-guard.ps1 .tenetx-guard.json .update-state.json; do
    del_file "$dir/$g"
  done
}

remove_guard_dir() {
  hooks="$1"
  [ -d "$hooks" ] || return 0
  remove_guard_files_in "$hooks"
  # Old hook-dir copies may hold unrelated user hooks: remove only our files.
  for d in "$hooks".tenetx-backup.* "$hooks.tenetx-paused"; do
    if [ -d "$d" ]; then
      remove_guard_files_in "$d"
    fi
  done
  for sub in versions current; do
    del_tree "$hooks/$sub"
  done
  # Updater bytecode + wrapper backups (cleanup.go Agent).
  for pat in "tenetx-guard.sh.*" "tenetx-guard.py.*" "tenetx-guard.cmd.*" "tenetx-guard.ps1.*"; do
    for f in "$hooks"/$pat; do
      del_file "$f"
    done
  done
  for f in "$hooks"/__pycache__/tenetx-guard.*; do
    del_file "$f"
  done
}

hard_wipe() {
  # One block per agent; order + paths mirror cli-go/internal/ide/ide.go
  # (layoutBySlug) and hooks.Uninstall. cline/vibe are skipped on Windows only,
  # which this script never runs on.

  # claude_code
  remove_guard_dir "$HOME_DIR/.claude/hooks"
  scrub_json_hooks "$HOME_DIR/.claude/settings.json"
  scrub_json_mcp "$HOME_DIR/.claude.json"

  # cursor
  remove_guard_dir "$HOME_DIR/.cursor/hooks"
  scrub_json_hooks "$HOME_DIR/.cursor/hooks.json"
  scrub_json_mcp "$HOME_DIR/.cursor/mcp.json"
  # Legacy misplaced wiring older builds wrote under hooks/ (cursor only —
  # the CLI does this nowhere else, and other agents' guard dirs may hold a
  # user's own hooks.json).
  del_file "$HOME_DIR/.cursor/hooks/hooks.json" "legacy hooks.json under hooks/"

  # windsurf (Devin)
  remove_guard_dir "$HOME_DIR/.windsurf/hooks"
  scrub_json_hooks "$HOME_DIR/.codeium/windsurf/hooks.json"
  scrub_json_hooks "$HOME_DIR/.config/devin/config.json"
  scrub_json_hooks "$HOME_DIR/.windsurf/settings.json"
  scrub_json_hooks "$HOME_DIR/.windsurf/mcp.json"
  scrub_json_mcp "$HOME_DIR/.windsurf/mcp.json"

  # codex
  remove_guard_dir "$TENETX_DIR/hooks/codex"
  scrub_json_hooks "$HOME_DIR/.codex/hooks.json"

  # copilot
  remove_guard_dir "$HOME_DIR/.copilot/hooks"
  scrub_json_hooks "$HOME_DIR/.copilot/hooks/notification-hooks.json"

  # antigravity — hooks.json is keyed by hook NAME, ours is a single top-level key
  remove_guard_dir "$HOME_DIR/.antigravity/hooks"
  scrub_json_misc "$HOME_DIR/.gemini/config/hooks.json" toplevel

  # qwen_code
  remove_guard_dir "$HOME_DIR/.qwen/hooks"
  scrub_json_hooks "$HOME_DIR/.qwen/settings.json"

  # hermes
  remove_guard_dir "$HOME_DIR/.hermes/hooks"
  strip_marker_block "$HOME_DIR/.hermes/config.yaml" "$HERMES_MARK_START" "$HERMES_MARK_END"
  scrub_json_misc "$HOME_DIR/.hermes/shell-hooks-allowlist.json" approvals

  # augment_code
  remove_guard_dir "$HOME_DIR/.augment/hooks"
  scrub_json_hooks "$HOME_DIR/.augment/settings.json"

  # kiro — tenetx-guard.json holds nothing but our hooks
  remove_guard_dir "$HOME_DIR/.kiro/hooks"
  del_file "$HOME_DIR/.kiro/hooks/tenetx-guard.json"

  # cline — installs by file presence, no settings file
  remove_guard_dir "$TENETX_DIR/hooks/cline"
  remove_cline_dispatch

  # vibe_code
  remove_guard_dir "$HOME_DIR/.vibe/hooks"
  strip_marker_block "$HOME_DIR/.vibe/hooks.toml" "$VIBE_MARK_START" "$VIBE_MARK_END"

  # codex: MCP rows in config.toml, plus adapter-owned rule file + browser skill
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

  del_file "$HOME_DIR/.codex/rules/tenetx.rules" "codex adapter rules"
  del_tree "$HOME_DIR/.agents/skills/tenetx-browser" "codex browser skill"

  # --- shared residue ---
  del_tree "$HOME_DIR/.cache/tenetx"

  # Older builds appended a Codex CLI PATH block pointing into ~/.tenetx/bin,
  # which the wipe below deletes.
  for rc in $RC_FILES; do
    strip_marker_block "$rc" "$CODEX_CLI_MARK_START" "$CODEX_CLI_MARK_END"
  done

  # Every wiring file the table above scrubbed, plus each agent's own config
  # basename (cleanup.go Backups).
  remove_cli_backups \
    "$HOME_DIR/.claude/settings.json" \
    "$HOME_DIR/.claude.json" \
    "$HOME_DIR/.cursor/hooks.json" \
    "$HOME_DIR/.cursor/mcp.json" \
    "$HOME_DIR/.codeium/windsurf/hooks.json" \
    "$HOME_DIR/.config/devin/config.json" \
    "$HOME_DIR/.windsurf/settings.json" \
    "$HOME_DIR/.windsurf/mcp.json" \
    "$HOME_DIR/.codex/hooks.json" \
    "$HOME_DIR/.codex/config.toml" \
    "$HOME_DIR/.copilot/hooks/notification-hooks.json" \
    "$HOME_DIR/.gemini/config/hooks.json" \
    "$HOME_DIR/.qwen/settings.json" \
    "$HOME_DIR/.hermes/config.yaml" \
    "$HOME_DIR/.hermes/shell-hooks-allowlist.json" \
    "$HOME_DIR/.augment/settings.json" \
    "$HOME_DIR/.kiro/hooks/tenetx-guard.json" \
    "$HOME_DIR/.vibe/hooks.toml"

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

  # build-cli keeps one rolling <name>.bak next to the binary.
  for d in "${TENETX_INSTALL_DIR:-}" /usr/local/bin /opt/homebrew/bin "$HOME_DIR/.local/bin"; do
    d="${d%/}"
    [ -n "$d" ] || continue
    del_file "$d/tenetx.bak"
    for f in "$d"/tenetx.*.bak; do
      del_file "$f"
    done
  done

  # build-cli appends our own rc block so the install dir is on PATH.
  for rc in $RC_FILES; do
    strip_marker_block "$rc" "$CLI_PATH_MARK_START" "$CLI_PATH_MARK_END"
  done
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
    "$HOME_DIR/.copilot/hooks" \
    "$HOME_DIR/.antigravity/hooks" \
    "$HOME_DIR/.qwen/hooks" \
    "$HOME_DIR/.hermes/hooks" \
    "$HOME_DIR/.augment/hooks" \
    "$HOME_DIR/.kiro/hooks" \
    "$HOME_DIR/.vibe/hooks"
  do
    for g in tenetx-guard.py tenetx-guard.sh tenetx-guard.cmd tenetx-guard.ps1 .tenetx-guard.json .update-state.json; do
      if [ -e "$hooks/$g" ]; then
        say "residual guard: $hooks/$g"
        fail=1
      fi
    done
  done
  # kiro: the hook definition file is entirely ours
  if [ -e "$HOME_DIR/.kiro/hooks/tenetx-guard.json" ]; then
    say "residual wiring: $HOME_DIR/.kiro/hooks/tenetx-guard.json"
    fail=1
  fi
  # hermes / vibe: sentinel block must be gone
  if [ -f "$HOME_DIR/.hermes/config.yaml" ] && grep -qF "$HERMES_MARK_START" "$HOME_DIR/.hermes/config.yaml" 2>/dev/null; then
    say "residual wiring: $HOME_DIR/.hermes/config.yaml ($HERMES_MARK_START)"
    fail=1
  fi
  if [ -f "$HOME_DIR/.vibe/hooks.toml" ] && grep -qF "$VIBE_MARK_START" "$HOME_DIR/.vibe/hooks.toml" 2>/dev/null; then
    say "residual wiring: $HOME_DIR/.vibe/hooks.toml ($VIBE_MARK_START)"
    fail=1
  fi
  # antigravity: top-level hook name
  if [ -f "$HOME_DIR/.gemini/config/hooks.json" ] && grep -q '"tenetx-guard"' "$HOME_DIR/.gemini/config/hooks.json" 2>/dev/null; then
    say "residual wiring: $HOME_DIR/.gemini/config/hooks.json (tenetx-guard)"
    fail=1
  fi
  # cline: file-presence registration
  for d in "$HOME_DIR/Documents/Cline/Hooks" "$HOME_DIR/.cline/hooks"; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      [ -f "$f" ] || continue
      if grep -q 'TENETX-CLINE-HOOK' "$f" 2>/dev/null; then
        say "residual wiring: $f (cline dispatch)"
        fail=1
      fi
    done
  done
  if [ "$KEEP_BINARY" -eq 0 ]; then
    for rc in $RC_FILES; do
      if [ -f "$rc" ] && grep -qF "$CLI_PATH_MARK_START" "$rc" 2>/dev/null; then
        say "residual wiring: $rc ($CLI_PATH_MARK_START)"
        fail=1
      fi
    done
    for d in "${TENETX_INSTALL_DIR:-}" /usr/local/bin /opt/homebrew/bin "$HOME_DIR/.local/bin"; do
      d="${d%/}"
      [ -n "$d" ] || continue
      for b in "$d/tenetx.bak" "$d"/tenetx.*.bak; do
        if [ -e "$b" ]; then
          say "residual backup: $b"
          fail=1
        fi
      done
    done
  fi
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
