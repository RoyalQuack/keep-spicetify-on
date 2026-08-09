[CmdletBinding()]
param(
    [switch] $NoStart,
    [switch] $NoTask
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -Filter *.ps1 -ErrorAction SilentlyContinue |
    Unblock-File -ErrorAction SilentlyContinue

. (Join-Path $PSScriptRoot 'src\Core.ps1')
. (Join-Path $PSScriptRoot 'src\Startup.ps1')

Write-Host ''
Write-Host '  KeepSpicetifyOn - install' -ForegroundColor Cyan
Write-Host '  =========================' -ForegroundColor Cyan
Write-Host ''

$spicetify = Resolve-SpicetifyExe
if (-not $spicetify) {
    Write-Host '  [X] Spicetify is not installed.' -ForegroundColor Red
    Write-Host ''
    Write-Host '      KeepSpicetifyOn keeps an existing Spicetify install working;'
    Write-Host '      it does not install Spicetify for you. Install it first:'
    Write-Host ''
    Write-Host '        https://spicetify.app/docs/getting-started' -ForegroundColor Cyan
    Write-Host ''
    exit 1
}
Write-Host "  [ok] Spicetify  : $spicetify" -ForegroundColor Green

$spotifyRoot = Get-SpotifyRoot
if (-not $spotifyRoot) {
    Write-Host '  [X] No Spotify installation was found.' -ForegroundColor Red
    Write-Host '      The Microsoft Store build of Spotify is not supported by Spicetify.'
    Write-Host '      Install the desktop build from https://www.spotify.com/download/windows/'
    exit 1
}
Write-Host "  [ok] Spotify    : $spotifyRoot" -ForegroundColor Green

Initialize-KsoDataDir | Out-Null
if (-not (Test-Path -LiteralPath (Get-KsoConfigPath))) {
    Save-KsoConfig (Get-KsoDefaultConfig)
    Write-Host "  [ok] Config     : $(Get-KsoConfigPath) (created)" -ForegroundColor Green
} else {
    Write-Host "  [ok] Config     : $(Get-KsoConfigPath) (kept)" -ForegroundColor Green
}

if (-not $NoTask) {
    try {
        Register-KsoStartupTask
        Write-Host "  [ok] Startup    : logon task '$(Get-KsoTaskName)' registered" -ForegroundColor Green
    } catch {
        Write-Host "  [!] Could not register the logon task: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host '      You can still run the tray app manually.'
    }
} else {
    Write-Host '  [--] Startup    : skipped (-NoTask)' -ForegroundColor DarkGray
}

Write-Host ''
$status = Get-SpicetifyStatus
if ($status.State -eq 'Healthy') {
    Write-Host "  [ok] Spicetify is currently applied (Spotify $($status.SpotifyVersion))." -ForegroundColor Green
} else {
    Write-Host "  [!] $($status.Reason)" -ForegroundColor Yellow
    if ($status.SpotifyRunning) {
        Write-Host '      Spotify is running - the tray app will repair it once you close Spotify.'
    } else {
        Write-Host '      Repairing now...'
        $r = Invoke-SpicetifyRepair
        $c = if ($r.Repaired) { 'Green' } else { 'Red' }
        Write-Host "      $($r.Message)" -ForegroundColor $c
    }
}

if (-not $NoStart) {
    $tray = Join-Path $PSScriptRoot 'src\KeepSpicetifyOn.ps1'
    $launcher = Join-Path $PSScriptRoot 'src\launcher.vbs'

    if (Test-Path -LiteralPath $launcher) {
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\wscript.exe') `
            -ArgumentList @('//nologo', "`"$launcher`"")
    } else {
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Start-Process -FilePath $psExe -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden',
            '-ExecutionPolicy', 'Bypass', '-File', "`"$tray`""
        )
    }
    Write-Host ''
    Write-Host '  [ok] Tray app started - look for the dot in your system tray.' -ForegroundColor Green
    Write-Host '       Green = Spicetify on, red = off, grey = paused.'
}

Write-Host ''
Write-Host "  Log: $(Get-KsoLogPath)" -ForegroundColor DarkGray
Write-Host '  To remove it later: double-click Uninstall.bat' -ForegroundColor DarkGray
Write-Host ''
