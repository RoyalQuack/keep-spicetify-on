$script:KsoDataDir = Join-Path $env:LOCALAPPDATA 'KeepSpicetifyOn'
$script:KsoLogPath = Join-Path $script:KsoDataDir 'log.txt'
$script:KsoConfigPath = Join-Path $script:KsoDataDir 'config.json'

function Get-KsoDataDir { $script:KsoDataDir }
function Get-KsoLogPath { $script:KsoLogPath }
function Get-KsoConfigPath { $script:KsoConfigPath }

function Initialize-KsoDataDir {
    if (-not (Test-Path -LiteralPath $script:KsoDataDir)) {
        New-Item -ItemType Directory -Path $script:KsoDataDir -Force | Out-Null
    }
    $script:KsoDataDir
}

function Get-KsoDefaultConfig {
    [pscustomobject]@{
        checkIntervalSeconds = 300
        repairPolicy         = 'WaitForSpotifyExit'
        repairOnStartup      = $true
        blockSpotifyUpdates  = $false
        notifications        = $true
        autoUpdate           = $true
        updateCheckHours     = 24
    }
}

function Get-KsoConfig {
    $config = Get-KsoDefaultConfig
    if (-not (Test-Path -LiteralPath $script:KsoConfigPath)) { return $config }

    try {
        $raw = Get-Content -LiteralPath $script:KsoConfigPath -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $config }
        $loaded = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-KsoLog "Config unreadable, using defaults: $($_.Exception.Message)" 'WARN'
        return $config
    }

    foreach ($prop in $config.PSObject.Properties.Name) {
        if ($loaded.PSObject.Properties.Name -contains $prop) {
            $config.$prop = $loaded.$prop
        }
    }
    $config
}

function Save-KsoConfig {
    param([Parameter(Mandatory)] $Config)
    Initialize-KsoDataDir | Out-Null
    $Config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:KsoConfigPath -Encoding utf8
}

function Write-KsoLog {
    param(
        [Parameter(Mandatory)][string] $Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string] $Level = 'INFO'
    )
    try {
        Initialize-KsoDataDir | Out-Null
        $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        $line = "[$stamp] [$Level] $Message" + [Environment]::NewLine
        $encoding = New-Object System.Text.UTF8Encoding($false)

        for ($attempt = 0; $attempt -lt 5; $attempt++) {
            try {
                [System.IO.File]::AppendAllText($script:KsoLogPath, $line, $encoding)
                break
            } catch {
                Start-Sleep -Milliseconds 120
            }
        }

        $item = Get-Item -LiteralPath $script:KsoLogPath -ErrorAction SilentlyContinue
        if ($item -and $item.Length -gt 512KB) {
            $keep = Get-Content -LiteralPath $script:KsoLogPath -Tail 500
            Set-Content -LiteralPath $script:KsoLogPath -Value $keep -Encoding utf8
        }
    } catch {
    }
}

function Resolve-SpicetifyExe {
    $onPath = Get-Command 'spicetify' -CommandType Application -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }

    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'spicetify\spicetify.exe'),
        (Join-Path $env:APPDATA 'spicetify\spicetify.exe')
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    $null
}

function Get-SpicetifyConfigPath {
    Join-Path $env:APPDATA 'spicetify\config-xpui.ini'
}

function Read-IniSectionValue {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Section,
        [Parameter(Mandatory)][string] $Key
    )
    if (-not (Test-Path -LiteralPath $Path)) { return $null }

    $inSection = $false
    foreach ($line in (Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^\[(.+)\]$') {
            $inSection = ($Matches[1] -eq $Section)
            continue
        }
        if (-not $inSection) { continue }
        if ($trimmed -match '^\s*([^;=]+?)\s*=\s*(.*?)\s*$') {
            if ($Matches[1] -eq $Key) { return $Matches[2] }
        }
    }
    $null
}

function Get-SpotifyRoot {
    $fromConfig = Read-IniSectionValue -Path (Get-SpicetifyConfigPath) -Section 'Setting' -Key 'spotify_path'
    if ($fromConfig -and (Test-Path -LiteralPath $fromConfig)) { return $fromConfig }

    $default = Join-Path $env:APPDATA 'Spotify'
    if (Test-Path -LiteralPath $default) { return $default }
    $null
}

function Get-SpotifyVersion {
    param([string] $SpotifyRoot)
    if (-not $SpotifyRoot) { return $null }
    $exe = Join-Path $SpotifyRoot 'Spotify.exe'
    if (-not (Test-Path -LiteralPath $exe)) { return $null }
    (Get-Item -LiteralPath $exe).VersionInfo.FileVersion
}

