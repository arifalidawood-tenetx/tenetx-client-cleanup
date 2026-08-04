# TenetX client cleanup (public)

Public, shareable scripts for TenetX client wipe and agent capture control. These tools go beyond product `tenetx uninstall` (partial by design — binary and credential leftovers can remain).

## Overview

This repository contains two main tools:

1. **Uninstall complete** — Full client wipe (inventory, dry-run, or destructive)
2. **Enable agent capture** — Manage `TENETX_AGENT_CAPTURE` for local debugging (sh/ps1)

Both scripts are self-contained, portable, and designed for QA, support, and end-user troubleshooting.

## Wipe (uninstall-complete)

Removes TenetX client artifacts beyond the product's built-in uninstall.

**Safety**
- Default run is inventory only (prints what would be removed).
- Destructive wipe requires `--force` / `-Force` (or `TENETX_FORCE=1`).
- Prefer `--dry-run` first on a machine you care about.

### One-liners (release v1.0.0)

**macOS / Linux — inventory:**

```bash
curl -fsSL https://github.com/arifalidawood-tenetx/tenetx-client-cleanup/releases/download/v1.0.0/uninstall-complete.sh | sh
```

**macOS / Linux — wipe:**

```bash
curl -fsSL https://github.com/arifalidawood-tenetx/tenetx-client-cleanup/releases/download/v1.0.0/uninstall-complete.sh | sh -s -- --force
```

**Windows — inventory:**

```powershell
irm https://github.com/arifalidawood-tenetx/tenetx-client-cleanup/releases/download/v1.0.0/uninstall-complete.ps1 | iex
```

**Windows — wipe:**

```powershell
$env:TENETX_FORCE = '1'
irm https://github.com/arifalidawood-tenetx/tenetx-client-cleanup/releases/download/v1.0.0/uninstall-complete.ps1 | iex
```

### Local clone

```bash
sh ./uninstall-complete.sh --dry-run
sh ./uninstall-complete.sh --force
```

```powershell
.\uninstall-complete.ps1 -DryRun
.\uninstall-complete.ps1 -Force
```

## Capture enable (enable-agent-capture)

Manage `TENETX_AGENT_CAPTURE` environment variable to enable / disable / reset agent capture on a client machine. This is a workaround for TENQA-75 (product server gap) until server-side `TENETX_CAPTURE_ORGS` is available.

Capture is gated by installed hooks:
```python
os.environ.get("TENETX_AGENT_CAPTURE", "<baked-default>") == "1"
```

The baked default is usually `0` unless the org was in server `TENETX_CAPTURE_ORGS` at hook install time. This script sets the client override so capture works without reinstalling hooks.

### One-liners (release v1.1.0)

**macOS / Linux — enable:**

```bash
curl -fsSL https://github.com/arifalidawood-tenetx/tenetx-client-cleanup/releases/download/v1.1.0/enable-agent-capture.sh | sh -s -- enable
```

**macOS / Linux — disable:**

```bash
curl -fsSL https://github.com/arifalidawood-tenetx/tenetx-client-cleanup/releases/download/v1.1.0/enable-agent-capture.sh | sh -s -- disable
```

**macOS / Linux — status:**

```bash
curl -fsSL https://github.com/arifalidawood-tenetx/tenetx-client-cleanup/releases/download/v1.1.0/enable-agent-capture.sh | sh -s -- status
```

**Windows — enable:**

```powershell
$env:TENETX_CAPTURE_ACTION = 'enable'
irm https://github.com/arifalidawood-tenetx/tenetx-client-cleanup/releases/download/v1.1.0/enable-agent-capture.ps1 | iex
```

**Windows — disable:**

```powershell
$env:TENETX_CAPTURE_ACTION = 'disable'
irm https://github.com/arifalidawood-tenetx/tenetx-client-cleanup/releases/download/v1.1.0/enable-agent-capture.ps1 | iex
```

**Windows — status:**

```powershell
irm https://github.com/arifalidawood-tenetx/tenetx-client-cleanup/releases/download/v1.1.0/enable-agent-capture.ps1 | iex
```

### Local clone

```bash
./enable-agent-capture.sh enable
./enable-agent-capture.sh disable
./enable-agent-capture.sh status
./enable-agent-capture.sh reset
./enable-agent-capture.sh help
```

