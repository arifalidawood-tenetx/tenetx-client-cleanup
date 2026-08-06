# TenetX client cleanup (public)

Public, shareable scripts for TenetX client wipe, agent capture control, and Windows agent-hook quote repair. These tools go beyond product `tenetx uninstall` (partial by design — binary and credential leftovers can remain).

## Overview

This repository contains three main tools:

1. **Uninstall complete** — Full client wipe (inventory, dry-run, or destructive)
2. **Enable agent capture** — Manage `TENETX_AGENT_CAPTURE` for local debugging (sh/ps1)
3. **Fix agent hooks** — Surgical rewrite of TenetX guard hook command quoting in agent JSON configs (**Windows / PowerShell 7+ only**; no Unix `.sh` counterpart)

All scripts are self-contained, portable, and designed for QA, support, and end-user troubleshooting.

## Wipe (uninstall-complete)

Removes TenetX client artifacts beyond the product's built-in uninstall.

**Safety**
- Default run is inventory only (prints what would be removed).
- Destructive wipe requires `--force` / `-Force` (or `TENETX_FORCE=1`).
- Prefer `--dry-run` first on a machine you care about.

Inventory/wipe includes guard scripts under agent hooks dirs (`tenetx-guard.py` / `.sh` / `.cmd` / `.ps1`) and other `tenetx-*` residue file names. Does **not** touch product-repo `local-stacks/` mirrors.

### One-liners (release v1.3.0)

**macOS / Linux — inventory:**

```bash
curl -fsSL https://github.com/arifalidawood-tenetx/tenetx-client-cleanup/releases/download/v1.3.0/uninstall-complete.sh | sh
```

**macOS / Linux — wipe:**

```bash
curl -fsSL https://github.com/arifalidawood-tenetx/tenetx-client-cleanup/releases/download/v1.3.0/uninstall-complete.sh | sh -s -- --force
```

**Windows — inventory:**

```powershell
irm https://github.com/arifalidawood-tenetx/tenetx-client-cleanup/releases/download/v1.3.0/uninstall-complete.ps1 | iex
```

**Windows — wipe:**

```powershell
$env:TENETX_FORCE = '1'
irm https://github.com/arifalidawood-tenetx/tenetx-client-cleanup/releases/download/v1.3.0/uninstall-complete.ps1 | iex
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

### One-liners (release v1.3.0)

**macOS / Linux — enable:**

```bash
curl -fsSL https://github.com/arifalidawood-tenetx/tenetx-client-cleanup/releases/download/v1.3.0/enable-agent-capture.sh | sh -s -- enable
```

**macOS / Linux — disable:**

```bash
curl -fsSL https://github.com/arifalidawood-tenetx/tenetx-client-cleanup/releases/download/v1.3.0/enable-agent-capture.sh | sh -s -- disable
```

**macOS / Linux — status:**

```bash
curl -fsSL https://github.com/arifalidawood-tenetx/tenetx-client-cleanup/releases/download/v1.3.0/enable-agent-capture.sh | sh -s -- status
```

**Windows — enable:**

```powershell
$env:TENETX_CAPTURE_ACTION = 'enable'
irm https://github.com/arifalidawood-tenetx/tenetx-client-cleanup/releases/download/v1.3.0/enable-agent-capture.ps1 | iex
```

**Windows — disable:**

```powershell
$env:TENETX_CAPTURE_ACTION = 'disable'
irm https://github.com/arifalidawood-tenetx/tenetx-client-cleanup/releases/download/v1.3.0/enable-agent-capture.ps1 | iex
```

**Windows — status:**

```powershell
irm https://github.com/arifalidawood-tenetx/tenetx-client-cleanup/releases/download/v1.3.0/enable-agent-capture.ps1 | iex
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

## Fix agent hooks (fix-agent-hooks.ps1)

**Windows only. Requires PowerShell 7+ (`pwsh`).** There is **no** `fix-agent-hooks.sh` — Unix agents do not need this quoting rewrite (N/A on Unix).

Walks only the `hooks` subtree in agent config JSON and rewrites entries whose *decoded* command ends in `tenetx-guard.cmd`. Leaves `bun` / `claude-mem` / other non-TenetX commands untouched. Non-hook keys stay byte-identical (pre/post SHA256 of the non-hooks object).

**Targets (when selected):**
| Agent | Config path | Default |
|-------|-------------|---------|
| claude | `~/.claude/settings.json` | yes |
| copilot | `~/.copilot/hooks/notification-hooks.json` | yes |
| cursor | `~/.cursor/hooks.json` | `-IncludeCursor` |
| codex | `~/.codex/hooks.json` | `-IncludeCodex` |

### `-Apply` is required to write

Default mode is **dry-run** (plan only; no file writes). You must pass **`-Apply`** to rewrite configs. Each apply creates a sibling backup `*.tenetx-bak-<utc>` before writing. Use `-Revert` to restore from the latest backup.

```powershell
# Dry-run (default) — inspect planned rewrites
pwsh -NoProfile -File .\fix-agent-hooks.ps1

# Apply claude + copilot, then verify
pwsh -NoProfile -File .\fix-agent-hooks.ps1 -Apply -Verify

# Include cursor and/or codex
pwsh -NoProfile -File .\fix-agent-hooks.ps1 -Apply -IncludeCursor -IncludeCodex

# Restore from latest backup
pwsh -NoProfile -File .\fix-agent-hooks.ps1 -Revert -Agents claude,copilot
```