function Get-SpicetifyBackupVersion {
    Read-IniSectionValue -Path (Get-SpicetifyConfigPath) -Section 'Backup' -Key 'version'
}

function Get-VersionCore {
    param([string] $Version)
    if ([string]::IsNullOrWhiteSpace($Version)) { return '' }

    $parts = @()
    foreach ($segment in ($Version -split '\.')) {
        if ($segment -match '^\d+$') { $parts += $segment } else { break }
    }
    $parts -join '.'
}

function Test-VersionMatch {
    param([string] $SpotifyVersion, [string] $BackupVersion)
    $a = Get-VersionCore $SpotifyVersion
    $b = Get-VersionCore $BackupVersion
    if ([string]::IsNullOrWhiteSpace($a) -or [string]::IsNullOrWhiteSpace($b)) { return $false }
    $a -eq $b
}

function Get-XpuiMarkerState {
    param([Parameter(Mandatory)][string] $SpotifyRoot)

    $appsDir = Join-Path $SpotifyRoot 'Apps'
    $result = [pscustomobject]@{ Source = 'None'; Patched = $false }

    $folderIndex = Join-Path $appsDir 'xpui\index.html'
    if (Test-Path -LiteralPath $folderIndex) {
        $result.Source = 'Folder'
        try {
            $text = Get-Content -LiteralPath $folderIndex -Raw -ErrorAction Stop
            $result.Patched = [bool]($text -match 'spicetify')
        } catch {
            Write-KsoLog "Could not read $folderIndex : $($_.Exception.Message)" 'WARN'
        }
        return $result
    }

    $spa = Join-Path $appsDir 'xpui.spa'
    if (Test-Path -LiteralPath $spa) {
        $result.Source = 'Archive'
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
            $zip = [System.IO.Compression.ZipFile]::OpenRead($spa)
            try {
                $entry = $zip.Entries | Where-Object { $_.FullName -eq 'index.html' } | Select-Object -First 1
                if ($entry) {
                    $reader = New-Object System.IO.StreamReader($entry.Open())
                    try { $result.Patched = [bool]($reader.ReadToEnd() -match 'spicetify') }
                    finally { $reader.Dispose() }
                }
            } finally { $zip.Dispose() }
        } catch {
            Write-KsoLog "Could not inspect $spa : $($_.Exception.Message)" 'WARN'
        }
    }
    $result
}

function Hide-SpotifyWindow {
    if (-not ('Kso.WindowUtil' -as [type])) {
        try {
            Add-Type -Namespace Kso -Name WindowUtil -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@ -ErrorAction Stop
        } catch {
            return
        }
    }

    $deadline = (Get-Date).AddSeconds(20)
    $hidden = $false

    while ((Get-Date) -lt $deadline -and -not $hidden) {
        foreach ($p in (Get-SpotifyProcess)) {
            try {
                $p.Refresh()
                if ($p.MainWindowHandle -ne [IntPtr]::Zero) {
                    [Kso.WindowUtil]::ShowWindow($p.MainWindowHandle, 6) | Out-Null
                    $hidden = $true
                }
            } catch { }
        }
        if (-not $hidden) { Start-Sleep -Milliseconds 700 }
    }

    if ($hidden) { Write-KsoLog 'Minimised the Spotify window opened by the repair.' }
    $hidden
}

function Restart-SpotifyMinimised {
    $exe = $null
    $root = Get-SpotifyRoot
    if ($root) { $exe = Join-Path $root 'Spotify.exe' }
    if (-not $exe -or -not (Test-Path -LiteralPath $exe)) { return $false }

    foreach ($p in (Get-SpotifyProcess)) {
        try { $p.CloseMainWindow() | Out-Null } catch { }
    }
    Start-Sleep -Milliseconds 1200
    foreach ($p in (Get-SpotifyProcess)) {
        try { $p.Kill() } catch { }
    }
    Start-Sleep -Milliseconds 1200

    Start-Process -FilePath $exe -ArgumentList '--minimized' -WindowStyle Minimized
    Write-KsoLog 'Restarted Spotify so it loads the restored theme.'
    Hide-SpotifyWindow | Out-Null
    $true
}

function Test-SpotifyArchiveRestored {
    param([Parameter(Mandatory)][string] $SpotifyRoot)
    Test-Path -LiteralPath (Join-Path $SpotifyRoot 'Apps\xpui.spa')
}

function Get-SpotifyProcess {
    Get-Process -Name 'Spotify' -ErrorAction SilentlyContinue
}

