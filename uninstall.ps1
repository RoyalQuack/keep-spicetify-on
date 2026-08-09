[CmdletBinding()]
param(
    [switch] $RemoveData,
    [switch] $UnblockSpotifyUpdates
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'src\Core.ps1')
. (Join-Path $PSScriptRoot 'src\Startup.ps1')

Write-Host ''
Write-Host '  KeepSpicetifyOn - uninstall' -ForegroundColor Cyan
Write-Host '  ===========================' -ForegroundColor Cyan
Write-Host ''

$stopped = 0
$procs = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -match '-File\s+"?[^"]*KeepSpicetifyOn\.ps1' } |
    Where-Object { $_.ProcessId -ne $PID }

foreach ($p in $procs) {
    try {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
        $stopped++
    } catch {
        Write-Host "  [!] Could not stop PID $($p.ProcessId): $($_.Exception.Message)" -ForegroundColor Yellow
    }
}
if ($stopped -gt 0) {
    Write-Host "  [ok] Stopped $stopped running tray instance(s)." -ForegroundColor Green
} else {
    Write-Host '  [--] No running tray instance found.' -ForegroundColor DarkGray
}

try {
    if (Unregister-KsoStartupTask) {
        Write-Host "  [ok] Removed logon task '$(Get-KsoTaskName)'." -ForegroundColor Green
    } else {
        Write-Host '  [--] No logon task was registered.' -ForegroundColor DarkGray
    }
} catch {
    Write-Host "  [!] Could not remove the logon task: $($_.Exception.Message)" -ForegroundColor Yellow
}

if ($UnblockSpotifyUpdates) {
    $r = Set-SpotifyUpdateBlocking -Enabled $false
    $c = if ($r.Success) { 'Green' } else { 'Yellow' }
    Write-Host "  [ok] $($r.Message)" -ForegroundColor $c
} else {
    $cfg = Get-KsoConfig
    if ($cfg.blockSpotifyUpdates) {
        Write-Host ''
        Write-Host '  [!] Spotify auto-updates are still BLOCKED.' -ForegroundColor Yellow
        Write-Host '      Re-run with -UnblockSpotifyUpdates to allow Spotify to update again.'
    }
}

if ($RemoveData) {
    $dir = Get-KsoDataDir
    if (Test-Path -LiteralPath $dir) {
        Remove-Item -LiteralPath $dir -Recurse -Force
        Write-Host "  [ok] Removed $dir" -ForegroundColor Green
    }
} else {
    Write-Host "  [--] Kept config and log in $(Get-KsoDataDir)" -ForegroundColor DarkGray
    Write-Host '       Re-run with -RemoveData to delete them.' -ForegroundColor DarkGray
}

Write-Host ''
Write-Host '  Done. Spotify and Spicetify were not modified.' -ForegroundColor Green
Write-Host ''
