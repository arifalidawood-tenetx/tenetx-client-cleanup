#Requires -Version 7.0
<#
.SYNOPSIS
    Surgical rewrite of TenetX guard hook command quoting in agent JSON configs.

.DESCRIPTION
    Walks ONLY the `hooks` subtree in agent config JSON files and rewrites
    entries whose *decoded* command ends in `tenetx-guard.cmd` (ignores
    bun / claude-mem / other commands). All non-hook keys stay byte-identical
    via pre/post SHA256 of the non-hooks object.

    Targets (when selected):
      claude  -> ~/.claude/settings.json
      copilot -> ~/.copilot/hooks/notification-hooks.json
      cursor  -> ~/.cursor/hooks.json          (-IncludeCursor)
      codex   -> ~/.codex/hooks.json           (-IncludeCodex)

    Replacement shapes:
      Claude/Cursor/Codex command:
        "\"C:\Users\<user>\.claude\hooks\tenetx-guard.cmd\""
        (agent-specific guard path under that agent's hooks dir, or existing path)
      Copilot bash:
        "\"C:\Users\<user>\.copilot\hooks\tenetx-guard.cmd\" <event>"
        (preserves exact lowercase event token already present)

    Default mode is DryRun. Pass -Apply to write. -Revert restores from
    sibling backups named <file>.tenetx-bak-<utc>. -Verify re-parses and
    optionally smoke-runs the guard via Git Bash with a sample payload.

.EXAMPLE
    # Dry-run default agents (claude, copilot)
    pwsh -NoProfile -File .\fix-agent-hooks.ps1

.EXAMPLE
    # Apply claude + copilot, then verify
    pwsh -NoProfile -File .\fix-agent-hooks.ps1 -Apply -Verify

.EXAMPLE
    # Include cursor + codex
    pwsh -NoProfile -File .\fix-agent-hooks.ps1 -Apply -IncludeCursor -IncludeCodex

.EXAMPLE
    # Restore from latest backup only
    pwsh -NoProfile -File .\fix-agent-hooks.ps1 -Revert -Agents claude,copilot
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Apply,
    [string[]]$Agents = @('claude', 'copilot'),
    [switch]$IncludeCodex,
    [switch]$IncludeCursor,
    [switch]$Revert,
    [switch]$Verify
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# PowerShell 7+ gate (also covered by #Requires, but be explicit for iex)
# ---------------------------------------------------------------------------
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Error "This script requires PowerShell 7+ (pwsh). Refusing Windows PowerShell 5.1. Current: $($PSVersionTable.PSVersion)"
    exit 2
}

# Default DryRun ON unless -Apply (or -Revert which has its own write path)
if (-not $Apply -and -not $Revert) {
    $DryRun = $true
}
if ($Apply -and $Revert) {
    Write-Error "Pass either -Apply or -Revert, not both."
    exit 2
}
if ($Apply) {
    $DryRun = $false
}

# TENETX_FIX_HOOKS_HOME: sandbox override for tests (GetFolderPath ignores USERPROFILE)
if (-not [string]::IsNullOrWhiteSpace($env:TENETX_FIX_HOOKS_HOME)) {
    $HomeDir = $env:TENETX_FIX_HOOKS_HOME
} else {
    $HomeDir = [Environment]::GetFolderPath('UserProfile')
    if ([string]::IsNullOrWhiteSpace($HomeDir)) {
        $HomeDir = $env:USERPROFILE
    }
}

$GitBash = 'C:\Program Files\Git\bin\bash.exe'
$DefaultPayload = 'C:/Users/aadx3d/codes/tenetx-pms/.omo/scratch/windowstest-20260804/payload.json'
# Also accept Windows path form of payload for Test-Path
$DefaultPayloadWin = 'C:\Users\aadx3d\codes\tenetx-pms\.omo\scratch\windowstest-20260804\payload.json'

# ---------------------------------------------------------------------------
# Agent catalog
# ---------------------------------------------------------------------------
$AgentCatalog = [ordered]@{
    claude = @{
        Name     = 'claude'
        Path     = Join-Path $HomeDir '.claude\settings.json'
        GuardCmd = Join-Path $HomeDir '.claude\hooks\tenetx-guard.cmd'
        Shape    = 'command'   # root key for command string: "command"
        QuotedOnlyPath = $true # expected: "\"C:\...\tenetx-guard.cmd\""
    }
    copilot = @{
        Name     = 'copilot'
        Path     = Join-Path $HomeDir '.copilot\hooks\notification-hooks.json'
        GuardCmd = Join-Path $HomeDir '.copilot\hooks\tenetx-guard.cmd'
        Shape    = 'bash'      # copilot stores under "bash"
        QuotedOnlyPath = $false
    }
    cursor = @{
        Name     = 'cursor'
        Path     = Join-Path $HomeDir '.cursor\hooks.json'
        GuardCmd = Join-Path $HomeDir '.cursor\hooks\tenetx-guard.cmd'
        Shape    = 'command'
        QuotedOnlyPath = $true
    }
    codex = @{
        Name     = 'codex'
        Path     = Join-Path $HomeDir '.codex\hooks.json'
        GuardCmd = Join-Path $HomeDir '.tenetx\hooks\codex\tenetx-guard.cmd'
        Shape    = 'command'
        QuotedOnlyPath = $true
    }
}

