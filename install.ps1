# shunt-local installer for Windows (PowerShell).
#
# Registers the PreToolUse guard for Antigravity and Cursor and installs the
# configuration. The bash CLI tools (bulk-read/code-write/task-exec) need Git
# Bash or WSL; this script prints a note if neither is on PATH.
#
# Usage:  powershell -ExecutionPolicy Bypass -File install.ps1

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigDir = Join-Path $HOME '.config\shunt-local'
$GuardWin  = Join-Path $ScriptDir 'hooks\shunt_guard.py'

function Resolve-Python {
    foreach ($candidate in @('python', 'python3', 'py')) {
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    return $null
}

$Python = Resolve-Python
if (-not $Python) {
    Write-Error 'python3 is required. Install Python 3 and re-run this script.'
    exit 1
}
Write-Host "Using Python: $Python"

function Write-Json($Path, $Object) {
    $json = $Object | ConvertTo-Json -Depth 20
    Set-Content -Path $Path -Value $json -Encoding UTF8
}

function Read-Json($Path) {
    if (Test-Path $Path) {
        try { return Get-Content -Raw $Path | ConvertFrom-Json } catch { }
    }
    return [pscustomobject]@{}
}

# 1. Configuration
New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
$ConfigPath = Join-Path $ConfigDir 'config.json'
if (-not (Test-Path $ConfigPath)) {
    Copy-Item (Join-Path $ScriptDir 'config.example.json') $ConfigPath
    Write-Host "Created default config at $ConfigPath"
}
# Restrict the config (which may hold an API key) to the current user.
try {
    icacls $ConfigPath /inheritance:r /grant:r "$($env:USERNAME):(R,W)" | Out-Null
} catch { Write-Warning "Could not tighten ACL on $ConfigPath" }

# 2. PreToolUse guard commands
$GuardQuoted = '"' + $GuardWin + '"'
function GuardCmd([string]$Kind) { return "$Python $GuardQuoted --kind $Kind" }
function CursorCmd([string]$Kind) { return "$Python $GuardQuoted --harness cursor --kind $Kind" }

# 3. Antigravity hooks (~/.gemini/config/hooks.json)
$GeminiDir = Join-Path $HOME '.gemini'
if (Test-Path $GeminiDir) {
    $GeminiCfgDir = Join-Path $GeminiDir 'config'
    New-Item -ItemType Directory -Force -Path $GeminiCfgDir | Out-Null
    $HooksFile = Join-Path $GeminiCfgDir 'hooks.json'
    $cfg = Read-Json $HooksFile
    $groups = @(
        [pscustomobject]@{ matcher = 'view_file'; hooks = @([pscustomobject]@{ type = 'command'; command = (GuardCmd 'read') }) },
        [pscustomobject]@{ matcher = 'run_command'; hooks = @([pscustomobject]@{ type = 'command'; command = (GuardCmd 'bash') }) },
        [pscustomobject]@{ matcher = 'write_to_file|replace_file_content|multi_replace_file_content'; hooks = @([pscustomobject]@{ type = 'command'; command = (GuardCmd 'write') }) }
    )
    $cfg | Add-Member -Force -NotePropertyName 'shunt-local' -NotePropertyValue ([pscustomobject]@{ PreToolUse = $groups })
    Write-Json $HooksFile $cfg
    Write-Host "Registered Antigravity hooks in $HooksFile"
}

# 4. Cursor hooks (~/.cursor/hooks.json)
$CursorDir = Join-Path $HOME '.cursor'
if (Test-Path $CursorDir) {
    $CursorFile = Join-Path $CursorDir 'hooks.json'
    $cfg = Read-Json $CursorFile
    if (-not $cfg.version) { $cfg | Add-Member -Force -NotePropertyName version -NotePropertyValue 1 }
    if (-not $cfg.hooks) { $cfg | Add-Member -Force -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) }
    $existing = @()
    if ($cfg.hooks.preToolUse) {
        $existing = @($cfg.hooks.preToolUse | Where-Object { $_.command -notmatch 'shunt_guard\.py' })
    }
    $entries = @(
        [pscustomobject]@{ matcher = 'Read'; command = (CursorCmd 'read') },
        [pscustomobject]@{ matcher = 'Shell'; command = (CursorCmd 'bash') },
        [pscustomobject]@{ matcher = 'Write'; command = (CursorCmd 'write') }
    )
    $cfg.hooks | Add-Member -Force -NotePropertyName preToolUse -NotePropertyValue ($existing + $entries)
    $before = @()
    if ($cfg.hooks.beforeReadFile) {
        $before = @($cfg.hooks.beforeReadFile | Where-Object { $_.command -notmatch 'shunt_guard\.py' })
    }
    $cfg.hooks | Add-Member -Force -NotePropertyName beforeReadFile -NotePropertyValue ($before + [pscustomobject]@{ matcher = 'Read'; command = (CursorCmd 'read') })
    Write-Json $CursorFile $cfg
    Write-Host "Registered Cursor hooks in $CursorFile"
}

if (-not (Get-Command bash -ErrorAction SilentlyContinue)) {
    Write-Host "NOTE: Git Bash or WSL is required to run the bulk-read/code-write/task-exec CLI tools."
}
Write-Host "shunt-local (Windows) installation complete."
