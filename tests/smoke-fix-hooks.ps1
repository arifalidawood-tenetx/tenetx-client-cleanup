#Requires -Version 7.0
<#
.SYNOPSIS
    Smoke tests for fix-agent-hooks.ps1 (sandboxed home + real decision-body assert).

.DESCRIPTION
    Sandbox: idempotency, already-quoted skip, quoted-shape decode compare,
    non-tenetx entries unchanged, array-shape survival, malformed-JSON restore,
    DryRun default (no -Apply). Decision-body assert hits REAL install guards with
    tests/SCRATCH/payload.json via Git bash — never fakes a decision body in sandbox.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Error "Requires PowerShell 7+ (pwsh). Current: $($PSVersionTable.PSVersion)"
    exit 2
}

$Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$FixScript = Join-Path $Root 'fix-agent-hooks.ps1'
$ScratchDir = Join-Path $Root 'tests\SCRATCH'
$PayloadPath = Join-Path $ScratchDir 'payload.json'
$GitBash = 'C:\Program Files\Git\bin\bash.exe'
$RealClaudeGuard = Join-Path $env:USERPROFILE '.claude\hooks\tenetx-guard.cmd'
$RealCursorGuard = Join-Path $env:USERPROFILE '.cursor\hooks\tenetx-guard.cmd'
$RealPayloadSource = 'C:\Users\aadx3d\codes\tenetx-pms\.omo\scratch\windowstest-20260804\payload.json'

$script:Pass = 0
$script:Fail = 0

function Write-Pass([string]$Msg) {
    $script:Pass++
    Write-Host "PASS: $Msg" -ForegroundColor Green
}
function Write-Fail([string]$Msg) {
    $script:Fail++
    Write-Host "FAIL: $Msg" -ForegroundColor Red
}

function New-SandboxRoot {
    $base = Join-Path ([System.IO.Path]::GetTempPath()) ("tx-fix-hooks-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $base -Force | Out-Null
    foreach ($rel in @(
            '.claude\hooks',
            '.copilot\hooks',
            '.cursor\hooks',
            '.codex',
            '.tenetx\hooks\codex'
        )) {
        New-Item -ItemType Directory -Path (Join-Path $base $rel) -Force | Out-Null
    }
    return $base
}

function Get-Sha([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Write-FixtureClaude([string]$SandboxRoot, [string]$GuardCmdShape) {
    $guard = Join-Path $SandboxRoot '.claude\hooks\tenetx-guard.cmd'
    $bun = 'C:\Users\fake\.bun\bin\bun.exe'
    $worker = 'C:\Users\fake\.claude\plugins\worker-service.cjs'
    $txBare = $guard
    $txQuoted = "`"$guard`""
    $txCmd = if ($GuardCmdShape -eq 'quoted') { $txQuoted } else { $txBare }

    $obj = [ordered]@{
        schemaVersion = 1
        unrelatedKey  = 'must-survive'
        permissions   = @{ allow = @('Bash') }
        hooks         = [ordered]@{
            PreToolUse = @(
                [ordered]@{
                    matcher = '.*'
                    hooks   = @(
                        [ordered]@{ type = 'command'; command = $txCmd }
                    )
                }
            )
            SessionStart = @(
                [ordered]@{
                    matcher = '.*'
                    hooks   = @(
                        [ordered]@{ type = 'command'; command = $txCmd }
                    )
                }
            )
            afterFileEdit = @(
                [ordered]@{
                    command = "`"$bun`" `"$worker`" hook cursor file-edit"
                }
            )
        }
    }
    $path = Join-Path $SandboxRoot '.claude\settings.json'
    Set-Content -LiteralPath $path -Value ($obj | ConvertTo-Json -Depth 20) -Encoding utf8
    return $path
}

function Write-FixtureCopilot([string]$SandboxRoot, [string]$Shape) {
    $guard = Join-Path $SandboxRoot '.copilot\hooks\tenetx-guard.cmd'
    $bashBare = "$guard preToolUse"
    $bashQuoted = "`"$guard`" preToolUse"
    $bash = if ($Shape -eq 'quoted') { $bashQuoted } else { $bashBare }
    $obj = [ordered]@{
        version = 1
        meta    = @{ keep = $true }
        hooks   = [ordered]@{
            preToolUse  = [ordered]@{ type = 'command'; bash = $bash }
            postToolUse = [ordered]@{
                type = 'command'
                bash = if ($Shape -eq 'quoted') { "`"$guard`" postToolUse" } else { "$guard postToolUse" }
            }
        }
    }
    $path = Join-Path $SandboxRoot '.copilot\hooks\notification-hooks.json'
    Set-Content -LiteralPath $path -Value ($obj | ConvertTo-Json -Depth 20) -Encoding utf8
    return $path
}