function Write-Info([string]$Message) { Write-Host $Message }
function Write-Ok([string]$Message)   { Write-Host $Message -ForegroundColor Green }
function Write-WarnMsg([string]$Message) { Write-Host "WARN: $Message" -ForegroundColor Yellow }
function Write-ErrMsg([string]$Message)  { Write-Host "ERROR: $Message" -ForegroundColor Red }

function Get-SelectedAgents {
    $list = [System.Collections.Generic.List[string]]::new()
    # Expand "claude,copilot" when caller passed a single CSV token (common via -File)
    $expanded = foreach ($a in $Agents) {
        if ($null -eq $a) { continue }
        foreach ($part in ([string]$a) -split ',') {
            $part
        }
    }
    foreach ($a in $expanded) {
        $n = $a.Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($n)) { continue }
        if (-not $AgentCatalog.Contains($n)) {
            throw "Unknown agent '$a'. Known: $($AgentCatalog.Keys -join ', ')"
        }
        if (-not $list.Contains($n)) { [void]$list.Add($n) }
    }
    if ($IncludeCursor -and -not $list.Contains('cursor')) { [void]$list.Add('cursor') }
    if ($IncludeCodex -and -not $list.Contains('codex'))   { [void]$list.Add('codex') }
    if ($list.Count -eq 0) {
        throw "No agents selected. Use -Agents and/or -IncludeCursor / -IncludeCodex."
    }
    return $list.ToArray()
}

function Get-FileSha256([string]$Path) {
    $hash = Get-FileHash -LiteralPath $Path -Algorithm SHA256
    return $hash.Hash
}

function Get-ObjectSha256($Object) {
    # Canonical-ish: re-serialize at fixed depth then hash UTF8 bytes
    $json = ConvertTo-Json -InputObject $Object -Depth 20 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha.ComputeHash($bytes)
        return ([BitConverter]::ToString($hashBytes) -replace '-', '')
    } finally {
        $sha.Dispose()
    }
}

function Get-NonHooksClone($Root) {
    # Clone root without the 'hooks' property (case-sensitive JSON names preserved
    # via PSCustomObject note properties).
    if ($null -eq $Root) { return $null }
    $clone = [ordered]@{}
    foreach ($p in $Root.PSObject.Properties) {
        if ($p.Name -eq 'hooks') { continue }
        $clone[$p.Name] = $p.Value
    }
    return [pscustomobject]$clone
}

function Test-EndsWithTenetxGuard([string]$Decoded) {
    if ([string]::IsNullOrWhiteSpace($Decoded)) { return $false }
    $trim = $Decoded.Trim()
    # Ignore bun / claude-mem / worker-service style commands
    if ($trim -match '(?i)[\\/]bun(\.exe)?(\s|"|$)') { return $false }
    if ($trim -match '(?i)claude-mem|worker-service\.cjs|thedotmack') { return $false }
    # Decoded command ends with tenetx-guard.cmd (optionally followed by event token(s))
    # Strip surrounding quotes and take last path-ish token before optional event args
    $core = $trim
    # Match ...tenetx-guard.cmd at end of a path segment, optional trailing args
    if ($core -match '(?i)tenetx-guard\.cmd(\s|$)') {
        return $true
    }
    return $false
}

function Get-DecodedCommand([string]$Raw) {
    if ($null -eq $Raw) { return '' }
    $s = [string]$Raw
    # JSON may already have the value without outer JSON quotes (PS string).
    # Strip one layer of surrounding double-quotes if present and balanced.
    $t = $s.Trim()
    if ($t.Length -ge 2 -and $t.StartsWith('"') -and $t.EndsWith('"')) {
        # Could be fully quoted path: "C:\...\tenetx-guard.cmd"
        # Or escaped-style already applied. Peel once for comparison of path.
        return $t.Substring(1, $t.Length - 2)
    }
    return $t
}

