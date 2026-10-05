# TenetX complete client cleanup — Windows (shareable one-click).
#
#   # Inventory only (safe default)
#   irm <URL>/uninstall-complete.ps1 | iex
#
#   # Destructive wipe
#   $env:TENETX_FORCE = '1'
#   irm <URL>/uninstall-complete.ps1 | iex
#   # or download then:  .\uninstall-complete.ps1 -Force
#
# Parity with local-stacks/runners/complete_uninstall.py and uninstall-complete.sh.
# Covers all 12 CLI agents (cli-go/internal/ide/ide.go Slugs; cline is
# macOS/Linux only) + run.sh build-cli tenetx.exe.bak.
# On macOS/Linux use uninstall-complete.sh instead.
#
# Params: -Force | -DryRun | -KeepBinary | -SkipRevoke | -Org <slug>
# Env:    TENETX_FORCE=1, TENETX_CONFIG_DIR
[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$DryRun,
    [switch]$KeepBinary,
    [switch]$SkipRevoke,
    [string]$Org = ""
)

$ErrorActionPreference = 'Stop'

function Write-Say([string]$Message) { Write-Host $Message }
function Write-Warn([string]$Message) { Write-Host "WARN: $Message" -ForegroundColor Yellow }

# Exit helper: hold the window open when run interactively (irm | iex,
# double-click, & .\file.ps1) so the outcome stays visible. Piped/CI runs
# (redirected stdin) skip the pause and keep the real exit code.

# True only for a real interactive console: a redirected/piped stdin, a
# non-console host, or -NonInteractive must never reach Read-Host.
function Test-Interactive {
    if ([Console]::IsInputRedirected) { return $false }
    if (-not [Environment]::UserInteractive) { return $false }
    if ($Host.Name -ne 'ConsoleHost') { return $false }
    return $true
}

function Exit-Host([int]$Code) {
    if (Test-Interactive) {
        Write-Host ''
        try { Read-Host 'Press Enter to close this window' | Out-Null } catch { }
    }
    exit $Code
}

# When piped via irm|iex, bound params may be empty — honor env.
if (-not $Force -and ($env:TENETX_FORCE -in @('1', 'true', 'TRUE', 'yes', 'YES'))) {
    $Force = $true
}
if ($DryRun) { $Force = $true }

# irm | iex passes no arguments; offer the action when nothing explicit was given.
if (-not $Force -and (Test-Interactive)) {
    Write-Host ''
    Write-Host 'TenetX client cleanup'
    Write-Host '====================='
    Write-Host '1. Inventory only (default) - list artifacts, change nothing'
    Write-Host '2. Dry-run wipe - show every action without deleting'
    Write-Host '3. WIPE - destructive removal of TenetX client artifacts'
    Write-Host '4. Exit'
    Write-Host ''
    $choice = $null
    try { $choice = Read-Host 'Select action [1-4]' } catch { $choice = $null }
    switch ($choice) {
        '2' { $DryRun = $true; $Force = $true }
        '3' {
            $confirm = $null
            try { $confirm = Read-Host 'Type WIPE to confirm destructive removal' } catch { $confirm = $null }
            if ($confirm -ceq 'WIPE') {
                $Force = $true
            } else {
                Write-Say 'Confirmation mismatch - staying in inventory-only mode.'
            }
        }
        '4' { Exit-Host 0 }
        default { }   # inventory only
    }
}

$HomeDir = if ($env:USERPROFILE) { $env:USERPROFILE } elseif ($env:HOME) { $env:HOME } else { [Environment]::GetFolderPath('UserProfile') }
$TenetxDir = if ($env:TENETX_CONFIG_DIR) { $env:TENETX_CONFIG_DIR } else { Join-Path $HomeDir '.tenetx' }
$LocalAppData = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $HomeDir 'AppData\Local' }
$WinBinDir = Join-Path $LocalAppData 'TenetX\bin'
$WinBinary = Join-Path $WinBinDir 'tenetx.exe'

$script:HadError = $false
$script:Actions = 0

# Sentinel blocks written by the CLI / server installer into third-party files.
$HermesMarkStart = '# >>> TENETX GUARD (managed) - do not edit by hand'
$HermesMarkEnd = '# <<< TENETX GUARD (managed)'
$VibeMarkStart = '# >>> TENETX MANAGED HOOKS -- do not edit inside this block >>>'
$VibeMarkEnd = '# <<< TENETX MANAGED HOOKS <<<'