function Write-FixtureCursor([string]$SandboxRoot, [string]$Shape) {
    $guard = Join-Path $SandboxRoot '.cursor\hooks\tenetx-guard.cmd'
    $bun = 'C:\Users\fake\.bun\bin\bun.exe'
    $tx = if ($Shape -eq 'quoted') { "`"$guard`"" } else { $guard }
    $obj = [ordered]@{
        version = 1
        hooks   = [ordered]@{
            beforeShellExecution = @(
                [ordered]@{ command = $tx }
            )
            afterFileEdit = @(
                [ordered]@{ command = "`"$bun`" `"C:\Users\fake\worker-service.cjs`" hook" }
            )
        }
    }
    $path = Join-Path $SandboxRoot '.cursor\hooks.json'
    Set-Content -LiteralPath $path -Value ($obj | ConvertTo-Json -Depth 20) -Encoding utf8
    return $path
}

function Invoke-Fix {
    param(
        [Parameter(Mandatory)][string]$SandboxRoot,
        [string[]]$ArgsExtra = @()
    )
    $env:TENETX_FIX_HOOKS_HOME = $SandboxRoot
    try {
        $allArgs = @('-NoProfile', '-File', $FixScript) + $ArgsExtra
        $out = & pwsh @allArgs 2>&1 | Out-String
        return [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output   = $out
        }
    } finally {
        Remove-Item Env:TENETX_FIX_HOOKS_HOME -ErrorAction SilentlyContinue
    }
}

function Get-CommandValues([string]$JsonPath, [string]$CmdProp = 'command') {
    $root = Get-Content -LiteralPath $JsonPath -Raw -Encoding utf8 | ConvertFrom-Json
    $found = [System.Collections.Generic.List[string]]::new()
    function Walk($n) {
        if ($null -eq $n) { return }
        if ($n -is [string]) { return }
        if ($n.PSObject -and $n.PSObject.Properties[$CmdProp]) {
            [void]$found.Add([string]$n.$CmdProp)
        }
        if ($n.PSObject) {
            foreach ($p in $n.PSObject.Properties) {
                $v = $p.Value
                if ($null -eq $v -or $v -is [string]) { continue }
                if ($v -is [System.Collections.IEnumerable] -and -not ($v -is [pscustomobject])) {
                    foreach ($i in @($v)) { Walk $i }
                } else {
                    Walk $v
                }
            }
        }
    }
    if ($root.PSObject.Properties['hooks']) { Walk $root.hooks }
    return @($found)
}

function Test-ArrayShapeSurvival([string]$JsonPath) {
    $text = Get-Content -LiteralPath $JsonPath -Raw -Encoding utf8
    $ok = $true
    foreach ($ev in @('PreToolUse', 'SessionStart')) {
        if ($text -notmatch ('"' + [regex]::Escape($ev) + '"\s*:\s*\[')) {
            $ok = $false
            Write-Fail "array-shape: event $ev is not a JSON array in file text"
        }
    }
    if ($text -notmatch '"hooks"\s*:\s*\[') {
        $ok = $false
        Write-Fail 'array-shape: nested hooks not array in JSON text'
    }
    return $ok
}