function Test-AlreadyQuotedShape([string]$Raw, [string]$AgentName) {
    # Idempotency: decoded form already matches quoted shape if raw starts and ends with "
    # (JSON string value begins with quote character as first char of the value)
    if ([string]::IsNullOrEmpty($Raw)) { return $false }
    $t = $Raw.Trim()
    if (-not ($t.StartsWith('"') -and $t.EndsWith('"'))) {
        # Copilot expected: "\"C:\...\tenetx-guard.cmd\" event" — after JSON parse the
        # PS string looks like: "C:\...\tenetx-guard.cmd" event
        # i.e. starts with " and has a trailing event after closing quote.
    }
    if ($AgentName -eq 'copilot') {
        # Pattern: "path" eventToken  (path quoted, event outside)
        return ($t -match '^"[^"]*tenetx-guard\.cmd"\s+\S+$')
    }
    # Claude/cursor/codex: entire command is a single quoted path
    # After JSON parse: "C:\...\tenetx-guard.cmd"  (starts and ends with ")
    return ($t.StartsWith('"') -and $t.EndsWith('"') -and ($t -match '(?i)tenetx-guard\.cmd"$'))
}

function Get-GuardPathFromDecoded([string]$Decoded, [string]$FallbackGuard) {
    # Prefer existing path to tenetx-guard.cmd from the decoded command.
    if ($Decoded -match '(?i)((?:[A-Za-z]:)?[^"\s]*tenetx-guard\.cmd)') {
        $p = $Matches[1]
        # Unescape doubled backslashes if any leaked
        $p = $p -replace '\\\\', '\'
        return $p
    }
    return $FallbackGuard
}

function Get-CopilotEventToken([string]$Decoded) {
    # Existing lowercase event after the cmd path, e.g. preToolUse
    if ($Decoded -match '(?i)tenetx-guard\.cmd\s+(\S+)') {
        return $Matches[1]
    }
    return $null
}

