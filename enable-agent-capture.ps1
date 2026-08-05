<#
.SYNOPSIS
    Enable / disable / reset / status for local TenetX agent capture (TENETX_AGENT_CAPTURE).

.DESCRIPTION
    Installed hooks gate raw capture with:
      os.environ.get("TENETX_AGENT_CAPTURE", "<baked-default>") == "1"
    Baked default is usually "0" unless the org was in server TENETX_CAPTURE_ORGS at
    hook install/update. This script sets the *client* override so capture works
    without reinstalling hooks.

    "Fully enable" means:
      1) process env TENETX_AGENT_CAPTURE=1 (this shell)
      2) durable User env on Windows ([Environment]::SetEnvironmentVariable User)
      3) launchctl setenv on macOS (session-usable for GUI agents launched after)

    "Disable" writes '0' (not unset) so the variable is explicitly false.
    "Reset" removes User var and unsets process env entirely.

    Server-side TENETX_CAPTURE_ORGS is not set by this script (API/compose concern;
    client override is enough for already-installed guards).

.EXAMPLE
    # Status (default non-interactive action)
    pwsh -NoProfile -NonInteractive -File enable-agent-capture.ps1

.EXAMPLE
    # Enable via CLI switch
    pwsh -NoProfile -File enable-agent-capture.ps1 -Enable

.EXAMPLE
    # Enable via env var
    $env:TENETX_CAPTURE_ACTION='enable'; pwsh -NoProfile -NonInteractive -File enable-agent-capture.ps1

.EXAMPLE
    # Dry-run: print what would be set without mutating
    $env:TENETX_CAPTURE_ACTION='enable'; $env:TENETX_CAPTURE_DRY_RUN='1'; pwsh -NoProfile -File enable-agent-capture.ps1

.NOTES
    Restart coding agents (Cursor / Claude / Codex / Copilot) after enable/disable/reset so
    their hook child processes inherit the updated environment.
