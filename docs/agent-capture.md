# Agent capture enable / disable / reset

Long-form guide for managing `TENETX_AGENT_CAPTURE` on client machines.

## What is agent capture?

Agent capture is a debugging feature that records hook execution context (tool calls, policy decisions, environment state) for analysis. It's controlled by the `TENETX_AGENT_CAPTURE` environment variable:

```python
# In installed hooks
os.environ.get("TENETX_AGENT_CAPTURE", "<baked-default>") == "1"
```

The baked default is set at hook install time based on server `TENETX_CAPTURE_ORGS`. If your org wasn't in that list, the default is `0` (disabled). This script lets you override that without reinstalling hooks.

## When to use this

- **Debugging policy decisions** — Enable capture to see why an action was blocked or allowed.
- **Reproducing issues** — Capture context helps QA and engineering trace problems.
- **Temporary troubleshooting** — Enable for a session, then disable when done.

## Three states

The script manages three distinct states:

### Enable (set to 1)

```bash
./enable-agent-capture.sh enable
```

```powershell
.\enable-agent-capture.ps1 -Enable
```

Sets `TENETX_AGENT_CAPTURE=1` in:
- Current process environment
- User environment (durable across shell restarts)
- launchctl (macOS, for GUI agents)

### Disable (set to 0)

```bash
./enable-agent-capture.sh disable
```

```powershell
.\enable-agent-capture.ps1 -Disable
```

Sets `TENETX_AGENT_CAPTURE=0` (explicit false, not unset). This is distinct from reset. Use this to override a baked-in default of `1`.

### Reset (remove entirely)

```bash
./enable-agent-capture.sh reset
```

```powershell
.\enable-agent-capture.ps1 -Reset
```

Removes the variable from User environment and unsets it in the current process. The next shell will use the baked-in default.

### Status (show current state)

```bash
./enable-agent-capture.sh status
```

```powershell
.\enable-agent-capture.ps1 -Status
```

Prints the current value from:
- Process environment
- User environment (Windows) / shell-rc files (macOS / Linux)
- Baked-in defaults from installed hooks (if found)

## Action resolution

The script chooses an action in this order:

1. **CLI arguments** (highest priority) — `-Enable`, `-Disable`, `-Status`, `-Reset`, `-Help`
2. **Environment variable** — `TENETX_CAPTURE_ACTION=enable|disable|status|reset|help`
3. **Interactive menu** — If TTY is available and not in a piped/non-interactive context
4. **Default** — Status (show current state; never defaults to enable)

This safety-first approach ensures non-interactive contexts (CI/CD, piped stdin, `-NonInteractive` flag) never accidentally enable capture.

## Usage patterns

### Quick enable (one-liner)

```bash
TENETX_CAPTURE_ACTION=enable ./enable-agent-capture.sh
```

```powershell
$env:TENETX_CAPTURE_ACTION = 'enable'; .\enable-agent-capture.ps1
```

### Check current state

```bash
./enable-agent-capture.sh status
```

```powershell
.\enable-agent-capture.ps1 -Status
```

### Dry-run (see what would change)

```bash
TENETX_CAPTURE_DRY_RUN=1 TENETX_CAPTURE_ACTION=enable ./enable-agent-capture.sh
```

```powershell
$env:TENETX_CAPTURE_DRY_RUN = '1'
$env:TENETX_CAPTURE_ACTION = 'enable'
.\enable-agent-capture.ps1
```

Output will show `WOULD_SET process=1`, `WOULD_SET User=1`, etc. without making changes.

### Interactive menu

```bash
./enable-agent-capture.sh
```

```powershell
.\enable-agent-capture.ps1
```

If a TTY is available, the script shows a menu:

```
TenetX agent capture control
==========================
1. Status (show current state)
2. Enable
3. Disable
4. Reset
5. Help
6. Exit

Select action [1-6]:
```

## Platform specifics

### macOS / Linux

The script manages shell-rc files:
- `$HOME/.profile`
- `$HOME/.bashrc`
- `$HOME/.zshrc`

It uses exact markers to find and replace the variable:

```bash
# >>> TENETX_AGENT_CAPTURE >>>
export TENETX_AGENT_CAPTURE=1
# <<< TENETX_AGENT_CAPTURE <<<
```

If the markers exist, the script replaces them in-place. If not, it appends at EOF.

On macOS, the script also manages launchctl:

```bash
launchctl setenv TENETX_AGENT_CAPTURE 1
```

This makes the variable available to GUI agents launched after the command.

### Windows

The script uses `[Environment]::SetEnvironmentVariable()` to set User environment variables. These are durable and visible in new PowerShell sessions.

```powershell
[Environment]::SetEnvironmentVariable('TENETX_AGENT_CAPTURE', '1', 'User')
```

The script also sets the process environment for the current session.

## Restart agents after changes

Coding agents (Cursor, Claude, Codex, Copilot) inherit the environment at startup. After running this script, restart your agent so hook child processes pick up the updated `TENETX_AGENT_CAPTURE` value.

## Troubleshooting

### Script says "No shell-rc files found" (macOS / Linux)

The script looks for `.profile`, `.bashrc`, or `.zshrc` in your home directory. If none exist, it creates `.profile` and writes to that.

If you use a different shell (e.g., fish, tcsh), you may need to manually add the export:

```bash
export TENETX_AGENT_CAPTURE=1
```

### launchctl setenv fails (macOS)

This usually means you're running the script in a restricted context (e.g., Docker, SSH session). The script will still set the variable in shell-rc files and the current process.

### Status shows different values across layers

This can happen if you've set the variable in multiple places (e.g., `.profile` and `.bashrc` with different values). The script will warn you and suggest running `reset` to clean up.

## Background

This script is a workaround for TENQA-75 (product server gap). Once server-side `TENETX_CAPTURE_ORGS` is available, capture can be controlled without client-side scripts.