```powershell
.\enable-agent-capture.ps1 -Enable
.\enable-agent-capture.ps1 -Disable
.\enable-agent-capture.ps1 -Status
.\enable-agent-capture.ps1 -Reset
.\enable-agent-capture.ps1 -Help
```

### Environment variable: TENETX_CAPTURE_ACTION

Set `TENETX_CAPTURE_ACTION` to choose the action without interactive menu:

```bash
TENETX_CAPTURE_ACTION=enable ./enable-agent-capture.sh
TENETX_CAPTURE_ACTION=disable ./enable-agent-capture.sh
TENETX_CAPTURE_ACTION=status ./enable-agent-capture.sh
TENETX_CAPTURE_ACTION=reset ./enable-agent-capture.sh
```

```powershell
$env:TENETX_CAPTURE_ACTION = 'enable'; .\enable-agent-capture.ps1
$env:TENETX_CAPTURE_ACTION = 'disable'; .\enable-agent-capture.ps1
$env:TENETX_CAPTURE_ACTION = 'status'; .\enable-agent-capture.ps1
$env:TENETX_CAPTURE_ACTION = 'reset'; .\enable-agent-capture.ps1
```

### Disable semantics

Disable writes `0` (not unset) so the variable is explicitly false. This is distinct from reset:

- **Enable**: `TENETX_AGENT_CAPTURE=1` (process + User env / launchctl)
- **Disable**: `TENETX_AGENT_CAPTURE=0` (process + User env / launchctl)
- **Reset**: Remove from User env, unset in process env

### Restart agents after enable/disable/reset

Coding agents (Cursor, Claude, Codex, Copilot) inherit the environment at startup. After running this script, restart your agent so hook child processes pick up the updated `TENETX_AGENT_CAPTURE` value.

## Flags / environment

### Wipe flags

| Flag / env | Effect |
|------------|--------|
| (default) | Inventory only |
| `--force` / `-Force` / `TENETX_FORCE=1` | Full wipe |
| `--dry-run` / `-DryRun` | Plan only (no mutations) |
| `--keep-binary` / `-KeepBinary` | Leave CLI binary |
| `--skip-revoke` / `-SkipRevoke` | Skip `tenetx logout --revoke` |
| `--org SLUG` / `-Org SLUG` | Pass through to `tenetx uninstall --org` |

### Capture flags

| Flag / env | Effect |
|------------|--------|
| `enable` | Enable capture (set to `1`) |
| `disable` | Disable capture (set to `0`) |
| `status` | Show current state (default non-interactive) |
| `reset` | Remove from User env, unset in process |
| `help` | Show usage |
| `TENETX_CAPTURE_ACTION` | Choose action without menu |
| `TENETX_CAPTURE_DRY_RUN=1` | Print what would change (no mutations) |

## Platforms

- **macOS** (10.13+): shell-rc files, launchctl
- **Linux** (glibc 2.17+): shell-rc files (.profile, .bashrc, .zshrc)
- **Windows** (PowerShell 5.1+): User environment variables

## Versions

### v1.1.0 (current)

Adds agent capture enable/disable/reset/status with:
- Three-state semantics: enable (1), disable (0), reset (unset)
- Safety-first action resolution (never defaults to enable in non-interactive contexts)
- Dry-run support (`TENETX_CAPTURE_DRY_RUN=1`)
- Shell-rc file management (.profile, .bashrc, .zshrc)
- launchctl support on macOS
- PowerShell self-contained (no external dependencies)

### Previous versions

**v1.0.0** — Complete client wipe

```bash
curl -fsSL https://github.com/arifalidawood-tenetx/tenetx-client-cleanup/releases/download/v1.0.0/uninstall-complete.sh | sh -s -- --force
```

```powershell
$env:TENETX_FORCE = '1'
irm https://github.com/arifalidawood-tenetx/tenetx-client-cleanup/releases/download/v1.0.0/uninstall-complete.ps1 | iex
```

## Background

QA mirror (private): `arifalidawood-tenetx/tenetx-pms` submodule. This public repo exists so unauthenticated `curl` / `irm` one-liners work. Long-term product CDN: TENQA-71 (`https://tenetx.ai/uninstall-complete.*`).