#>
[CmdletBinding()]
param(
    [switch]$Enable,
    [switch]$Disable,
    [switch]$Status,
    [switch]$Reset,
    [switch]$Help,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$VarName = 'TENETX_AGENT_CAPTURE'
$EnableValue = '1'
$DisableValue = '0'

# True only for a real interactive console: a redirected/piped stdin, a
# non-console host, or -NonInteractive must never reach Read-Host.
function Test-Interactive {
    if ([Console]::IsInputRedirected) { return $false }
    if (-not [Environment]::UserInteractive) { return $false }
    if ($Host.Name -ne 'ConsoleHost') { return $false }
    return $true
}

# Resolve action: CLI switches (highest priority) > env var > default to status
# CLI wins over env. NEVER default to enable.
$action = $null

if ($Help) {
    $action = 'help'
} elseif ($Enable) {
    $action = 'enable'
} elseif ($Disable) {
    $action = 'disable'
} elseif ($Reset) {
    $action = 'reset'
} elseif ($Status) {
    $action = 'status'
}

# If no CLI switch, check env var
if ($null -eq $action -and $env:TENETX_CAPTURE_ACTION) {
    $action = $env:TENETX_CAPTURE_ACTION.ToLower()
    # Validate env action
    if ($action -notin @('enable', 'disable', 'status', 'reset', 'help')) {
        $action = $null
    }
}

# If still no action, try interactive menu (Test-Interactive covers stdin/host)
if ($null -eq $action -and (Test-Interactive)) {
    Write-Host ""
    Write-Host "TenetX agent capture control"
    Write-Host "=========================="
    Write-Host "1. Status (show current state)"
    Write-Host "2. Enable"
    Write-Host "3. Disable"
    Write-Host "4. Reset"
    Write-Host "5. Help"
    Write-Host "6. Exit"
    Write-Host ""
    $choice = $null
    try { $choice = Read-Host "Select action [1-6]" } catch { $choice = $null }
    $choiceMap = @{
        '1' = 'status'
        '2' = 'enable'
        '3' = 'disable'
        '4' = 'reset'
        '5' = 'help'
        '6' = $null
    }
    $action = $choiceMap[$choice]
    if ($choice -eq '6') {
        exit 0
    }
}

# Default action: status
if ($null -eq $action) {
    $action = 'status'
}

# Check for dry-run
$isDryRun = $DryRun -or ($env:TENETX_CAPTURE_DRY_RUN -eq '1')

function Write-Say([string]$Message) {
    Write-Host $Message
}

function Write-Ok([string]$Message) {
    Write-Host $Message -ForegroundColor Green
}

function Write-WarnMsg([string]$Message) {
    Write-Host "WARN: $Message" -ForegroundColor Yellow
}

function Test-IsWindows {
    return ($env:OS -eq 'Windows_NT') -or ($IsWindows -eq $true)
}

function Test-IsMacOS {
    if ($IsMacOS -eq $true) { return $true }
    try {
        return ((uname -s 2>$null) -eq 'Darwin')
    } catch {
        return $false
    }
}

function Get-HomeDir {
    if ($env:USERPROFILE) { return $env:USERPROFILE }
    if ($env:HOME) { return $env:HOME }
    return [Environment]::GetFolderPath('UserProfile')
}

function Get-ProcessCapture {
    return [Environment]::GetEnvironmentVariable($VarName, 'Process')
}

function Get-UserCapture {
    if (-not (Test-IsWindows)) { return $null }
    try {
        return [Environment]::GetEnvironmentVariable($VarName, 'User')
    } catch {
        return $null
    }
}

function Get-LaunchctlCapture {
    if (-not (Test-IsMacOS)) { return $null }
    if (-not (Get-Command launchctl -ErrorAction SilentlyContinue)) { return $null }
    try {
        $out = & launchctl getenv $VarName 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        if ([string]::IsNullOrWhiteSpace($out)) { return $null }
        return $out.Trim()
    } catch {
        return $null
    }
}

function Set-ProcessCapture([string]$Value) {
    if ($null -eq $Value -or $Value -eq '') {
        # Remove from this process
        Remove-Item -LiteralPath "Env:$VarName" -ErrorAction SilentlyContinue
    } else {
        Set-Item -LiteralPath "Env:$VarName" -Value $Value
    }
}

function Set-UserCapture([string]$Value) {
    if (-not (Test-IsWindows)) {
        return $false
    }
    [Environment]::SetEnvironmentVariable($VarName, $Value, 'User')
    return $true
}

function Set-LaunchctlCapture([string]$Value) {
    if (-not (Test-IsMacOS)) { return $false }
    if (-not (Get-Command launchctl -ErrorAction SilentlyContinue)) { return $false }
    if ($null -eq $Value -or $Value -eq '') {
        & launchctl unsetenv $VarName 2>$null | Out-Null
    } else {
        & launchctl setenv $VarName $Value
        if ($LASTEXITCODE -ne 0) {
            throw "launchctl setenv $VarName failed (exit $LASTEXITCODE)"
        }
    }
    return $true
}

function Get-GuardInstalls {
    $homeDir = Get-HomeDir
    $tenetx = if ($env:TENETX_CONFIG_DIR) { $env:TENETX_CONFIG_DIR } else { Join-Path $homeDir '.tenetx' }
    return @(
        [pscustomobject]@{ Label = 'codex';   Path = (Join-Path $tenetx 'hooks/codex/tenetx-guard.py') }
        [pscustomobject]@{ Label = 'claude';  Path = (Join-Path $homeDir '.claude/hooks/tenetx-guard.py') }
        [pscustomobject]@{ Label = 'cursor';  Path = (Join-Path $homeDir '.cursor/hooks/tenetx-guard.py') }
        [pscustomobject]@{ Label = 'copilot'; Path = (Join-Path $homeDir '.copilot/hooks/tenetx-guard.py') }
    )
}

function Get-BakedDefault([string]$GuardPath) {
    if (-not (Test-Path -LiteralPath $GuardPath)) { return $null }
    try {
        $hit = Select-String -LiteralPath $GuardPath -Pattern 'environ\.get\(\s*"TENETX_AGENT_CAPTURE"' |
            Select-Object -First 1
        if (-not $hit) { return '?' }
        # os.environ.get("TENETX_AGENT_CAPTURE", '0')  or  ,"0")
        if ($hit.Line -match 'TENETX_AGENT_CAPTURE"\s*,\s*[''"]([^''"]*)[''"]') {
            return $Matches[1]
        }
        return '?'
    } catch {
        return '?'
    }
}

function Show-Status {
    Write-Say ""
    Write-Say "=== TenetX agent capture status ==="
    Write-Say "Var: $VarName (client override; not TENETX_CAPTURE)"
    Write-Say ""

    $proc = Get-ProcessCapture
    $user = Get-UserCapture
    $lc = Get-LaunchctlCapture

    Write-Say ("process:   {0}" -f $(if ($null -eq $proc -or $proc -eq '') { '<unset>' } else { $proc }))
    if (Test-IsWindows) {
        Write-Say ("User env:  {0}" -f $(if ($null -eq $user -or $user -eq '') { '<unset>' } else { $user }))
    } else {
        Write-Say "User env:  (n/a — Windows only; same pattern as install.ps1 PATH)"
    }
    if (Test-IsMacOS) {
        Write-Say ("launchctl: {0}" -f $(if ($null -eq $lc -or $lc -eq '') { '<unset>' } else { $lc }))
    } else {
        Write-Say "launchctl: (n/a — macOS only)"
    }

    Write-Say ""
    Write-Say "Installed guards (baked default when env unset):"
    $any = $false
    foreach ($g in Get-GuardInstalls) {
        if (Test-Path -LiteralPath $g.Path) {
            $any = $true
            $baked = Get-BakedDefault -GuardPath $g.Path
            Write-Say ("  {0,-8} baked={1}  {2}" -f $g.Label, $baked, $g.Path)
        } else {
            Write-Say ("  {0,-8} (not installed)" -f $g.Label)
        }
    }
    if (-not $any) {
        Write-WarnMsg "No tenetx-guard.py found — login/install hooks before expecting capture."
    }

    Write-Say ""
    $effectiveOn = ($proc -eq $EnableValue) -or `
        ($user -eq $EnableValue) -or `
        ($lc -eq $EnableValue)
    # Effective for *new* agent processes: prefer durable/session sources.
    $sessionOn = $false
    if (Test-IsWindows) {
        $sessionOn = ($user -eq $EnableValue) -or ($proc -eq $EnableValue)
    } elseif (Test-IsMacOS) {
        $sessionOn = ($lc -eq $EnableValue) -or ($proc -eq $EnableValue)
    } else {
        $sessionOn = ($proc -eq $EnableValue)
    }

    if ($sessionOn) {
        Write-Ok "Effective: ON (restart agents if they were already running)."
    } else {
        Write-Say "Effective: OFF (run without -Status / -Disable to enable)."
    }
    if ($effectiveOn -and -not $sessionOn) {
        Write-WarnMsg "Some layers set; durable/session layer may still be missing."
    }
}

function Enable-Capture {
    if ($isDryRun) {
        Write-Say "DRY-RUN: Would enable agent capture ($VarName=$EnableValue)"
        Write-Say "WOULD_SET process=$EnableValue"
        if (Test-IsWindows) {
            Write-Say "WOULD_SET User=$EnableValue"
        }
        return
    }

    Write-Say "Enabling local agent capture ($VarName=$EnableValue) ..."
    Set-ProcessCapture -Value $EnableValue
    Write-Ok "  process:   $EnableValue"

    if (Set-UserCapture -Value $EnableValue) {
        Write-Ok "  User env:  $EnableValue (persisted; new terminals/apps after restart)"
    }

    if (Set-LaunchctlCapture -Value $EnableValue) {
        Write-Ok "  launchctl: $EnableValue (this login session; GUI agents started after this)"
    }

    Write-Say ""
    Write-WarnMsg "Restart Cursor / Claude Code / Codex / Copilot so hooks inherit $VarName."
    Write-Say "Server TENETX_CAPTURE_ORGS is unchanged (client override is enough for installed hooks)."
    Show-Status
}

function Disable-Capture {
    if ($isDryRun) {
        Write-Say "DRY-RUN: Would disable agent capture ($VarName=$DisableValue)"
        Write-Say "WOULD_SET process=$DisableValue"
        if (Test-IsWindows) {
            Write-Say "WOULD_SET User=$DisableValue"
        }
        return
    }

    Write-Say "Disabling local agent capture ($VarName=$DisableValue) ..."
    Set-ProcessCapture -Value $DisableValue
    Write-Ok "  process:   $DisableValue"

    if (Set-UserCapture -Value $DisableValue) {
        Write-Ok "  User env:  $DisableValue (persisted; new terminals/apps after restart)"
    }

    if (Set-LaunchctlCapture -Value $DisableValue) {
        Write-Ok "  launchctl: $DisableValue (this login session)"
    }

    Write-Say ""
    Write-WarnMsg "Restart coding agents so they drop the old env."
    Show-Status
}

function Reset-Capture {
    if ($isDryRun) {
        Write-Say "DRY-RUN: Would reset agent capture (remove User var, unset process env)"
        Write-Say "WOULD_UNSET process"
        if (Test-IsWindows) {
            Write-Say "WOULD_UNSET User"
        }
        return
    }

    Write-Say "Resetting local agent capture (removing User var, unsetting process env) ..."
    Set-ProcessCapture -Value $null
    Write-Ok "  process:   unset"

    if (Set-UserCapture -Value $null) {
        Write-Ok "  User env:  removed"
    }

    if (Set-LaunchctlCapture -Value $null) {
        Write-Ok "  launchctl: unset"
    }

    Write-Say ""
    Write-WarnMsg "Restart coding agents so they drop the old env."
    Show-Status
}

function Show-Help {
    Write-Say ""
    Write-Say "TenetX agent capture control"
    Write-Say ""
    Write-Say "SYNOPSIS"
    Write-Say "  Enable / disable / reset / status for local agent capture (TENETX_AGENT_CAPTURE)"
    Write-Say ""
    Write-Say "USAGE"
    Write-Say "  enable-agent-capture.ps1 [-Enable | -Disable | -Reset | -Status | -Help]"
    Write-Say "  enable-agent-capture.ps1 [-DryRun]"
    Write-Say ""
    Write-Say "PARAMETERS"
    Write-Say "  -Enable      Enable agent capture (set TENETX_AGENT_CAPTURE=1)"
    Write-Say "  -Disable     Disable agent capture (set TENETX_AGENT_CAPTURE=0)"
    Write-Say "  -Reset       Reset to unset (remove User var, unset process env)"
    Write-Say "  -Status      Show current capture status (default if no action specified)"
    Write-Say "  -Help        Show this help message"
    Write-Say "  -DryRun      Plan-only; print what would change without mutating"
    Write-Say ""
    Write-Say "ENVIRONMENT VARIABLES"
    Write-Say "  TENETX_CAPTURE_ACTION   Set action: enable, disable, reset, status, help"
    Write-Say "  TENETX_CAPTURE_DRY_RUN  Set to '1' to enable dry-run mode"
    Write-Say ""
    Write-Say "ACTION RESOLUTION"
    Write-Say "  1. CLI switches (highest priority: -Enable, -Disable, -Reset, -Status, -Help)"
    Write-Say "  2. TENETX_CAPTURE_ACTION environment variable"
    Write-Say "  3. Interactive menu (if stdin is available)"
    Write-Say "  4. Default: status (never defaults to enable)"
    Write-Say ""
    Write-Say "EXAMPLES"
    Write-Say "  # Status (default non-interactive)"
    Write-Say "  pwsh -NoProfile -NonInteractive -File enable-agent-capture.ps1"
    Write-Say ""
    Write-Say "  # Enable via CLI"
    Write-Say "  pwsh -NoProfile -File enable-agent-capture.ps1 -Enable"
    Write-Say ""
    Write-Say "  # Enable via env var"
    Write-Say "  `$env:TENETX_CAPTURE_ACTION='enable'; pwsh -NoProfile -File enable-agent-capture.ps1"
    Write-Say ""
    Write-Say "  # Dry-run"
    Write-Say "  `$env:TENETX_CAPTURE_ACTION='enable'; `$env:TENETX_CAPTURE_DRY_RUN='1'; pwsh -File enable-agent-capture.ps1"
    Write-Say ""
}

# Execute the action
switch ($action) {
    'status'  { Show-Status }
    'disable' { Disable-Capture }
    'reset'   { Reset-Capture }
    'help'    { Show-Help }
    default   { Enable-Capture }
}