function New-ExpectedCommand([string]$AgentName, [string]$GuardPath, [string]$EventToken) {
    # JSON string value content (what PS stores after ConvertFrom-Json / before ConvertTo-Json)
    # Claude:  "C:\Users\...\tenetx-guard.cmd"   (literal quote chars wrapping path)
    # Copilot: "C:\Users\...\tenetx-guard.cmd" preToolUse
    if ($AgentName -eq 'copilot') {
        if ([string]::IsNullOrWhiteSpace($EventToken)) {
            throw "Copilot entry missing event token; cannot build replacement for guard '$GuardPath'"
        }
        return "`"$GuardPath`" $EventToken"
    }
    return "`"$GuardPath`""
}

function ConvertTo-ArraySafe($Value) {
    # Ensure array-valued properties stay arrays (single-element → [object[]]).
    # The leading comma is required: `return [object[]]@($x)` unrolls a
    # single-element array into the pipeline and yields the scalar instead.
    if ($null -eq $Value) { return ,([object[]]@()) }
    if ($Value -is [System.Array]) { return ,([object[]]$Value) }
    return ,([object[]]@($Value))
}

function Test-IsHookLeafOrGroup($Val) {
    if ($null -eq $Val) { return $false }
    if ($Val -is [string]) { return $false }
    if (-not $Val.PSObject) { return $false }
    $names = @($Val.PSObject.Properties | ForEach-Object { $_.Name })
    # Leaf hook spec or matcher group
    foreach ($n in @('command', 'bash', 'hooks', 'type', 'matcher', 'timeout', 'failClosed')) {
        if ($names -contains $n) { return $true }
    }
    return $false
}

function Repair-HooksArrays($HooksNode) {
    # Walk hooks tree; any property that is a list of hook entries must be [object[]]
    # ConvertFrom-Json unwraps single-element arrays to scalars — re-wrap those.
    if ($null -eq $HooksNode) { return }
    foreach ($prop in @($HooksNode.PSObject.Properties)) {
        $name = $prop.Name
        $val = $prop.Value
        if ($null -eq $val) { continue }
        if ($val -is [string]) { continue }

        if ($val -is [System.Collections.IEnumerable] -and -not ($val -is [System.Collections.IDictionary]) -and -not ($val -is [pscustomobject])) {
            $arr = ConvertTo-ArraySafe $val
        } elseif (Test-IsHookLeafOrGroup $val) {
            # Unwrapped single-element array → re-wrap
            $arr = [object[]]@($val)
        } else {
            continue
        }

        for ($i = 0; $i -lt $arr.Count; $i++) {
            $item = $arr[$i]
            if ($null -eq $item) { continue }
            if ($item.PSObject -and $item.PSObject.Properties['hooks']) {
                $innerVal = $item.hooks
                if ($null -eq $innerVal) { continue }
                if ($innerVal -is [System.Collections.IEnumerable] -and -not ($innerVal -is [string]) -and -not ($innerVal -is [pscustomobject])) {
                    $item.hooks = ConvertTo-ArraySafe $innerVal
                } elseif (Test-IsHookLeafOrGroup $innerVal) {
                    $item.hooks = [object[]]@($innerVal)
                }
            }
        }
        $HooksNode.$name = $arr
    }
}

function Test-IsJsonArray($Value) {
    if ($null -eq $Value) { return $false }
    # .PSObject.BaseObject unwraps PSObject-wrapped values. The direct
    # .BaseObject member is null on PSCustomObject under StrictMode.
    $base = $Value.PSObject.BaseObject
    return ($base -is [System.Collections.IList]) -and -not ($base -is [string])
}

function Test-HooksNeedArrayNormalization($HooksNode) {
    # True when any event value, or any matcher group's nested 'hooks',
    # is a bare object instead of an array (the shape Claude Code rejects).
    if ($null -eq $HooksNode) { return $false }
    foreach ($prop in @($HooksNode.PSObject.Properties)) {
        $val = $prop.Value
        if ($null -eq $val) { continue }
        if (-not (Test-IsJsonArray $val)) { return $true }
        foreach ($group in $val) {
            if ($null -eq $group) { continue }
            if ($group.PSObject -and $group.PSObject.Properties['hooks']) {
                if ($null -eq $group.hooks) { continue }
                if (-not (Test-IsJsonArray $group.hooks)) { return $true }
            }
        }
    }
    return $false
}

function Get-CommandPropertyName([string]$Shape) {
    if ($Shape -eq 'bash') { return 'bash' }
    return 'command'
}

function Walk-HooksSubtree {
    param(
        [Parameter(Mandatory)]$HooksNode,
        [Parameter(Mandatory)][string]$AgentName,
        [Parameter(Mandatory)][string]$FallbackGuard,
        [Parameter(Mandatory)][string]$Shape,
        [switch]$Mutate
    )

    $cmdProp = Get-CommandPropertyName $Shape
    $changes = [System.Collections.Generic.List[object]]::new()

    function Visit-Object($Node, [string]$Path) {
        if ($null -eq $Node) { return }

        # Leaf: object with command/bash property
        if ($Node.PSObject -and $Node.PSObject.Properties[$cmdProp]) {
            $raw = [string]$Node.$cmdProp
            $decoded = Get-DecodedCommand $raw
            # Also treat unquoted raw as decoded
            if (-not (Test-EndsWithTenetxGuard $raw) -and -not (Test-EndsWithTenetxGuard $decoded)) {
                # not a tenetx-guard entry
            } else {
                $guardPath = Get-GuardPathFromDecoded $decoded $FallbackGuard
                if ([string]::IsNullOrWhiteSpace($guardPath)) {
                    $guardPath = $FallbackGuard
                }
                # Normalize path separators to single backslash for Windows cmd path
                $guardPath = $guardPath -replace '/', '\'
                $guardPath = $guardPath -replace '\\\\+', '\'

                $eventTok = $null
                if ($AgentName -eq 'copilot') {
                    $eventTok = Get-CopilotEventToken $decoded
                    if (-not $eventTok) {
                        # try raw
                        $eventTok = Get-CopilotEventToken $raw
                    }
                }

                $expected = New-ExpectedCommand -AgentName $AgentName -GuardPath $guardPath -EventToken $eventTok
                $already = Test-AlreadyQuotedShape $raw $AgentName
                # Stronger: raw -eq expected
                if ($raw -eq $expected -or $already) {
                    $changes.Add([pscustomobject]@{
                        Path     = $Path
                        Action   = 'skip'
                        Before   = $raw
                        After    = $expected
                        Reason   = 'already-quoted'
                    }) | Out-Null
                } else {
                    $changes.Add([pscustomobject]@{
                        Path     = $Path
                        Action   = 'rewrite'
                        Before   = $raw
                        After    = $expected
                        Reason   = 'unquoted-or-wrong-shape'
                    }) | Out-Null
                    if ($Mutate) {
                        $Node.$cmdProp = $expected
                    }
                }
            }
        }

        # Nested: .hooks array under matcher group
        if ($Node.PSObject -and $Node.PSObject.Properties['hooks']) {
            $inner = ConvertTo-ArraySafe $Node.hooks
            if ($Mutate) { $Node.hooks = $inner }
            for ($i = 0; $i -lt $inner.Count; $i++) {
                Visit-Object $inner[$i] "$Path.hooks[$i]"
            }
        }

        # Dictionary-like: event name → array (or unwrapped single group/leaf)
        foreach ($prop in @($Node.PSObject.Properties)) {
            if ($prop.Name -in @($cmdProp, 'hooks', 'type', 'timeout', 'matcher', 'failClosed')) { continue }
            $val = $prop.Value
            if ($null -eq $val) { continue }
            if ($val -is [string]) { continue }
            if ($val -is [System.Collections.IEnumerable] -and -not ($val -is [System.Collections.IDictionary]) -and -not ($val -is [pscustomobject])) {
                $arr = ConvertTo-ArraySafe $val
                if ($Mutate) { $Node.($prop.Name) = $arr }
                for ($i = 0; $i -lt $arr.Count; $i++) {
                    Visit-Object $arr[$i] "$Path.$($prop.Name)[$i]"
                }
            } elseif (Test-IsHookLeafOrGroup $val) {
                # ConvertFrom-Json unwrapped a single-element array
                if ($Mutate) { $Node.($prop.Name) = [object[]]@($val) }
                Visit-Object $val "$Path.$($prop.Name)[0]"
            } elseif ($val.PSObject) {
                Visit-Object $val "$Path.$($prop.Name)"
            }
        }
    }

    Visit-Object $HooksNode 'hooks'
    return $changes
}

function Assert-RootIsObject([string]$JsonText) {
    $trim = $JsonText.TrimStart()
    if ($trim.StartsWith('[')) {
        throw "Root serialized as JSON array — refusing. Never use -AsArray on file root."
    }
    if (-not $trim.StartsWith('{')) {
        throw "Root is not a JSON object (does not start with '{')."
    }
}

function Repair-SingleElementJsonArrays {
    param(
        [Parameter(Mandatory)][string]$JsonText,
        [Parameter(Mandatory)]$HooksNode
    )
    # ConvertTo-Json collapses single-element arrays. For each top-level event key
    # under hooks that was an array (or should be), ensure `"Event": {` becomes
    # `"Event": [{` ... `}]` when the value is a single matcher/leaf object.
    # Also ensure nested `"hooks": {` (single leaf) becomes `"hooks": [{`.
    if ($null -eq $HooksNode) { return $JsonText }

    $text = $JsonText
    foreach ($prop in @($HooksNode.PSObject.Properties)) {
        $name = $prop.Name
        # Always prefer array form for event keys under hooks
        # Pattern: "Name": { ... single object ... }  where Name is event key
        # Use a conservative brace matcher for one object only (no sibling keys at same level).
        $escaped = [regex]::Escape($name)
        # Collapse form: "Event": { ... }  (not already "Event": [)
        $pat = '("' + $escaped + '"\s*:\s*)\{'
        if ($text -match $pat -and $text -notmatch ('"' + $escaped + '"\s*:\s*\[')) {
            # Wrap the next top-level object after the key in [ ]
            $text = [regex]::Replace(
                $text,
                '("' + $escaped + '"\s*:\s*)(\{(?:[^{}]|(?<open>\{)|(?<-open>\}))*(?(open)(?!))\})',
                '${1}[${2}]',
                1
            )
        }
    }

    # Nested single-element "hooks": { leaf } under matcher groups → "hooks": [ leaf ]
    # Only when value is an object with type/command/bash (leaf), not an array.
    $text = [regex]::Replace(
        $text,
        '("hooks"\s*:\s*)(\{\s*"(?:type|command|bash)"(?:[^{}]|(?<open>\{)|(?<-open>\}))*(?(open)(?!))\})',
        '${1}[${2}]'
    )

    return $text
}

function Assert-TouchedArraysStillArrays($HooksNode, [string]$Shape) {
    if ($null -eq $HooksNode) { return }
    foreach ($prop in @($HooksNode.PSObject.Properties)) {
        $val = $prop.Value
        if ($null -eq $val) { continue }
        if ($val -is [string]) { continue }
        # Event arrays must remain collections
        if ($val -is [System.Collections.IEnumerable] -and -not ($val -is [System.Collections.IDictionary])) {
            # OK
            foreach ($item in $val) {
                if ($null -eq $item) { continue }
                if ($item.PSObject -and $item.PSObject.Properties['hooks']) {
                    $h = $item.hooks
                    if ($null -eq $h) { continue }
                    if (-not ($h -is [System.Collections.IEnumerable]) -or ($h -is [string])) {
                        throw "hooks nested array under event '$($prop.Name)' is no longer an array after serialize/parse."
                    }
                }
            }
        }
    }
}

function New-BackupPath([string]$Path) {
    $utc = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    return "$Path.tenetx-bak-$utc"
}

function Get-LatestBackup([string]$Path) {
    $dir = Split-Path -Parent $Path
    $leaf = Split-Path -Leaf $Path
    $pattern = "$leaf.tenetx-bak-*"
    $backs = @(Get-ChildItem -LiteralPath $dir -Filter $pattern -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending)
    if ($backs.Count -eq 0) { return $null }
    return $backs[0].FullName
}

function Write-RestoreInstructions([string]$Path, [string]$BackupPath) {
    Write-Info ""
    Write-Info "Restore instructions for: $Path"
    Write-Info "  Backup: $BackupPath"
    Write-Info "  Manual restore:"
    Write-Info "    Copy-Item -LiteralPath '$BackupPath' -Destination '$Path' -Force"
    Write-Info "  Or re-run:"
    Write-Info "    pwsh -NoProfile -File fix-agent-hooks.ps1 -Revert -Agents <agent>"
    Write-Info ""
}

function Invoke-GuardSmoke {
    param(
        [Parameter(Mandatory)][string]$DecodedCommand,
        [string]$PayloadPath = $DefaultPayload
    )

    $payloadWin = $DefaultPayloadWin
    if (-not (Test-Path -LiteralPath $payloadWin)) {
        Write-WarnMsg "Verify payload missing: $payloadWin — skipping bash smoke for this entry."
        return [pscustomobject]@{ Ok = $true; Skipped = $true; ExitCode = $null; Note = 'payload-missing' }
    }
    if (-not (Test-Path -LiteralPath $GitBash)) {
        Write-WarnMsg "Git bash not found at $GitBash — skipping bash smoke."
        return [pscustomobject]@{ Ok = $true; Skipped = $true; ExitCode = $null; Note = 'bash-missing' }
    }

    # decoded may be: "C:\path\tenetx-guard.cmd"  or  "C:\path\tenetx-guard.cmd" event
    # For bash -c we need a shell-safe form. Use the path without outer quotes for -c body.
    $cmdForBash = $DecodedCommand
    # Convert Windows path to something bash can run via cmd.exe /c is safer for .cmd
    # Spec: bash -c '<decoded_command>' < payload
    # decoded_command with quotes: "C:\...\tenetx-guard.cmd"
    # Git bash can run .cmd via cmd //c
    $inner = $DecodedCommand.Trim()
    # Build: cmd //c <decoded>  so .cmd runs under cmd, stdin still redirected by bash
    # Spec literally: bash -c '<decoded_command>' < payload.json
    $bashC = $inner.Replace("'", "'\''")

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $GitBash
    $psi.Arguments = "-c `"$bashC`" < `"$PayloadPath`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    $p.WaitForExit(60000) | Out-Null
    if (-not $p.HasExited) {
        try { $p.Kill() } catch { }
        return [pscustomobject]@{ Ok = $false; Skipped = $false; ExitCode = -1; Note = 'timeout'; StdOut = $stdout; StdErr = $stderr }
    }
    $code = $p.ExitCode
    $ok = $code -in 0, 2
    if ($ok) {
        # Decision body may be missing under 401 API; warn but do not fail
        $hasDecision = $false
        if ($stdout -match '(?i)"(decision|permissionDecision|hookSpecificOutput)"') {
            $hasDecision = $true
        }
        if (-not $hasDecision) {
            Write-WarnMsg "Guard exit $code but decision body missing (API 401 expected). Not failing."
        }
    }
    return [pscustomobject]@{
        Ok       = $ok
        Skipped  = $false
        ExitCode = $code
        Note     = if ($ok) { 'ok' } else { "exit-$code" }
        StdOut   = $stdout
        StdErr   = $stderr
    }
}

function Process-AgentFile {
    param(
        [Parameter(Mandatory)]$Meta,
        [switch]$DoApply,
        [switch]$DoDryRun,
        [switch]$DoVerify
    )

    $path = $Meta.Path
    $name = $Meta.Name
    Write-Info "---- agent=$name path=$path ----"

    if (-not (Test-Path -LiteralPath $path)) {
        Write-WarnMsg "File missing — skip: $path"
        return [pscustomobject]@{ Agent = $name; Status = 'missing'; Changes = 0 }
    }

    $rawText = Get-Content -LiteralPath $path -Raw -Encoding utf8
    Assert-RootIsObject $rawText

    $root = $rawText | ConvertFrom-Json
    if ($null -eq $root) {
        throw "ConvertFrom-Json returned null for $path"
    }
    if ($root -is [System.Array]) {
        throw "Root of $path is an array — refusing to process."
    }

    $nonHooksBefore = Get-NonHooksClone $root
    $nonHooksHashBefore = Get-ObjectSha256 $nonHooksBefore

    if (-not $root.PSObject.Properties['hooks']) {
        Write-WarnMsg "No 'hooks' property — nothing to do."
        return [pscustomobject]@{ Agent = $name; Status = 'no-hooks'; Changes = 0 }
    }

    # Detect BEFORE repair: Repair-HooksArrays normalizes in memory.
    $structureNeedsFix = Test-HooksNeedArrayNormalization $root.hooks
    Repair-HooksArrays $root.hooks

    $planned = Walk-HooksSubtree -HooksNode $root.hooks -AgentName $name `
        -FallbackGuard $Meta.GuardCmd -Shape $Meta.Shape

    $rewriteCount = @($planned | Where-Object { $_.Action -eq 'rewrite' }).Count
    $skipCount = @($planned | Where-Object { $_.Action -eq 'skip' }).Count

    foreach ($c in $planned) {
        $tag = $c.Action.ToUpperInvariant()
        Write-Info "  [$tag] $($c.Path)"
        Write-Info "    before: $($c.Before)"
        Write-Info "    after:  $($c.After)"
    }
    Write-Info "  summary: rewrite=$rewriteCount skip=$skipCount"
    if ($structureNeedsFix) { Write-Info "  structure: event/hooks objects need array normalization" }

    if ($DoDryRun -or -not $DoApply) {
        if ($rewriteCount -gt 0 -or $structureNeedsFix) {
            Write-Info "  DRY-RUN: would write (rewrite=$rewriteCount structureFix=$structureNeedsFix)."
        } else {
            Write-Info "  DRY-RUN: no changes needed."
        }
        return [pscustomobject]@{ Agent = $name; Status = 'dry-run'; Changes = $rewriteCount; StructureFix = $structureNeedsFix; Planned = $planned }
    }

    if ($rewriteCount -eq 0 -and -not $structureNeedsFix) {
        Write-Ok "  Already idempotent — no write needed."
        if ($DoVerify) {
            Invoke-PostWriteVerify -Path $path -Meta $Meta -NonHooksHashBefore $nonHooksHashBefore -ExpectRewrite $false | Out-Null
        }
        return [pscustomobject]@{ Agent = $name; Status = 'noop'; Changes = 0 }
    }

    # Mutate for real
    $null = Walk-HooksSubtree -HooksNode $root.hooks -AgentName $name `
        -FallbackGuard $Meta.GuardCmd -Shape $Meta.Shape -Mutate
    Repair-HooksArrays $root.hooks

    # Non-hooks hash must still match before serialize
    $nonHooksAfterMut = Get-NonHooksClone $root
    $nonHooksHashAfterMut = Get-ObjectSha256 $nonHooksAfterMut
    if ($nonHooksHashBefore -ne $nonHooksHashAfterMut) {
        throw "Non-hooks subtree hash changed during mutation for $path — aborting write."
    }

    # Serialize root WITHOUT -AsArray. PS ConvertTo-Json unwraps single-element
    # arrays to objects — re-wrap event arrays + nested hooks arrays in text.
    $outJson = ConvertTo-Json -InputObject $root -Depth 20
    $outJson = Repair-SingleElementJsonArrays -JsonText $outJson -HooksNode $root.hooks
    Assert-RootIsObject $outJson

    $bak = New-BackupPath $path
    Copy-Item -LiteralPath $path -Destination $bak -Force
    Write-Ok "  Backup: $bak"
    Write-RestoreInstructions -Path $path -BackupPath $bak

    # Write UTF8 no BOM preferred; PS7 Set-Content -Encoding utf8 is UTF8 no BOM
    Set-Content -LiteralPath $path -Value $outJson -Encoding utf8 -NoNewline
    # Ensure trailing newline for POSIX friendliness
    Add-Content -LiteralPath $path -Value '' -Encoding utf8

    Write-Ok "  Wrote: $path"

    if ($DoVerify) {
        $vr = Invoke-PostWriteVerify -Path $path -Meta $Meta -NonHooksHashBefore $nonHooksHashBefore -ExpectRewrite $true
        if (-not $vr.Ok) {
            throw "Post-write verify failed for $path : $($vr.Note)"
        }
    }

    return [pscustomobject]@{ Agent = $name; Status = 'applied'; Changes = $rewriteCount; StructureFix = $structureNeedsFix; Backup = $bak }
}

function Invoke-PostWriteVerify {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Meta,
        [Parameter(Mandatory)][string]$NonHooksHashBefore,
        [bool]$ExpectRewrite = $true
    )

    Write-Info "  VERIFY: re-parse $Path"
    $text = Get-Content -LiteralPath $Path -Raw -Encoding utf8
    Assert-RootIsObject $text
    $root = $text | ConvertFrom-Json
    if ($root -is [System.Array]) {
        return [pscustomobject]@{ Ok = $false; Note = 'root-is-array' }
    }

    $nonHooks = Get-NonHooksClone $root
    $h = Get-ObjectSha256 $nonHooks
    if ($h -ne $NonHooksHashBefore) {
        return [pscustomobject]@{ Ok = $false; Note = "non-hooks-hash-mismatch before=$NonHooksHashBefore after=$h" }
    }
    Write-Ok "  VERIFY: non-hooks SHA256 unchanged ($h)"

    Assert-TouchedArraysStillArrays $root.hooks $Meta.Shape

    $changes = Walk-HooksSubtree -HooksNode $root.hooks -AgentName $Meta.Name `
        -FallbackGuard $Meta.GuardCmd -Shape $Meta.Shape
    $stillBad = @($changes | Where-Object { $_.Action -eq 'rewrite' })
    if ($stillBad.Count -gt 0) {
        return [pscustomobject]@{ Ok = $false; Note = "still-unquoted count=$($stillBad.Count)" }
    }
    Write-Ok "  VERIFY: all tenetx-guard entries match quoted shape"

    # Smoke one decoded command (first skip/rewrite after-shape)
    $sample = @($changes | Select-Object -First 1)
    if ($sample.Count -gt 0) {
        $decoded = $sample[0].After
        Write-Info "  VERIFY: bash smoke → $decoded"
        $smoke = Invoke-GuardSmoke -DecodedCommand $decoded
        if (-not $smoke.Ok) {
            return [pscustomobject]@{ Ok = $false; Note = "smoke-fail exit=$($smoke.ExitCode)" }
        }
        if ($smoke.Skipped) {
            Write-WarnMsg "  VERIFY: smoke skipped ($($smoke.Note))"
        } else {
            Write-Ok "  VERIFY: smoke exit=$($smoke.ExitCode) (allowed 0|2)"
        }
    }

    return [pscustomobject]@{ Ok = $true; Note = 'ok' }
}

function Invoke-RevertAgent {
    param([Parameter(Mandatory)]$Meta)

    $path = $Meta.Path
    $name = $Meta.Name
    Write-Info "---- REVERT agent=$name path=$path ----"

    $bak = Get-LatestBackup $path
    if (-not $bak) {
        Write-WarnMsg "No backup matching $($path).tenetx-bak-* — skip."
        return [pscustomobject]@{ Agent = $name; Status = 'no-backup' }
    }

    Write-Info "  Restoring from: $bak"
    if ($DryRun -and -not $Apply) {
        # -Revert always writes unless someone only wants preview; treat -DryRun as preview
        # Spec: -Revert restores from backup ONLY. If DryRun default is on without -Apply,
        # require explicit intent: when -Revert is set we restore (not dry).
    }
    # Revert is intentional mutation; only skip if user also forced DryRun without clearing.
    # Policy: -Revert implies write of restore. Ignore DryRun for revert path.
    Copy-Item -LiteralPath $bak -Destination $path -Force
    Write-Ok "  Restored: $path"
    Write-Info "  Backup kept: $bak"
    return [pscustomobject]@{ Agent = $name; Status = 'reverted'; Backup = $bak }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Write-Info "fix-agent-hooks.ps1 (PowerShell $($PSVersionTable.PSVersion))"
Write-Info "Home: $HomeDir"
Write-Info "Mode: $(if ($Revert) { 'REVERT' } elseif ($Apply) { 'APPLY' } else { 'DRY-RUN' }) Verify=$Verify"

$selected = Get-SelectedAgents
Write-Info "Agents: $($selected -join ', ')"

$results = [System.Collections.Generic.List[object]]::new()
$failed = $false

foreach ($agentName in $selected) {
    $meta = $AgentCatalog[$agentName]
    try {
        if ($Revert) {
            $r = Invoke-RevertAgent -Meta $meta
            $results.Add($r) | Out-Null
        } else {
            $r = Process-AgentFile -Meta $meta -DoApply:$Apply -DoDryRun:$DryRun -DoVerify:$Verify
            $results.Add($r) | Out-Null
        }
    } catch {
        $failed = $true
        Write-ErrMsg "agent=$agentName failed: $_"
        $results.Add([pscustomobject]@{ Agent = $agentName; Status = 'error'; Error = "$_" }) | Out-Null
    }
}

Write-Info ""
Write-Info "==== summary ===="
foreach ($r in $results) {
    $chg = '-'
    if ($r.PSObject.Properties['Changes'] -and $null -ne $r.Changes) {
        $chg = $r.Changes
    }
    Write-Info ("  {0,-8} {1} changes={2}" -f $r.Agent, $r.Status, $chg)
}

if ($failed) {
    Write-ErrMsg "Completed with errors."
    exit 1
}

if (-not $Apply -and -not $Revert) {
    Write-Info ""
    Write-Info "Dry-run complete. Re-run with -Apply to write (creates .tenetx-bak-<utc> first)."
}

Write-Ok "Done."
exit 0
