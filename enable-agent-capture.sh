#!/bin/sh
#
# enable-agent-capture.sh — TENETX_AGENT_CAPTURE lifecycle manager
#
# Manages TENETX_AGENT_CAPTURE (1=enabled, 0=disabled) across:
#   - Shell-rc files (.profile, .bashrc, .zshrc)
#   - Process environment
#   - launchctl (macOS)
#
# Action resolution: CLI args → TENETX_CAPTURE_ACTION env → interactive menu → status
#
# Usage:
#   ./enable-agent-capture.sh [enable|disable|status|reset|help]
#   TENETX_CAPTURE_ACTION=enable ./enable-agent-capture.sh
#   ./enable-agent-capture.sh (interactive menu if TTY)
#

set -u

# ============================================================================
# ANSI Color Support
# ============================================================================

enable_color() {
  if [ -t 1 ]; then
    RESET='\033[0m'
    BOLD='\033[1m'
    RED='\033[31m'
    GREEN='\033[32m'
    YELLOW='\033[33m'
    BLUE='\033[34m'
    MAGENTA='\033[35m'
  else
    RESET=''
    BOLD=''
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    MAGENTA=''
  fi
}

# ============================================================================
# Utility Functions
# ============================================================================

info() {
  printf "${BLUE}ℹ${RESET} %s\n" "$1" >&2
}

success() {
  printf "${GREEN}✓${RESET} %s\n" "$1" >&2
}

warn() {
  printf "${YELLOW}⚠${RESET} %s\n" "$1" >&2
}

error() {
  printf "${RED}✗${RESET} %s\n" "$1" >&2
}

die() {
  error "$1"
  exit 1
}

# ============================================================================
# Shell-RC Helpers
# ============================================================================

get_shellrc_files() {
  local files=""
  if [ -f "$HOME/.profile" ]; then
    files="$files $HOME/.profile"
  fi
  if [ -f "$HOME/.bashrc" ]; then
    files="$files $HOME/.bashrc"
  fi
  if [ -f "$HOME/.zshrc" ]; then
    files="$files $HOME/.zshrc"
  fi
  echo "$files" | xargs
}

get_or_create_profile() {
  if [ ! -f "$HOME/.profile" ]; then
    touch "$HOME/.profile"
    chmod 600 "$HOME/.profile"
    info "Created $HOME/.profile"
  fi
  echo "$HOME/.profile"
}

get_marker_start() {
  echo "# >>> TENETX_AGENT_CAPTURE >>>"
}

get_marker_end() {
  echo "# <<< TENETX_AGENT_CAPTURE <<<"
}

build_rc_block() {
  local value="$1"
  local marker_start
  local marker_end
  marker_start=$(get_marker_start)
  marker_end=$(get_marker_end)
  
  cat <<EOF
$marker_start
export TENETX_AGENT_CAPTURE=$value
$marker_end
EOF
}

# Writes or replaces marked block in a shell-rc file
write_rc_block() {
  local filepath="$1"
  local value="$2"
  local marker_start
  local marker_end
  local new_block
  local content
  
  marker_start=$(get_marker_start)
  marker_end=$(get_marker_end)
  new_block=$(build_rc_block "$value")
  
  if [ -f "$filepath" ]; then
    # Check if block already exists
    if grep -q "$(echo "$marker_start" | sed 's/[[\.*^$/]/\\&/g')" "$filepath"; then
      # Replace existing block
      # Extract everything before marker, the new block, and everything after marker
      content=$(cat "$filepath")
      # Use a temp file for safety
      tmp=$(mktemp)
      {
        echo "$content" | sed "/$marker_start/,/$marker_end/d" | grep -v "^$"
        printf '%s\n' "$new_block"
      } > "$tmp"
      mv "$tmp" "$filepath"
    else
      # Append new block
      printf '\n%s\n' "$new_block" >> "$filepath"
    fi
  else
    # Create file with block
    printf '%s\n' "$new_block" > "$filepath"
    chmod 600 "$filepath"
  fi
}