function Get-SpicetifyStatus {
    [CmdletBinding()]
    param()

    $status = [pscustomobject]@{
        State           = 'Unknown'
        Reason          = ''
        SpicetifyExe    = Resolve-SpicetifyExe
        SpotifyRoot     = $null
        SpotifyVersion  = $null
        BackupVersion   = $null
        MarkerSource    = 'None'
        Patched         = $false
        VersionMatch    = $false
        ArchiveRestored = $false
        SpotifyRunning  = [bool](Get-SpotifyProcess)
        CheckedAt       = Get-Date
    }

    if (-not $status.SpicetifyExe) {
        $status.State = 'SpicetifyNotInstalled'
        $status.Reason = 'spicetify.exe was not found on PATH or in the usual install locations.'
        return $status
    }

    $status.SpotifyRoot = Get-SpotifyRoot
    if (-not $status.SpotifyRoot) {
        $status.State = 'SpotifyNotInstalled'
        $status.Reason = 'No Spotify installation directory was found.'
        return $status
    }

    $status.SpotifyVersion = Get-SpotifyVersion -SpotifyRoot $status.SpotifyRoot
    if (-not $status.SpotifyVersion) {
        $status.State = 'SpotifyNotInstalled'
        $status.Reason = "Spotify.exe was not found under $($status.SpotifyRoot)."
        return $status
    }

    $status.BackupVersion = Get-SpicetifyBackupVersion
    $marker = Get-XpuiMarkerState -SpotifyRoot $status.SpotifyRoot
    $status.MarkerSource = $marker.Source
    $status.Patched = $marker.Patched
    $status.VersionMatch = Test-VersionMatch -SpotifyVersion $status.SpotifyVersion -BackupVersion $status.BackupVersion
    $status.ArchiveRestored = Test-SpotifyArchiveRestored -SpotifyRoot $status.SpotifyRoot

    if (-not $status.Patched) {
        $status.State = 'NeedsRepair'
        $status.Reason = 'The Spotify UI bundle contains no Spicetify markers - the patch is gone.'
    } elseif (-not $status.VersionMatch) {
        $status.State = 'NeedsRepair'
        $status.Reason = "Spotify updated to $($status.SpotifyVersion) but the patch was built against $($status.BackupVersion) - the patch is stale."
    } elseif ($status.ArchiveRestored) {
        $status.State = 'NeedsRepair'
        $status.Reason = 'Spotify has reinstalled its UI bundle alongside the patch - re-applying to stay ahead of it.'
    } else {
        $status.State = 'Healthy'
        $status.Reason = "Spicetify is applied and matches Spotify $($status.SpotifyVersion)."
    }
    $status
}

function Read-SharedText {
    param([Parameter(Mandatory)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $reader = New-Object System.IO.StreamReader($stream)
            try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
        } finally { $stream.Dispose() }
    } catch {
        return ''
    }
}

function Invoke-SpicetifyCommand {
    param(
        [Parameter(Mandatory)][string] $SpicetifyExe,
        [Parameter(Mandatory)][string[]] $Arguments,
        [int] $TimeoutSeconds = 900
    )

    Initialize-KsoDataDir | Out-Null
    $outFile = Join-Path $script:KsoDataDir 'spicetify-out.log'
    $errFile = Join-Path $script:KsoDataDir 'spicetify-err.log'

    try {
        Write-KsoLog "Running: spicetify $($Arguments -join ' ')"
        $proc = Start-Process -FilePath $SpicetifyExe -ArgumentList $Arguments `
            -NoNewWindow -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile

        $null = $proc.Handle

        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            Write-KsoLog "spicetify did not finish within $TimeoutSeconds s; terminating it." 'ERROR'
            try { $proc.Kill() } catch { }
            return [pscustomobject]@{ ExitCode = -2; Success = $false; StdOut = ''; StdErr = 'Timed out.' }
        }

        $stdout = Read-SharedText $outFile
        $stderr = Read-SharedText $errFile

        if ($stdout) {
            $tail = ($stdout -split "`n" | Where-Object { $_ -notmatch 'Patching files \[' } | Select-Object -Last 15) -join ' | '
            if ($tail.Trim()) { Write-KsoLog "  output: $($tail.Trim())" }
        }

        $exitCode = $proc.ExitCode
        if ($null -eq $exitCode) {
            Write-KsoLog 'spicetify exit code was unavailable; relying on the follow-up health check.' 'WARN'
            $exitCode = 0
        }

        [pscustomobject]@{
            ExitCode = $exitCode
            Success  = ($exitCode -eq 0)
            StdOut   = $stdout
            StdErr   = $stderr
        }
    } catch {
        Write-KsoLog "spicetify invocation failed: $($_.Exception.Message)" 'ERROR'
        [pscustomobject]@{ ExitCode = -1; Success = $false; StdOut = ''; StdErr = $_.Exception.Message }
    }
}

