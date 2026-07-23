# TenetX client cleanup (public)

Public, shareable **complete client wipe** scripts for TenetX. These go beyond product `tenetx uninstall` (partial by design — binary / credential leftovers can remain).

**Safety**
- Default run is **inventory only** (prints what would be removed).
- Destructive wipe requires `--force` / `-Force` (or `TENETX_FORCE=1`).
- Prefer `--dry-run` first on a machine you care about.

QA mirror (private PMS): `arifalidawood-tenetx/tenetx-pms` → `local-stacks/client-cleanup/` and submodule `tenetx-client-cleanup`.
This public repo exists so unauthenticated `curl` / `irm` one-liners work. Long-term product CDN: TENQA-71 (`https://tenetx.ai/uninstall-complete.*`).

## One-liners (release `v1.0.0`)

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

## Flags

| Flag / env | Effect |
|------------|--------|
| (default) | Inventory only |
| `--force` / `-Force` / `TENETX_FORCE=1` | Full wipe |
| `--dry-run` / `-DryRun` | Plan only |
| `--keep-binary` / `-KeepBinary` | Leave CLI binary |
| `--skip-revoke` / `-SkipRevoke` | Skip `tenetx logout --revoke` |
| `--org SLUG` / `-Org SLUG` | Pass through to `tenetx uninstall --org` |

## Local clone

```bash
sh ./uninstall-complete.sh --dry-run
sh ./uninstall-complete.sh --force
```

```powershell
.\uninstall-complete.ps1 -DryRun
.\uninstall-complete.ps1 -Force
```