### One-liners (release v1.3.1)

**Windows — dry-run:**

```powershell
irm https://github.com/arifalidawood-tenetx/tenetx-client-cleanup/releases/download/v1.3.1/fix-agent-hooks.ps1 | iex
```

**Windows — apply (claude + copilot defaults):**

```powershell
# Download then apply (iex alone cannot pass -Apply reliably)
irm https://github.com/arifalidawood-tenetx/tenetx-client-cleanup/releases/download/v1.3.1/fix-agent-hooks.ps1 -OutFile fix-agent-hooks.ps1
pwsh -NoProfile -File .\fix-agent-hooks.ps1 -Apply -Verify
```

**Unix:** N/A — `fix-agent-hooks` is Windows-specific (no `.sh`).

### Smoke tests

```powershell
pwsh -NoProfile -File .\tests\smoke-fix-hooks.ps1
```

Requires PowerShell 7+, optional real install paths for decision-body assert (`tests/SCRATCH/payload.json` + Git bash).

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

### Fix-hooks flags (Windows)

| Flag / env | Effect |
|------------|--------|
| (default) | Dry-run (no writes) |
| `-Apply` | Write rewrites (creates `.tenetx-bak-<utc>`) |
| `-Revert` | Restore latest backup |
| `-Verify` | Re-parse + optional guard smoke after apply |
| `-Agents a,b` | Subset: `claude`, `copilot`, `cursor`, `codex` |
| `-IncludeCursor` / `-IncludeCodex` | Add those agents |
| `-NoDedupe` / `TENETX_FIX_HOOKS_DEDUPE=0` | Keep duplicate guard entries (repair quoting only) |
| `TENETX_FIX_HOOKS_HOME` | Override home root (tests / sandbox) |

## Platforms

- **macOS** (10.13+): shell-rc files, launchctl (wipe + capture)
- **Linux** (glibc 2.17+): shell-rc files (.profile, .bashrc, .zshrc)
- **Windows** (PowerShell 5.1+ wipe/capture; **PowerShell 7+** for `fix-agent-hooks.ps1`): User environment variables + agent JSON hooks

## Versions

### v1.3.1 (current)

`fix-agent-hooks.ps1` fix release:

- **Real verify smoke**: post-write bash smoke now runs the decoded command via a temp `.sh` + stdin payload (portable Git-bash discovery, self-contained payload — no machine-specific paths). Fixes the false `smoke-fail exit=127` on Claude (broken nested-quote `-c "..."` argv).
- **Duplicate-guard dedupe**: `-Apply` collapses duplicate TenetX guard entries per event (first wins, matcher-aware); foreign hooks (bun / orca etc.) are never touched and their count is verified. Opt out with `-NoDedupe` / `TENETX_FIX_HOOKS_DEDUPE=0`.
- **Copilot repaired-shape detection**: recognises `"C:\...\tenetx-guard.cmd" eventToken` so re-runs report `skip=N` instead of `rewrite=0 skip=0`, and the guard smoke gets a real sample.
- **Honest status**: a failed verify returns `verify-failed` (structural vs smoke class) instead of throwing and wiping the change count from the summary; guard runtime failures (exit ≠ 0/2/126/127) are warnings, not run failures.

```powershell
# Dry-run
irm https://github.com/arifalidawood-tenetx/tenetx-client-cleanup/releases/download/v1.3.1/fix-agent-hooks.ps1 -OutFile fix-agent-hooks.ps1
pwsh -NoProfile -File .\fix-agent-hooks.ps1

# Apply
pwsh -NoProfile -File .\fix-agent-hooks.ps1 -Apply -Verify
```

**Unix:** `fix-agent-hooks` N/A (Windows-only).

### v1.3.0

All installer one-liners now serve the unified **v1.3.0 asset set** (`fix-agent-hooks.ps1`, `uninstall-complete.ps1` / `.sh`, `enable-agent-capture.ps1` / `.sh`). Publishes the v1.2.0 feature set (`fix-agent-hooks.ps1` + wipe residue sweep) as an actual release:

```powershell
# Dry-run
irm https://github.com/arifalidawood-tenetx/tenetx-client-cleanup/releases/download/v1.3.0/fix-agent-hooks.ps1 -OutFile fix-agent-hooks.ps1
pwsh -NoProfile -File .\fix-agent-hooks.ps1

# Apply
pwsh -NoProfile -File .\fix-agent-hooks.ps1 -Apply -Verify
```

**Unix:** `fix-agent-hooks` N/A (Windows-only).

### Previous versions

**v1.2.0** — Adds Windows `fix-agent-hooks.ps1` (surgical TenetX guard quote rewrite) plus uninstall inventory of `tenetx-guard.ps1` / `tenetx-*` residue. Commands ship in the v1.3.0 asset set:

```powershell
# Uninstall inventory / wipe
irm https://github.com/arifalidawood-tenetx/tenetx-client-cleanup/releases/download/v1.3.0/uninstall-complete.ps1 | iex
```

**v1.1.0** — Agent capture enable/disable/reset/status with:
- Three-state semantics: enable (1), disable (0), reset (unset)
- Safety-first action resolution (never defaults to enable in non-interactive contexts)
- Dry-run support (`TENETX_CAPTURE_DRY_RUN=1`)
- Shell-rc file management (.profile, .bashrc, .zshrc)
- launchctl support on macOS
- PowerShell self-contained (no external dependencies)

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