function Note([string]$Message) {
    $script:Actions++
    if ($DryRun) {
        Write-Say "  [dry-run] $Message"
    } else {
        Write-Say "  $Message"
    }
}

function Test-PathContains([string]$PathValue, [string]$Entry) {
    if ([string]::IsNullOrWhiteSpace($PathValue) -or [string]::IsNullOrWhiteSpace($Entry)) {
        return $false
    }
    $entryN = [System.IO.Path]::GetFullPath($Entry.TrimEnd('\', '/')).ToLowerInvariant()
    foreach ($part in ($PathValue -split ';')) {
        $raw = $part.Trim()
        if (-not $raw) { continue }
        try {
            $pN = [System.IO.Path]::GetFullPath($raw.TrimEnd('\', '/')).ToLowerInvariant()
        } catch {
            continue
        }
        if ($pN -eq $entryN) { return $true }
    }
    return $false
}

function Strip-PathEntry([string]$PathValue, [string]$Entry) {
    $entryN = [System.IO.Path]::GetFullPath($Entry.TrimEnd('\', '/')).ToLowerInvariant()
    $kept = New-Object System.Collections.Generic.List[string]
    foreach ($part in ($PathValue -split ';')) {
        $raw = $part.Trim()
        if (-not $raw) { continue }
        try {
            $pN = [System.IO.Path]::GetFullPath($raw.TrimEnd('\', '/')).ToLowerInvariant()
        } catch {
            $kept.Add($part)
            continue
        }
        if ($pN -eq $entryN) { continue }
        $kept.Add($part)
    }
    return ($kept -join ';')
}

function Get-Binaries {
    $out = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $WinBinary) {
        $out.Add($WinBinary)
    }
    $which = Get-Command tenetx -ErrorAction SilentlyContinue
    if ($which -and $which.Source -and (Test-Path -LiteralPath $which.Source)) {
        if (-not ($out -contains $which.Source)) {
            $out.Add($which.Source)
        }
    }
    return $out
}

function Show-Inventory([string]$Label) {
    Write-Say ""
    Write-Say "=== inventory $Label ==="
    Write-Say "HOME=$HomeDir"
    if (Test-Path -LiteralPath $TenetxDir) {
        $files = @(Get-ChildItem -LiteralPath $TenetxDir -Recurse -File -ErrorAction SilentlyContinue)
        Write-Say "TENETX_DIR=$TenetxDir exists=yes files=$($files.Count)"
        $files | Select-Object -First 40 | ForEach-Object { Write-Say "  $($_.FullName)" }
    } else {
        Write-Say "TENETX_DIR=$TenetxDir exists=no"
    }

    Write-Say "binaries:"
    $bins = @(Get-Binaries)
    if ($bins.Count -eq 0) {
        Write-Say "  (none)"
    } else {
        foreach ($b in $bins) { Write-Say "  $b" }
    }

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    Write-Say ("PATH User has bin={0} Machine={1} process={2}" -f `
        (Test-PathContains $userPath $WinBinDir), `
        (Test-PathContains $machinePath $WinBinDir), `
        (Test-PathContains $env:Path $WinBinDir))
    Write-Say ("tenetx on PATH={0}" -f [bool](Get-Command tenetx -ErrorAction SilentlyContinue))

    $ide = @(
        @{ Name = 'claude_code'; Hooks = (Join-Path $HomeDir '.claude\hooks') },
        @{ Name = 'cursor'; Hooks = (Join-Path $HomeDir '.cursor\hooks') },
        @{ Name = 'windsurf'; Hooks = (Join-Path $HomeDir '.windsurf\hooks') },
        @{ Name = 'codex'; Hooks = (Join-Path $TenetxDir 'hooks\codex') },
        @{ Name = 'copilot'; Hooks = (Join-Path $HomeDir '.copilot\hooks') },
        @{ Name = 'antigravity'; Hooks = (Join-Path $HomeDir '.antigravity\hooks') },
        @{ Name = 'qwen_code'; Hooks = (Join-Path $HomeDir '.qwen\hooks') },
        @{ Name = 'hermes'; Hooks = (Join-Path $HomeDir '.hermes\hooks') },
        @{ Name = 'augment_code'; Hooks = (Join-Path $HomeDir '.augment\hooks') },
        @{ Name = 'kiro'; Hooks = (Join-Path $HomeDir '.kiro\hooks') },
        @{ Name = 'cline'; Hooks = (Join-Path $TenetxDir 'hooks\cline') },
        @{ Name = 'vibe_code'; Hooks = (Join-Path $HomeDir '.vibe\hooks') }
    )
    $guards = @(
        'tenetx-guard.py', 'tenetx-guard.sh', 'tenetx-guard.cmd', 'tenetx-guard.ps1',
        '.tenetx-guard.json', '.update-state.json'
    )
    foreach ($entry in $ide) {
        $found = @()
        foreach ($g in $guards) {
            $p = Join-Path $entry.Hooks $g
            if (Test-Path -LiteralPath $p) { $found += $p }
        }
        foreach ($sub in @('versions', 'current')) {
            $p = Join-Path $entry.Hooks $sub
            if (Test-Path -LiteralPath $p) { $found += $p }
        }
        # Stray tenetx-* residue under hooks dir (wrappers, backups) — name match only
        if (Test-Path -LiteralPath $entry.Hooks) {
            $strays = @(Get-ChildItem -LiteralPath $entry.Hooks -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like 'tenetx-*' -or $_.Name -like '.tenetx-*' })
            foreach ($s in $strays) {
                if ($found -notcontains $s.FullName) { $found += $s.FullName }
            }
        }
        if ($found.Count -gt 0) {
            Write-Say ("IDE {0}: {1}" -f $entry.Name, ($found -join ' '))
        }
    }
}

function Invoke-ProductCli {
    $tenetx = $null
    $cmd = Get-Command tenetx -ErrorAction SilentlyContinue
    if ($cmd) {
        $tenetx = $cmd.Source
    } elseif (Test-Path -LiteralPath $WinBinary) {
        $tenetx = $WinBinary
    }
    if (-not $tenetx) {
        Write-Warn 'tenetx not on PATH and binary missing — skip product logout/uninstall'
        return
    }

    if (-not $SkipRevoke) {
        Note "cli: $tenetx logout --revoke"
        if (-not $DryRun) {
            & $tenetx logout --revoke
            if ($LASTEXITCODE -ne 0) {
                Write-Warn "logout --revoke exit $LASTEXITCODE (continuing)"
            }
        }
    }

    if ($Org) {
        Note "cli: $tenetx uninstall --org $Org"
        if (-not $DryRun) {
            & $tenetx uninstall --org $Org
            if ($LASTEXITCODE -ne 0) {
                Write-Warn "uninstall exit $LASTEXITCODE (continuing)"
            }
        }
    } else {
        Note "cli: $tenetx uninstall"
        if (-not $DryRun) {
            & $tenetx uninstall
            if ($LASTEXITCODE -ne 0) {
                Write-Warn "uninstall exit $LASTEXITCODE (continuing)"
            }
        }
    }
}

function Scrub-JsonFile([string]$Path, [string]$Mode) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $py = Get-Command python -ErrorAction SilentlyContinue
    if (-not $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }
    if (-not $py) {
        Write-Warn "python missing — skip JSON scrub $Path"
        return
    }
    Note "json-scrub: $Path ($Mode)"
    if ($DryRun) { return }

    $code = @'
import json, shutil, sys
from pathlib import Path
path = Path(sys.argv[1])
mode = sys.argv[2]
MARKERS = ("tenetx_proxy_token=", ".tenetx/", ".tenetx.", "tenetx-ask")
try:
    data = json.loads(path.read_text(encoding="utf-8"))
except Exception as e:
    print(f"skip: {e}", file=sys.stderr)
    sys.exit(0)
if not isinstance(data, dict):
    sys.exit(0)
changed = False

def is_tx(cmd):
    return isinstance(cmd, str) and "tenetx-guard" in cmd.lower()

if mode == "hooks":
    hooks = data.get("hooks")
    if isinstance(hooks, dict):
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
elif mode == "mcp":
    servers = data.get("mcpServers")
    if isinstance(servers, dict):
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
elif mode == "toplevel":
    # Antigravity keys hooks.json by hook NAME; ours is one top-level key.
    if "tenetx-guard" in data:
        del data["tenetx-guard"]
        changed = True
elif mode == "approvals":
    # Hermes shell-hooks allowlist: drop rows authorising our own guard.
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
'@
    $tmp = [System.IO.Path]::GetTempFileName() + '.py'
    try {
        Set-Content -LiteralPath $tmp -Value $code -Encoding UTF8
        & $py.Source $tmp $Path $Mode
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "JSON scrub failed: $Path"
        }
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Scrub-TomlFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $py = Get-Command python -ErrorAction SilentlyContinue
    if (-not $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }
    if (-not $py) {
        Write-Warn "python missing — skip toml-scrub $Path"
        return
    }
    Note "toml-scrub: $Path"
    if ($DryRun) { return }

    $code = @'
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
'@
    $tmp = [System.IO.Path]::GetTempFileName() + '.py'
    try {
        Set-Content -LiteralPath $tmp -Value $code -Encoding UTF8
        & $py.Source $tmp $Path
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "toml-scrub failed: $Path"
        }
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

# Remove the sentinel block (inclusive) from a text file, leaving every other
# line — including the user's own hooks — intact.
function Strip-MarkerBlock([string]$Path, [string]$Begin, [string]$End) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $lines = @([System.IO.File]::ReadAllLines($Path))
    $hasBegin = $false
    $hasEnd = $false
    foreach ($line in $lines) {
        $t = $line.Trim()
        if ($t -eq $Begin) { $hasBegin = $true }
        if ($t -eq $End) { $hasEnd = $true }
    }
    if (-not ($hasBegin -and $hasEnd)) { return }
    Note "strip-block: $Path ($Begin)"
    if ($DryRun) { return }

    $backup = "$Path.tenetx-complete-uninstall-backup"
    if (-not (Test-Path -LiteralPath $backup)) {
        Copy-Item -LiteralPath $Path -Destination $backup -Force
    }
    $kept = New-Object System.Collections.Generic.List[string]
    $skip = $false
    foreach ($line in $lines) {
        $t = $line.Trim()
        if ((-not $skip) -and $t -eq $Begin) { $skip = $true; continue }
        if ($skip -and $t -eq $End) { $skip = $false; continue }
        if (-not $skip) { $kept.Add($line) }
    }
    try {
        [System.IO.File]::WriteAllLines($Path, $kept, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        Write-Warn "strip-block failed $Path : $_"
        $script:HadError = $true
    }
}

# CLI backup residue for the wiring files (cli-go/internal/uninstall/cleanup.go
# Backups). Our own *.tenetx-complete-uninstall-backup and fix-agent-hooks'
# *.tenetx-bak-* are the operators' rollback points and are deliberately kept.
function Remove-CliBackups([string[]]$Paths) {
    foreach ($p in $Paths) {
        foreach ($suffix in @('.tenetx-backup.*', '.tenetx-test-backup.*', '.pre-tenetx-clean.*', '.backup-tenetx-*')) {
            $hits = @(Get-ChildItem -Path "$p$suffix" -Force -ErrorAction SilentlyContinue)
            foreach ($hit in $hits) {
                Note "delete: $($hit.FullName)"
                if (-not $DryRun) {
                    try {
                        Remove-Item -LiteralPath $hit.FullName -Force
                    } catch {
                        Write-Warn "delete failed $($hit.FullName) : $_"
                        $script:HadError = $true
                    }
                }
            }
        }
    }
}

function Remove-GuardDir([string]$HooksDir) {
    if (-not (Test-Path -LiteralPath $HooksDir)) { return }
    # Known guard artifacts (incl. orphan PowerShell wrapper)
    foreach ($g in @(
            'tenetx-guard.py', 'tenetx-guard.sh', 'tenetx-guard.cmd', 'tenetx-guard.ps1',
            '.tenetx-guard.json', '.update-state.json'
        )) {
        $p = Join-Path $HooksDir $g
        if (Test-Path -LiteralPath $p) {
            Note "delete: $p"
            if (-not $DryRun) {
                try { Remove-Item -LiteralPath $p -Force } catch {
                    Write-Warn "delete failed $p : $_"
                    $script:HadError = $true
                }
            }
        }
    }
    # Stray tenetx-* / .tenetx-* files only (wrappers, residue). Never touch non-tenetx files.
    # Do NOT scan repo local-stacks/ mirrors — inventory is under user HOME + TENETX_DIR only.
    $strays = @(Get-ChildItem -LiteralPath $HooksDir -File -ErrorAction SilentlyContinue |
            Where-Object {
                ($_.Name -like 'tenetx-*' -or $_.Name -like '.tenetx-*') -and
                $_.Name -notin @(
                    'tenetx-guard.py', 'tenetx-guard.sh', 'tenetx-guard.cmd', 'tenetx-guard.ps1',
                    '.tenetx-guard.json'
                )
            })
    foreach ($s in $strays) {
        Note "delete: $($s.FullName) (tenetx-* residue)"
        if (-not $DryRun) {
            try { Remove-Item -LiteralPath $s.FullName -Force } catch {
                Write-Warn "delete failed $($s.FullName) : $_"
                $script:HadError = $true
            }
        }
    }
    foreach ($sub in @('versions', 'current')) {
        $p = Join-Path $HooksDir $sub
        if (Test-Path -LiteralPath $p) {
            Note "rmtree: $p"
            if (-not $DryRun) {
                try { Remove-Item -LiteralPath $p -Recurse -Force } catch {
                    Write-Warn "rmtree failed $p : $_"
                    $script:HadError = $true
                }
            }
        }
    }
    # Updater bytecode (cleanup.go Agent). The tenetx-* stray sweep above already
    # covers tenetx-guard.<ext>.* wrapper backups.
    $pycDir = Join-Path $HooksDir '__pycache__'
    if (Test-Path -LiteralPath $pycDir) {
        foreach ($f in @(Get-ChildItem -LiteralPath $pycDir -File -Filter 'tenetx-guard.*' -ErrorAction SilentlyContinue)) {
            Note "delete: $($f.FullName)"
            if (-not $DryRun) {
                try { Remove-Item -LiteralPath $f.FullName -Force } catch {
                    Write-Warn "delete failed $($f.FullName) : $_"
                    $script:HadError = $true
                }
            }
        }
        if ((-not $DryRun) -and (Test-Path -LiteralPath $pycDir) -and
            -not (Get-ChildItem -LiteralPath $pycDir -Force -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $pycDir -Force -ErrorAction SilentlyContinue
        }
    }
    # Old hook-dir copies may hold unrelated user hooks: remove only our files,
    # never the directory (cleanup.go Backups).
    foreach ($copy in @(Get-ChildItem -Path "$HooksDir.tenetx-backup.*", "$HooksDir.tenetx-paused" `
                -Directory -Force -ErrorAction SilentlyContinue)) {
        foreach ($g in @(
                'tenetx-guard.py', 'tenetx-guard.sh', 'tenetx-guard.cmd', 'tenetx-guard.ps1',
                '.tenetx-guard.json', '.update-state.json'
            )) {
            $p = Join-Path $copy.FullName $g
            if (Test-Path -LiteralPath $p) {
                Note "delete: $p"
                if (-not $DryRun) {
                    try { Remove-Item -LiteralPath $p -Force } catch {
                        Write-Warn "delete failed $p : $_"
                        $script:HadError = $true
                    }
                }
            }
        }
    }
}

function Invoke-HardWipe {
    # One block per agent; order + paths mirror cli-go/internal/ide/ide.go
    # (layoutBySlug) and hooks.Uninstall. Cline is macOS/Linux only — the CLI
    # refuses it on Windows, so there is nothing to remove here.

    # claude_code
    Remove-GuardDir (Join-Path $HomeDir '.claude\hooks')
    Scrub-JsonFile (Join-Path $HomeDir '.claude\settings.json') 'hooks'
    Scrub-JsonFile (Join-Path $HomeDir '.claude.json') 'mcp'

    # cursor
    Remove-GuardDir (Join-Path $HomeDir '.cursor\hooks')
    Scrub-JsonFile (Join-Path $HomeDir '.cursor\hooks.json') 'hooks'
    Scrub-JsonFile (Join-Path $HomeDir '.cursor\mcp.json') 'mcp'
    # Legacy misplaced wiring older builds wrote under hooks/ (cursor only —
    # elsewhere a hooks.json under a guard dir is the user's own file).
    $legacy = Join-Path (Join-Path $HomeDir '.cursor\hooks') 'hooks.json'
    if (Test-Path -LiteralPath $legacy) {
        Note "delete: $legacy (legacy hooks.json under hooks/)"
        if (-not $DryRun) {
            try { Remove-Item -LiteralPath $legacy -Force } catch {
                Write-Warn "delete failed $legacy : $_"
                $script:HadError = $true
            }
        }
    }

    # windsurf (Devin)
    Remove-GuardDir (Join-Path $HomeDir '.windsurf\hooks')
    Scrub-JsonFile (Join-Path $HomeDir '.codeium\windsurf\hooks.json') 'hooks'
    Scrub-JsonFile (Join-Path $HomeDir '.config\devin\config.json') 'hooks'
    Scrub-JsonFile (Join-Path $HomeDir '.windsurf\settings.json') 'hooks'
    Scrub-JsonFile (Join-Path $HomeDir '.windsurf\mcp.json') 'hooks'
    Scrub-JsonFile (Join-Path $HomeDir '.windsurf\mcp.json') 'mcp'

    # codex
    Remove-GuardDir (Join-Path $TenetxDir 'hooks\codex')
    Scrub-JsonFile (Join-Path $HomeDir '.codex\hooks.json') 'hooks'

    # copilot
    Remove-GuardDir (Join-Path $HomeDir '.copilot\hooks')
    Scrub-JsonFile (Join-Path $HomeDir '.copilot\hooks\notification-hooks.json') 'hooks'

    # antigravity — hooks.json is keyed by hook NAME, ours is one top-level key
    Remove-GuardDir (Join-Path $HomeDir '.antigravity\hooks')
    Scrub-JsonFile (Join-Path $HomeDir '.gemini\config\hooks.json') 'toplevel'

    # qwen_code
    Remove-GuardDir (Join-Path $HomeDir '.qwen\hooks')
    Scrub-JsonFile (Join-Path $HomeDir '.qwen\settings.json') 'hooks'

    # hermes
    Remove-GuardDir (Join-Path $HomeDir '.hermes\hooks')
    Strip-MarkerBlock (Join-Path $HomeDir '.hermes\config.yaml') $HermesMarkStart $HermesMarkEnd
    Scrub-JsonFile (Join-Path $HomeDir '.hermes\shell-hooks-allowlist.json') 'approvals'

    # augment_code
    Remove-GuardDir (Join-Path $HomeDir '.augment\hooks')
    Scrub-JsonFile (Join-Path $HomeDir '.augment\settings.json') 'hooks'

    # kiro — tenetx-guard.json holds nothing but our hooks (removed by the
    # tenetx-* stray sweep in Remove-GuardDir)
    Remove-GuardDir (Join-Path $HomeDir '.kiro\hooks')

    # vibe_code
    Remove-GuardDir (Join-Path $HomeDir '.vibe\hooks')
    Strip-MarkerBlock (Join-Path $HomeDir '.vibe\hooks.toml') $VibeMarkStart $VibeMarkEnd

    # codex: MCP rows in config.toml, plus adapter-owned rule file + browser skill
    Scrub-TomlFile (Join-Path $HomeDir '.codex\config.toml')
    foreach ($codexResidue in @(
            (Join-Path $HomeDir '.codex\rules\tenetx.rules'),
            (Join-Path $HomeDir '.agents\skills\tenetx-browser')
        )) {
        if (Test-Path -LiteralPath $codexResidue) {
            $isDir = (Get-Item -LiteralPath $codexResidue -Force).PSIsContainer
            Note "$(if ($isDir) { 'rmtree' } else { 'delete' }): $codexResidue"
            if (-not $DryRun) {
                try { Remove-Item -LiteralPath $codexResidue -Recurse -Force } catch {
                    Write-Warn "delete failed $codexResidue : $_"
                    $script:HadError = $true
                }
            }
        }
    }

    # --- shared residue ---
    $cache = Join-Path $HomeDir '.cache\tenetx'
    if (Test-Path -LiteralPath $cache) {
        Note "rmtree: $cache"
        if (-not $DryRun) {
            try { Remove-Item -LiteralPath $cache -Recurse -Force } catch {
                Write-Warn "rmtree $cache failed: $_"
                $script:HadError = $true
            }
        }
    }

    Remove-CliBackups @(
        (Join-Path $HomeDir '.claude\settings.json'),
        (Join-Path $HomeDir '.claude.json'),
        (Join-Path $HomeDir '.cursor\hooks.json'),
        (Join-Path $HomeDir '.cursor\mcp.json'),
        (Join-Path $HomeDir '.codeium\windsurf\hooks.json'),
        (Join-Path $HomeDir '.config\devin\config.json'),
        (Join-Path $HomeDir '.windsurf\settings.json'),
        (Join-Path $HomeDir '.windsurf\mcp.json'),
        (Join-Path $HomeDir '.codex\hooks.json'),
        (Join-Path $HomeDir '.codex\config.toml'),
        (Join-Path $HomeDir '.copilot\hooks\notification-hooks.json'),
        (Join-Path $HomeDir '.gemini\config\hooks.json'),
        (Join-Path $HomeDir '.qwen\settings.json'),
        (Join-Path $HomeDir '.hermes\config.yaml'),
        (Join-Path $HomeDir '.hermes\shell-hooks-allowlist.json'),
        (Join-Path $HomeDir '.augment\settings.json'),
        (Join-Path $HomeDir '.kiro\hooks\tenetx-guard.json'),
        (Join-Path $HomeDir '.vibe\hooks.toml')
    )

    if (Test-Path -LiteralPath $TenetxDir) {
        Note "rmtree: $TenetxDir (full ~/.tenetx wipe)"
        if (-not $DryRun) {
            try { Remove-Item -LiteralPath $TenetxDir -Recurse -Force } catch {
                Write-Warn "rmtree $TenetxDir failed: $_"
                $script:HadError = $true
            }
        }
    }
}

function Remove-BinaryAndPath {
    if ($KeepBinary) {
        Write-Warn '--keep-binary: leaving binary and TenetX install dir'
        return
    }

    foreach ($b in @(Get-Binaries)) {
        Note "delete: $b"
        if (-not $DryRun) {
            try {
                Remove-Item -LiteralPath $b -Force
            } catch {
                Write-Warn "delete failed $b : $_ (TENQA-29: re-run elevated if Administrators-owned)"
                $script:HadError = $true
            }
        }
    }

    # build-cli keeps one rolling <name>.bak next to the binary.
    $bak = "$WinBinary.bak"
    if (Test-Path -LiteralPath $bak) {
        Note "delete: $bak"
        if (-not $DryRun) {
            try { Remove-Item -LiteralPath $bak -Force } catch {
                Write-Warn "delete failed $bak : $_"
                $script:HadError = $true
            }
        }
    }
    foreach ($extra in @(Get-ChildItem -Path "$WinBinDir\tenetx.*.bak" -Force -ErrorAction SilentlyContinue)) {
        Note "delete: $($extra.FullName)"
        if (-not $DryRun) {
            try { Remove-Item -LiteralPath $extra.FullName -Force } catch {
                Write-Warn "delete failed $($extra.FullName) : $_"
                $script:HadError = $true
            }
        }
    }

    foreach ($d in @($WinBinDir, (Split-Path $WinBinDir -Parent))) {
        if ((Test-Path -LiteralPath $d) -and -not (Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue)) {
            Note "rmdir: $d"
            if (-not $DryRun) {
                try { Remove-Item -LiteralPath $d -Force } catch {
                    Write-Warn "rmdir $d : $_"
                }
            }
        }
    }

    # Process PATH
    if (Test-PathContains $env:Path $WinBinDir) {
        Note "path-process: $WinBinDir (remove)"
        if (-not $DryRun) {
            $env:Path = Strip-PathEntry $env:Path $WinBinDir
        }
    }

    foreach ($scope in @('User', 'Machine')) {
        $cur = [Environment]::GetEnvironmentVariable('Path', $scope)
        if (-not (Test-PathContains $cur $WinBinDir)) { continue }
        $newVal = Strip-PathEntry $cur $WinBinDir
        Note "path-$($scope.ToLower()): $WinBinDir (remove from persisted Path)"
        if ($DryRun) { continue }
        try {
            [Environment]::SetEnvironmentVariable('Path', $newVal, $scope)
        } catch {
            $msg = "$scope Path scrub failed: $_"
            if ($scope -eq 'Machine') {
                Write-Warn "$msg (best-effort; may need elevation)"
            } else {
                Write-Warn $msg
                $script:HadError = $true
            }
        }
    }
}

function Test-Residuals {
    $fail = $false
    if (Test-Path -LiteralPath $TenetxDir) {
        $files = @(Get-ChildItem -LiteralPath $TenetxDir -Recurse -File -ErrorAction SilentlyContinue)
        if ($files.Count -gt 0) {
            Write-Say "residual: $TenetxDir still has $($files.Count) files"
            $fail = $true
        }
    }
    if (-not $KeepBinary) {
        foreach ($b in @(Get-Binaries)) {
            Write-Say "residual binary: $b"
            $fail = $true
        }
        foreach ($bak in @("$WinBinary.bak") + @(Get-ChildItem -Path "$WinBinDir\tenetx.*.bak" -Force -ErrorAction SilentlyContinue |
                    ForEach-Object { $_.FullName })) {
            if (Test-Path -LiteralPath $bak) {
                Write-Say "residual backup: $bak"
                $fail = $true
            }
        }
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        if (Test-PathContains $userPath $WinBinDir) {
            Write-Say "residual: User PATH contains $WinBinDir"
            $fail = $true
        }
    }
    foreach ($hooks in @(
        (Join-Path $HomeDir '.claude\hooks'),
        (Join-Path $HomeDir '.cursor\hooks'),
        (Join-Path $HomeDir '.windsurf\hooks'),
        (Join-Path $HomeDir '.copilot\hooks'),
        (Join-Path $HomeDir '.antigravity\hooks'),
        (Join-Path $HomeDir '.qwen\hooks'),
        (Join-Path $HomeDir '.hermes\hooks'),
        (Join-Path $HomeDir '.augment\hooks'),
        (Join-Path $HomeDir '.kiro\hooks'),
        (Join-Path $HomeDir '.vibe\hooks')
    )) {
        foreach ($g in @(
                'tenetx-guard.py', 'tenetx-guard.sh', 'tenetx-guard.cmd', 'tenetx-guard.ps1',
                '.tenetx-guard.json', '.update-state.json'
            )) {
            $p = Join-Path $hooks $g
            if (Test-Path -LiteralPath $p) {
                Write-Say "residual guard: $p"
                $fail = $true
            }
        }
        if (Test-Path -LiteralPath $hooks) {
            $left = @(Get-ChildItem -LiteralPath $hooks -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like 'tenetx-*' -or $_.Name -like '.tenetx-*' })
            foreach ($s in $left) {
                Write-Say "residual guard: $($s.FullName)"
                $fail = $true
            }
        }
    }
    # kiro: the hook definition file is entirely ours
    $kiroFile = Join-Path $HomeDir '.kiro\hooks\tenetx-guard.json'
    if (Test-Path -LiteralPath $kiroFile) {
        Write-Say "residual wiring: $kiroFile"
        $fail = $true
    }
    # hermes / vibe: the sentinel block must be gone
    foreach ($pair in @(
            @{ Path = (Join-Path $HomeDir '.hermes\config.yaml'); Marker = $HermesMarkStart },
            @{ Path = (Join-Path $HomeDir '.vibe\hooks.toml'); Marker = $VibeMarkStart }
        )) {
        if ((Test-Path -LiteralPath $pair.Path) -and
            (Select-String -LiteralPath $pair.Path -SimpleMatch -Pattern $pair.Marker -Quiet)) {
            Write-Say "residual wiring: $($pair.Path) ($($pair.Marker))"
            $fail = $true
        }
    }
    # antigravity: top-level hook name
    $geminiHooks = Join-Path $HomeDir '.gemini\config\hooks.json'
    if ((Test-Path -LiteralPath $geminiHooks) -and
        (Select-String -LiteralPath $geminiHooks -SimpleMatch -Pattern '"tenetx-guard"' -Quiet)) {
        Write-Say "residual wiring: $geminiHooks (tenetx-guard)"
        $fail = $true
    }
    return -not $fail
}

# --- main ---
Show-Inventory 'before'

if (-not $Force) {
    Write-Say ""
    Write-Say 'Inventory only — no changes made.'
    Write-Say 'Re-run with -Force (or $env:TENETX_FORCE=''1'') to wipe:'
    Write-Say '  $env:TENETX_FORCE = ''1''; irm <URL>/uninstall-complete.ps1 | iex'
    Write-Say '  # or locally:'
    Write-Say '  .\uninstall-complete.ps1 -Force'
    Exit-Host 0
}

Write-Say ""
Write-Say '--- product CLI ---'
Invoke-ProductCli

Write-Say ""
Write-Say '--- hard wipe ---'
Invoke-HardWipe
Remove-BinaryAndPath

Write-Say ""
Write-Say "--- actions noted: $($script:Actions) ---"

Show-Inventory 'after'

if ($DryRun) {
    Write-Say ""
    Write-Say 'Dry-run only — no changes applied.'
    Exit-Host 0
}

if ($script:HadError) {
    Write-Say ""
    Write-Say 'COMPLETE-UNINSTALL INCOMPLETE — errors during wipe'
    Exit-Host 1
}

if (-not (Test-Residuals)) {
    Write-Say ""
    Write-Say 'COMPLETE-UNINSTALL INCOMPLETE — residuals remain'
    Exit-Host 1
}

Write-Say ""
Write-Say 'COMPLETE-UNINSTALL OK'
Exit-Host 0