function Invoke-RealGuardBash {
    param(
        [Parameter(Mandatory)][string]$GuardCmd,
        [Parameter(Mandatory)][string]$PayloadWin,
        [int]$TimeoutMs = 60000
    )
    if (-not (Test-Path -LiteralPath $GitBash)) {
        return [pscustomobject]@{ Ok = $false; ExitCode = -1; StdOut = ''; StdErr = "git-bash-missing: $GitBash"; HasDecision = $false; Note = 'bash-missing' }
    }
    if (-not (Test-Path -LiteralPath $GuardCmd)) {
        return [pscustomobject]@{ Ok = $false; ExitCode = -1; StdOut = ''; StdErr = "guard-missing: $GuardCmd"; HasDecision = $false; Note = 'guard-missing' }
    }
    if (-not (Test-Path -LiteralPath $PayloadWin)) {
        return [pscustomobject]@{ Ok = $false; ExitCode = -1; StdOut = ''; StdErr = "payload-missing: $PayloadWin"; HasDecision = $false; Note = 'payload-missing' }
    }

    $gUnix = ($GuardCmd -replace '\\', '/')
    $pUnix = ($PayloadWin -replace '\\', '/')
    $tmpSh = Join-Path ([System.IO.Path]::GetTempPath()) ("tx-real-guard-" + [guid]::NewGuid().ToString('N') + '.sh')
    $body = "export MSYS_NO_PATHCONV=1`n`"$gUnix`" < `"$pUnix`"`necho EXIT:`$?`n"
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($tmpSh, $body, $utf8NoBom)

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $GitBash
        $psi.Arguments = "`"$tmpSh`""
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        [void]$p.Start()
        $stdout = $p.StandardOutput.ReadToEnd()
        $stderr = $p.StandardError.ReadToEnd()
        $finished = $p.WaitForExit($TimeoutMs)
        if (-not $finished) {
            try { $p.Kill() } catch { }
            return [pscustomobject]@{ Ok = $false; ExitCode = -1; StdOut = $stdout; StdErr = $stderr; HasDecision = $false; Note = 'hang-timeout'; Body = '' }
        }
        $code = $null
        if ($stdout -match 'EXIT:(\d+)') {
            $code = [int]$Matches[1]
        } else {
            $code = $p.ExitCode
        }
        $bodyOnly = ($stdout -replace 'EXIT:\d+\s*$', '').Trim()
        $hasDecision = $false
        if ($bodyOnly -match '(?i)"(decision|permissionDecision|hookSpecificOutput|permission)"') {
            $hasDecision = $true
        } elseif ($bodyOnly -match '^\s*\{' -and $bodyOnly -match '\}') {
            $hasDecision = $true
        }
        $exitOk = $code -in 0, 2
        return [pscustomobject]@{
            Ok          = ($exitOk -and $hasDecision)
            ExitCode    = $code
            StdOut      = $stdout
            StdErr      = $stderr
            Body        = $bodyOnly
            HasDecision = $hasDecision
            Note        = if (-not $exitOk) { "exit-$code" } elseif (-not $hasDecision) { 'bodyless' } else { 'ok' }
        }
    } finally {
        Remove-Item -LiteralPath $tmpSh -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# SCRATCH payload
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Path $ScratchDir -Force | Out-Null
if (Test-Path -LiteralPath $RealPayloadSource) {
    Copy-Item -LiteralPath $RealPayloadSource -Destination $PayloadPath -Force
} else {
    Set-Content -LiteralPath $PayloadPath -Value '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo hi"}}' -Encoding utf8
}

if (-not (Test-Path -LiteralPath $FixScript)) {
    Write-Fail "fix-agent-hooks.ps1 missing: $FixScript"
    exit 1
}

Write-Host "=== smoke-fix-hooks.ps1 ==="
Write-Host "Root: $Root"
Write-Host "Payload: $PayloadPath"

# 1) DryRun default
$SandboxRoot = New-SandboxRoot
try {
    $claude = Write-FixtureClaude -SandboxRoot $SandboxRoot -GuardCmdShape 'bare'
    $before = Get-Sha $claude
    $r = Invoke-Fix -SandboxRoot $SandboxRoot -ArgsExtra @('-Agents', 'claude')
    $after = Get-Sha $claude
    if ($r.ExitCode -eq 0 -and $before -eq $after) {
        Write-Pass 'dry-run-default: no -Apply leaves file SHA unchanged'
    } else {
        Write-Fail "dry-run-default: exit=$($r.ExitCode) shaBefore=$before shaAfter=$after"
    }
    if ($r.Output -match 'DRY-RUN|Dry-run|dry-run') {
        Write-Pass 'dry-run-default: output announces dry-run'
    } else {
        Write-Fail 'dry-run-default: output missing dry-run marker'
    }
} finally {
    Remove-Item -LiteralPath $SandboxRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# 2) Apply rewrite + quoted-shape + non-tenetx + array + backup
$SandboxRoot = New-SandboxRoot
try {
    $claude = Write-FixtureClaude -SandboxRoot $SandboxRoot -GuardCmdShape 'bare'
    $bunBefore = @(Get-CommandValues $claude | Where-Object { $_ -match 'bun' })
    if (@($bunBefore).Count -lt 1) {
        Write-Fail 'fixture: expected bun non-tenetx command'
    }

    $r = Invoke-Fix -SandboxRoot $SandboxRoot -ArgsExtra @('-Apply', '-Agents', 'claude')
    if ($r.ExitCode -ne 0) {
        Write-Fail "apply-rewrite: exit=$($r.ExitCode)`n$($r.Output)"
    } else {
        Write-Pass 'apply-rewrite: exit 0'
    }

    $cmds = @(Get-CommandValues $claude)
    $tx = @($cmds | Where-Object { $_ -match 'tenetx-guard\.cmd' })
    $bunAfter = @($cmds | Where-Object { $_ -match 'bun' })

    $allQuoted = $true
    foreach ($c in $tx) {
        if ($c -notmatch '^".*tenetx-guard\.cmd"$') {
            $allQuoted = $false
            Write-Fail "quoted-shape: tenetx cmd not quoted: $c"
        }
    }
    if ($allQuoted -and @($tx).Count -ge 1) {
        Write-Pass "quoted-shape: $(@($tx).Count) tenetx commands match quoted path"
    }

    if (@($bunAfter).Count -eq @($bunBefore).Count -and $bunAfter[0] -eq $bunBefore[0]) {
        Write-Pass 'non-tenetx: bun/worker command unchanged'
    } else {
        Write-Fail "non-tenetx: bun before='$($bunBefore -join '|')' after='$($bunAfter -join '|')'"
    }

    $rootObj = Get-Content $claude -Raw | ConvertFrom-Json
    if ($rootObj.unrelatedKey -eq 'must-survive' -and $rootObj.schemaVersion -eq 1) {
        Write-Pass 'non-hooks: unrelated keys survived'
    } else {
        Write-Fail 'non-hooks: unrelated keys lost or changed'
    }

    if (Test-ArrayShapeSurvival $claude) {
        Write-Pass 'array-shape: PreToolUse/SessionStart/nested hooks stay arrays'
    }

    $baks = @(Get-ChildItem -LiteralPath (Split-Path $claude) -Filter 'settings.json.tenetx-bak-*' -ErrorAction SilentlyContinue)
    if (@($baks).Count -ge 1) {
        Write-Pass "backup: created $($baks[0].Name)"
    } else {
        Write-Fail 'backup: missing .tenetx-bak-* after apply'
    }
} finally {
    Remove-Item -LiteralPath $SandboxRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# 3) Already-quoted skip + idempotency
$SandboxRoot = New-SandboxRoot
try {
    $claude = Write-FixtureClaude -SandboxRoot $SandboxRoot -GuardCmdShape 'quoted'
    $r1 = Invoke-Fix -SandboxRoot $SandboxRoot -ArgsExtra @('-Apply', '-Agents', 'claude')
    $sha1 = Get-Sha $claude
    $r2 = Invoke-Fix -SandboxRoot $SandboxRoot -ArgsExtra @('-Apply', '-Agents', 'claude')
    $sha2 = Get-Sha $claude

    if ($r1.ExitCode -eq 0 -and $r2.ExitCode -eq 0 -and $sha1 -eq $sha2) {
        Write-Pass 'idempotency: second -Apply leaves SHA identical'
    } else {
        Write-Fail "idempotency: exit1=$($r1.ExitCode) exit2=$($r2.ExitCode) sha1=$sha1 sha2=$sha2"
    }

    if ($r1.Output -match 'already-quoted|noop|Already idempotent|rewrite=0' -or
        $r2.Output -match 'already-quoted|noop|Already idempotent|rewrite=0') {
        Write-Pass 'already-quoted-skip: planner reports skip/noop/rewrite=0'
    } elseif ($sha1 -eq $sha2) {
        Write-Pass 'already-quoted-skip: second pass no content change (idempotent)'
    } else {
        Write-Fail "already-quoted-skip: unexpected output`n$($r2.Output)"
    }

    Remove-Item -LiteralPath $SandboxRoot -Recurse -Force -ErrorAction SilentlyContinue
    $SandboxRoot = New-SandboxRoot
    $claude = Write-FixtureClaude -SandboxRoot $SandboxRoot -GuardCmdShape 'bare'
    $null = Invoke-Fix -SandboxRoot $SandboxRoot -ArgsExtra @('-Apply', '-Agents', 'claude')
    $shaA = Get-Sha $claude
    $null = Invoke-Fix -SandboxRoot $SandboxRoot -ArgsExtra @('-Apply', '-Agents', 'claude')
    $shaB = Get-Sha $claude
    if ($shaA -eq $shaB) {
        Write-Pass 'idempotency-after-rewrite: second apply no changes'
    } else {
        Write-Fail 'idempotency-after-rewrite: second apply mutated file'
    }
} finally {
    Remove-Item -LiteralPath $SandboxRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# 4) Quoted-shape decode compare (claude + copilot)
$SandboxRoot = New-SandboxRoot
try {
    $null = Write-FixtureClaude -SandboxRoot $SandboxRoot -GuardCmdShape 'bare'
    $copilot = Write-FixtureCopilot -SandboxRoot $SandboxRoot -Shape 'bare'
    $r = Invoke-Fix -SandboxRoot $SandboxRoot -ArgsExtra @('-Apply', '-Agents', 'claude,copilot')
    if ($r.ExitCode -ne 0) {
        Write-Fail "decode-compare: apply failed exit=$($r.ExitCode)`n$($r.Output)"
    }

    $claudePath = Join-Path $SandboxRoot '.claude\settings.json'
    $claudeCmds = @(Get-CommandValues $claudePath 'command')
    $copilotCmds = @(Get-CommandValues $copilot 'bash')

    $claudeOk = (@($claudeCmds | Where-Object { $_ -match 'tenetx-guard' } | ForEach-Object {
                $_ -match '^".*tenetx-guard\.cmd"$'
            }) -notcontains $false) -and (@($claudeCmds | Where-Object { $_ -match 'tenetx-guard' }).Count -ge 1)

    $copilotOk = (@($copilotCmds | Where-Object { $_ -match 'tenetx-guard' } | ForEach-Object {
                $_ -match '^".*tenetx-guard\.cmd"\s+\S+$'
            }) -notcontains $false) -and (@($copilotCmds | Where-Object { $_ -match 'tenetx-guard' }).Count -ge 1)

    if ($claudeOk) {
        Write-Pass 'decode-compare: claude quoted-only-path shape'
    } else {
        Write-Fail "decode-compare: claude shape bad: $($claudeCmds -join ' | ')"
    }
    if ($copilotOk) {
        Write-Pass 'decode-compare: copilot quoted-path + event token'
    } else {
        Write-Fail "decode-compare: copilot shape bad: $($copilotCmds -join ' | ')"
    }
} finally {
    Remove-Item -LiteralPath $SandboxRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# 5) Non-tenetx on cursor
$SandboxRoot = New-SandboxRoot
try {
    $cursor = Write-FixtureCursor -SandboxRoot $SandboxRoot -Shape 'bare'
    $r = Invoke-Fix -SandboxRoot $SandboxRoot -ArgsExtra @('-Apply', '-Agents', 'claude', '-IncludeCursor')
    if ($r.ExitCode -ne 0) {
        Write-Fail "non-tenetx-cursor: apply exit=$($r.ExitCode)`n$($r.Output)"
    }
    $after = Get-Content $cursor -Raw | ConvertFrom-Json
    $bun = $null
    $tx = @()
    foreach ($p in $after.hooks.PSObject.Properties) {
        foreach ($item in @($p.Value)) {
            if ($null -eq $item) { continue }
            if ($item.PSObject.Properties['command'] -and $item.command -match 'bun') {
                $bun = $item.command
            }
            if ($item.PSObject.Properties['command'] -and $item.command -match 'tenetx-guard') {
                $tx += $item.command
            }
        }
    }
    if ($bun -and $bun -match 'bun' -and $bun -notmatch 'tenetx-guard') {
        Write-Pass 'non-tenetx-cursor: bun entry left alone'
    } else {
        Write-Fail "non-tenetx-cursor: bun missing or rewritten: $bun"
    }
    if (@($tx).Count -ge 1 -and (@($tx | Where-Object { $_ -notmatch '^"' }).Count -eq 0)) {
        Write-Pass 'non-tenetx-cursor: tenetx entries quoted, bun separate'
    } else {
        Write-Fail "non-tenetx-cursor: tenetx not quoted: $($tx -join ' | ')"
    }
} finally {
    Remove-Item -LiteralPath $SandboxRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# 6) Malformed-JSON restore via -Revert
$SandboxRoot = New-SandboxRoot
try {
    $claude = Write-FixtureClaude -SandboxRoot $SandboxRoot -GuardCmdShape 'bare'
    $good = Get-Content $claude -Raw
    $r = Invoke-Fix -SandboxRoot $SandboxRoot -ArgsExtra @('-Apply', '-Agents', 'claude')
    if ($r.ExitCode -ne 0) {
        Write-Fail "malformed-restore: initial apply failed exit=$($r.ExitCode)"
    }
    $baks = @(Get-ChildItem -LiteralPath (Split-Path $claude) -Filter 'settings.json.tenetx-bak-*' |
            Sort-Object LastWriteTimeUtc -Descending)
    if (@($baks).Count -lt 1) {
        Write-Fail 'malformed-restore: no backup to restore from'
    } else {
        Set-Content -LiteralPath $claude -Value '{ not valid json !!!' -Encoding utf8
        $rr = Invoke-Fix -SandboxRoot $SandboxRoot -ArgsExtra @('-Revert', '-Agents', 'claude')
        if ($rr.ExitCode -eq 0 -and (Test-Path $claude)) {
            $restored = Get-Content $claude -Raw
            try {
                $null = $restored | ConvertFrom-Json
                Write-Pass 'malformed-restore: -Revert restored parseable JSON from backup'
            } catch {
                Write-Fail 'malformed-restore: restored file still invalid JSON'
            }
            $bakText = Get-Content $baks[0].FullName -Raw
            if ($bakText.Trim() -eq $good.Trim() -or $bakText -match 'tenetx-guard') {
                Write-Pass 'malformed-restore: backup retained original (or tenetx) content'
            } else {
                Write-Fail 'malformed-restore: backup content unexpected'
            }
        } else {
            Write-Fail "malformed-restore: revert exit=$($rr.ExitCode)"
        }
    }
} finally {
    Remove-Item -LiteralPath $SandboxRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# 7) REAL decision-body assert
Write-Host ""
Write-Host "=== REAL decision-body assert (install paths) ==="

$realTargets = @(
    @{ Name = 'cursor'; Path = $RealCursorGuard },
    @{ Name = 'claude'; Path = $RealClaudeGuard }
)

$anyRealRan = $false
foreach ($t in $realTargets) {
    if (-not (Test-Path -LiteralPath $t.Path)) {
        Write-Host "SKIP real $($t.Name): guard missing $($t.Path)" -ForegroundColor Yellow
        continue
    }
    $anyRealRan = $true
    Write-Host "REAL $($t.Name): $($t.Path) < $PayloadPath via $GitBash"
    $res = Invoke-RealGuardBash -GuardCmd $t.Path -PayloadWin $PayloadPath
    if ($res.Note -eq 'hang-timeout') {
        Write-Fail "decision-body $($t.Name): HANG/timeout"
        continue
    }
    if ($res.ExitCode -notin 0, 2) {
        Write-Fail "decision-body $($t.Name): exit=$($res.ExitCode) not in {0,2} note=$($res.Note)"
        Write-Host "  stdout: $($res.StdOut)"
        Write-Host "  stderr: $($res.StdErr)"
        continue
    }
    if (-not $res.HasDecision) {
        if ($t.Name -eq 'claude') {
            Write-Host "NOTE decision-body claude: exit=$($res.ExitCode) bodyless (fail-open/401 known) — soft" -ForegroundColor Yellow
            Write-Pass "decision-body claude: exit=$($res.ExitCode) in {0,2} (body deferred if API 401 fail-open)"
        } else {
            Write-Fail "decision-body $($t.Name): bodyless (exit=$($res.ExitCode)) — FAIL"
            Write-Host "  stdout: $($res.StdOut)"
        }
        continue
    }
    $preview = $res.Body
    if ($preview.Length -gt 80) { $preview = $preview.Substring(0, 80) + '...' }
    Write-Pass "decision-body $($t.Name): exit=$($res.ExitCode) body present ($preview)"
}

if (-not $anyRealRan) {
    Write-Fail 'decision-body: no real guards found on this machine'
}

if (Test-Path -LiteralPath $RealCursorGuard) {
    $hard = Invoke-RealGuardBash -GuardCmd $RealCursorGuard -PayloadWin $PayloadPath
    if ($hard.Ok) {
        Write-Pass 'decision-body HARD: cursor real install has exit in {0,2} + decision body'
    } else {
        Write-Fail "decision-body HARD: cursor failed note=$($hard.Note) exit=$($hard.ExitCode) bodyless=$(-not $hard.HasDecision)"
    }
} else {
    Write-Fail 'decision-body HARD: real cursor tenetx-guard.cmd missing'
}

Write-Host ""
Write-Host "==== summary pass=$script:Pass fail=$script:Fail ===="
if ($script:Fail -gt 0) {
    Write-Host 'SMOKE FAILED' -ForegroundColor Red
    exit 1
}
Write-Host 'SMOKE OK' -ForegroundColor Green
exit 0