function Invoke-SpicetifyRepair {
    [CmdletBinding()]
    param(
        [switch] $Force
    )

    $status = Get-SpicetifyStatus

    if ($status.State -eq 'SpicetifyNotInstalled' -or $status.State -eq 'SpotifyNotInstalled') {
        Write-KsoLog "Cannot repair: $($status.Reason)" 'ERROR'
        return [pscustomobject]@{ Repaired = $false; Status = $status; Message = $status.Reason }
    }

    if ($status.State -eq 'Healthy' -and -not $Force) {
        return [pscustomobject]@{ Repaired = $false; Status = $status; Message = 'Already healthy; nothing to do.' }
    }

    Write-KsoLog "Repair starting - $($status.Reason)"

    if ($status.ArchiveRestored) {
        $primary  = @('backup', 'apply')
        $fallback = @('restore', 'backup', 'apply')
    } else {
        $primary  = @('restore', 'backup', 'apply')
        $fallback = @('backup', 'apply')
    }

    $result = Invoke-SpicetifyCommand -SpicetifyExe $status.SpicetifyExe -Arguments $primary
    if (-not $result.Success) {
        Write-KsoLog "'$($primary -join ' ')' exited $($result.ExitCode); falling back to '$($fallback -join ' ')'." 'WARN'
        $result = Invoke-SpicetifyCommand -SpicetifyExe $status.SpicetifyExe -Arguments $fallback
    }

    $after = Get-SpicetifyStatus
    if ($after.State -eq 'Healthy') {
        Write-KsoLog "Repair succeeded - Spicetify re-applied for Spotify $($after.SpotifyVersion)." 'OK'
        return [pscustomobject]@{ Repaired = $true; Status = $after; Message = "Spicetify restored for Spotify $($after.SpotifyVersion)." }
    }

    Write-KsoLog "Repair did not reach a healthy state: $($after.Reason)" 'ERROR'
    [pscustomobject]@{ Repaired = $false; Status = $after; Message = "Repair failed: $($after.Reason)" }
}

function Invoke-SpicetifyRepairPreservingState {
    param(
        [switch] $Force,
        [switch] $RestartSpotifyMinimised
    )

    $wasRunning = [bool](Get-SpotifyProcess)
    $result = Invoke-SpicetifyRepair -Force:$Force

    if ($RestartSpotifyMinimised -and $wasRunning) {
        if ($result.Status.State -eq 'Healthy') {
            Restart-SpotifyMinimised | Out-Null
        }
        return $result
    }

    if (-not $wasRunning -and (Get-SpotifyProcess)) {
        Write-KsoLog 'Closing the Spotify window Spicetify opened (it was not running before the repair).'

        $deadline = (Get-Date).AddSeconds(15)
        while ((Get-Date) -lt $deadline) {
            $running = Get-SpotifyProcess
            if (-not $running) { break }

            foreach ($p in $running) {
                try { $p.CloseMainWindow() | Out-Null } catch { }
            }
            Start-Sleep -Milliseconds 700

            foreach ($p in (Get-SpotifyProcess)) {
                try { $p.Kill() } catch { }
            }
            Start-Sleep -Milliseconds 500
        }

        if (Get-SpotifyProcess) {
            Write-KsoLog 'Spotify was still running after the close attempt; leaving it alone.' 'WARN'
        }
    }
    $result
}

function Set-SpotifyUpdateBlocking {
    param([Parameter(Mandatory)][bool] $Enabled)

    $exe = Resolve-SpicetifyExe
    if (-not $exe) {
        return [pscustomobject]@{ Success = $false; Message = 'spicetify.exe not found.' }
    }

    $verb = if ($Enabled) { 'block' } else { 'unblock' }
    $result = Invoke-SpicetifyCommand -SpicetifyExe $exe -Arguments @('spotify-updates', $verb)

    if ($result.Success) {
        Write-KsoLog "Spotify auto-updates ${verb}ed." 'OK'
        return [pscustomobject]@{ Success = $true; Message = "Spotify auto-updates ${verb}ed." }
    }
    Write-KsoLog "Failed to $verb Spotify auto-updates (exit $($result.ExitCode))." 'ERROR'
    [pscustomobject]@{ Success = $false; Message = "Failed to $verb Spotify auto-updates." }
}