# Read the value from a marked block in a shell-rc file
read_rc_value() {
  local filepath="$1"
  
  if [ ! -f "$filepath" ]; then
    echo ""
    return
  fi
  
  # Extract the export line from within the markers
  sed -n '/# >>> TENETX_AGENT_CAPTURE >>>/,/# <<< TENETX_AGENT_CAPTURE <</p' "$filepath" | \
    grep '^export TENETX_AGENT_CAPTURE=' | \
    sed 's/^export TENETX_AGENT_CAPTURE=//'
}

# Remove marked block from a shell-rc file
remove_rc_block() {
  local filepath="$1"
  
  if [ ! -f "$filepath" ]; then
    return
  fi
  
  if grep -q "$(get_marker_start | sed 's/[[\.*^$/]/\\&/g')" "$filepath"; then
    tmp=$(mktemp)
    sed "/$(get_marker_start | sed 's/[[\.*^$/]/\\&/g')/,/$(get_marker_end | sed 's/[[\.*^$/]/\\&/g')/d" "$filepath" > "$tmp"
    mv "$tmp" "$filepath"
  fi
}

# Check if marked block exists in any shell-rc file
rc_block_exists() {
  for f in $(get_shellrc_files); do
    if grep -q "$(get_marker_start | sed 's/[[\.*^$/]/\\&/g')" "$f" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

# ============================================================================
# launchctl Helpers (Darwin)
# ============================================================================

is_darwin() {
  [ "$(uname -s)" = "Darwin" ]
}

launchctl_setenv() {
  local key="$1"
  local value="$2"
  
  if is_darwin; then
    launchctl setenv "$key" "$value" 2>/dev/null || true
  fi
}

launchctl_unsetenv() {
  local key="$1"
  
  if is_darwin; then
    launchctl unsetenv "$key" 2>/dev/null || true
  fi
}

launchctl_getenv() {
  local key="$1"
  
  if is_darwin; then
    launchctl getenv "$key" 2>/dev/null || echo ""
  else
    echo ""
  fi
}

# ============================================================================
# Action: Enable
# ============================================================================

action_enable() {
  info "Enabling TENETX_AGENT_CAPTURE..."
  
  export TENETX_AGENT_CAPTURE=1
  launchctl_setenv TENETX_AGENT_CAPTURE 1
  
  # Write to .profile (create if missing)
  profile=$(get_or_create_profile)
  write_rc_block "$profile" 1
  
  # Write to .bashrc if exists
  if [ -f "$HOME/.bashrc" ]; then
    write_rc_block "$HOME/.bashrc" 1
  fi
  
  # Write to .zshrc if exists
  if [ -f "$HOME/.zshrc" ]; then
    write_rc_block "$HOME/.zshrc" 1
  fi
  
  success "TENETX_AGENT_CAPTURE enabled (value: 1)"
  printf '\nℹ Restart your shell or run:\n'
  printf '  export TENETX_AGENT_CAPTURE=1\n\n'
}

# ============================================================================
# Action: Disable
# ============================================================================

action_disable() {
  info "Disabling TENETX_AGENT_CAPTURE..."
  
  export TENETX_AGENT_CAPTURE=0
  launchctl_setenv TENETX_AGENT_CAPTURE 0
  
  # Write to .profile (create if missing)
  profile=$(get_or_create_profile)
  write_rc_block "$profile" 0
  
  # Write to .bashrc if exists
  if [ -f "$HOME/.bashrc" ]; then
    write_rc_block "$HOME/.bashrc" 0
  fi
  
  # Write to .zshrc if exists
  if [ -f "$HOME/.zshrc" ]; then
    write_rc_block "$HOME/.zshrc" 0
  fi
  
  success "TENETX_AGENT_CAPTURE disabled (value: 0)"
  printf '\nℹ Restart your shell or run:\n'
  printf '  export TENETX_AGENT_CAPTURE=0\n\n'
}

# ============================================================================
# Action: Reset
# ============================================================================

action_reset() {
  info "Resetting TENETX_AGENT_CAPTURE..."
  
  unset TENETX_AGENT_CAPTURE 2>/dev/null || true
  launchctl_unsetenv TENETX_AGENT_CAPTURE
  
  for f in $(get_shellrc_files); do
    remove_rc_block "$f"
  done
  
  success "TENETX_AGENT_CAPTURE reset (removed from shell-rc and launchctl)"
  printf '\nℹ Restart your shell to complete reset.\n\n'
}

# ============================================================================
# Action: Status
# ============================================================================

action_status() {
  local process_val
  local launchctl_val
  local rc_files
  local rc_val
  local block_count
  local marker_start_escaped
  
  printf '\n%s TENETX_AGENT_CAPTURE Status\n' "$BOLD"
  printf '%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n' "$RESET"
  
  # Process environment
  process_val="${TENETX_AGENT_CAPTURE:-}"
  if [ -z "$process_val" ]; then
    printf 'Process Environment: %s(not set)%s\n' "$YELLOW" "$RESET"
  else
    if [ "$process_val" = "1" ]; then
      printf 'Process Environment: %s1 (enabled)%s\n' "$GREEN" "$RESET"
    elif [ "$process_val" = "0" ]; then
      printf 'Process Environment: %s0 (disabled)%s\n' "$YELLOW" "$RESET"
    else
      printf 'Process Environment: %s%s (unexpected value)%s\n' "$RED" "$process_val" "$RESET"
    fi
  fi
  
  # launchctl environment (macOS only)
  if is_darwin; then
    launchctl_val=$(launchctl_getenv TENETX_AGENT_CAPTURE)
    if [ -z "$launchctl_val" ]; then
      printf 'launchctl setenv: %s(not set)%s\n' "$YELLOW" "$RESET"
    else
      if [ "$launchctl_val" = "1" ]; then
        printf 'launchctl setenv: %s1 (enabled)%s\n' "$GREEN" "$RESET"
      elif [ "$launchctl_val" = "0" ]; then
        printf 'launchctl setenv: %s0 (disabled)%s\n' "$YELLOW" "$RESET"
      else
        printf 'launchctl setenv: %s%s (unexpected value)%s\n' "$RED" "$launchctl_val" "$RESET"
      fi
    fi
  fi
  
  # Shell-RC files
  printf '\nShell-RC Files:\n'
  block_count=0
  marker_start_escaped=$(get_marker_start | sed 's/[[\.*^$/]/\\&/g')
  
  for f in $(get_shellrc_files); do
    if grep -q "$marker_start_escaped" "$f" 2>/dev/null; then
      block_count=$((block_count + 1))
      rc_val=$(read_rc_value "$f")
      if [ -z "$rc_val" ]; then
        printf '  %s: %s(block present, no value)%s\n' "$f" "$YELLOW" "$RESET"
      else
        if [ "$rc_val" = "1" ]; then
          printf '  %s: %s1 (enabled)%s\n' "$f" "$GREEN" "$RESET"
        elif [ "$rc_val" = "0" ]; then
          printf '  %s: %s0 (disabled)%s\n' "$f" "$YELLOW" "$RESET"
        else
          printf '  %s: %s%s (unexpected value)%s\n' "$f" "$RED" "$rc_val" "$RESET"
        fi
      fi
    fi
  done
  
  if [ "$block_count" -eq 0 ]; then
    printf '  %s(no marked blocks found)%s\n' "$YELLOW" "$RESET"
  fi
  
  # Guard hooks scanning
  printf '\nGuard Hooks:\n'
  local guard_found=0
  local guard_paths="$HOME/.claude/hooks/tenetx-guard.py $HOME/.cursor/hooks/tenetx-guard.py $HOME/.windsurf/hooks/tenetx-guard.py $HOME/.tenetx/hooks/codex/tenetx-guard.py $HOME/.copilot/hooks/tenetx-guard.py"
  
  for guard_path in $guard_paths; do
    if [ -f "$guard_path" ]; then
      guard_found=1
      # Search for TENETX_AGENT_CAPTURE with baked default
      local baked=$(grep -o 'TENETX_AGENT_CAPTURE["'"'"']?\s*,\s*['"'"'"][01]['"'"'"]' "$guard_path" 2>/dev/null | head -1)
      if [ -n "$baked" ]; then
        local baked_val=$(echo "$baked" | grep -o '[01]')
        if [ "$baked_val" = "1" ]; then
          printf '  %s: %sbaked default=1 (enabled)%s\n' "$guard_path" "$GREEN" "$RESET"
        else
          printf '  %s: %sbaked default=0 (disabled)%s\n' "$guard_path" "$YELLOW" "$RESET"
        fi
      else
        printf '  %s: %s(no baked default found)%s\n' "$guard_path" "$YELLOW" "$RESET"
      fi
    fi
  done
  
  if [ "$guard_found" -eq 0 ]; then
    warn "No guard hooks found in expected locations"
  fi
  
  # Restart message
  printf '\n%s Note:%s Shell restart required for changes to take effect.\n' "$BOLD" "$RESET"
  printf 'Cannot verify server connectivity or auth token.\n'
  printf '\n'
}

# ============================================================================
# Action: Help
# ============================================================================

action_help() {
  cat <<'EOF'

enable-agent-capture.sh — TENETX Agent Capture Lifecycle Manager

USAGE:
  ./enable-agent-capture.sh [ACTION]

ACTIONS:
  enable        Set TENETX_AGENT_CAPTURE=1 (enable capture)
  disable       Set TENETX_AGENT_CAPTURE=0 (disable capture)
  status        Display current capture configuration
  reset         Remove capture configuration and unset variables
  help          Show this help message

ENVIRONMENT:
  TENETX_CAPTURE_ACTION    Override action (enable|disable|status|reset|help)
  HOME                      Home directory for shell-rc files

NOTES:
  - If no ACTION is given and no TENETX_CAPTURE_ACTION is set, an interactive
    menu is displayed (if TTY is available; otherwise defaults to 'status').
  - Shell-rc blocks are marked with:
      # >>> TENETX_AGENT_CAPTURE >>>
      # <<< TENETX_AGENT_CAPTURE <<<
  - On macOS, launchctl is updated alongside shell-rc files.
  - Changes require shell restart to take effect.

EOF
}

# ============================================================================
# Interactive Menu
# ============================================================================

interactive_menu() {
  # Try to reattach /dev/tty if possible
  if [ -e /dev/tty ]; then
    exec 0</dev/tty 2>/dev/null || true
  fi
  
  # Check if we actually have a TTY after reattach attempt
  if ! [ -t 0 ]; then
    info "No TTY available, defaulting to 'status'"
    action_status
    return
  fi
  
  local choice
  local attempts=0
  
  while true; do
    printf '\n%s Agent Capture Menu\n' "$BOLD"
    printf '%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n' "$RESET"
    printf '1) Status\n'
    printf '2) Enable\n'
    printf '3) Disable\n'
    printf '4) Reset\n'
    printf '5) Exit\n'
    printf '\n%sChoose an option [1-5]:%s ' "$BOLD" "$RESET"
    
    if ! read -r choice; then
      error "Failed to read input"
      return 1
    fi
    
    case "$choice" in
      1) action_status; return ;;
      2) action_enable; return ;;
      3) action_disable; return ;;
      4) action_reset; return ;;
      5) info "Exiting"; return ;;
      *)
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 1 ]; then
          error "Invalid choice, exiting"
          return 1
        fi
        error "Invalid choice, please try again"
        ;;
    esac
  done
}

# ============================================================================
# Main
# ============================================================================

main() {
  enable_color
  
  local action=""
  
  # 1. CLI argument takes precedence
  if [ $# -gt 0 ]; then
    action="$1"
  # 2. Environment variable
  elif [ -n "${TENETX_CAPTURE_ACTION:-}" ]; then
    action="$TENETX_CAPTURE_ACTION"
  # 3. Try interactive menu
  elif [ -t 0 ] || [ -e /dev/tty ]; then
    interactive_menu
    return $?
  # 4. Default to status
  else
    action="status"
  fi
  
  # Execute action
  case "$action" in
    enable)
      action_enable
      ;;
    disable)
      action_disable
      ;;
    status)
      action_status
      ;;
    reset)
      action_reset
      ;;
    help)
      action_help
      ;;
    *)
      error "Unknown action: $action"
      printf 'Run: %s --help\n' "$0"
      exit 1
      ;;
  esac
}

main "$@"
