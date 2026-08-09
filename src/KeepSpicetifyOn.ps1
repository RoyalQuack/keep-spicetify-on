[CmdletBinding()]
param(
    [switch] $Once,
    [switch] $Status,
    [switch] $ShowConsole
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Core.ps1')
. (Join-Path $PSScriptRoot 'Startup.ps1')
. (Join-Path $PSScriptRoot 'Update.ps1')

function Write-StatusToHost {
    param($S)
    $colour = switch ($S.State) {
        'Healthy'     { 'Green' }
        'NeedsRepair' { 'Yellow' }
        default       { 'Red' }
    }
    $v = Get-KsoLocalVersion
    Write-Host ''
    Write-Host "  KeepSpicetifyOn $(if ($v) { "v$v" })" -ForegroundColor Cyan
    Write-Host '  ---------------'
    Write-Host "  State           : " -NoNewline; Write-Host $S.State -ForegroundColor $colour
    Write-Host "  Reason          : $($S.Reason)"
    Write-Host "  Spotify version : $($S.SpotifyVersion)"
    Write-Host "  Patched against : $($S.BackupVersion)"
    Write-Host "  UI bundle source: $($S.MarkerSource)"
    Write-Host "  Marker present  : $($S.Patched)"
    Write-Host "  Version matches : $($S.VersionMatch)"
    Write-Host "  xpui.spa back   : $($S.ArchiveRestored)  (true means Spotify reinstalled its bundle)"
    Write-Host "  Spotify running : $($S.SpotifyRunning)"
    Write-Host ''
}

if ($Status) {
    Write-StatusToHost (Get-SpicetifyStatus)
    return
}

if ($Once) {
    $s = Get-SpicetifyStatus
    Write-StatusToHost $s
    if ($s.State -eq 'NeedsRepair') {
        Write-Host '  Repairing (this can take a few minutes)...' -ForegroundColor Yellow
        $r = Invoke-SpicetifyRepairPreservingState
        Write-Host "  $($r.Message)" -ForegroundColor $(if ($r.Repaired) { 'Green' } else { 'Red' })
    }
    return
}

$script:Mutex = New-Object System.Threading.Mutex($false, 'Global\KeepSpicetifyOn.Tray')
if (-not $script:Mutex.WaitOne(0, $false)) {
    Write-KsoLog 'Another KeepSpicetifyOn tray instance is already running; exiting.' 'WARN'
    return
}

if (-not $ShowConsole) {
    try {
        Add-Type -Namespace Kso -Name Win32 -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@ -ErrorAction Stop
        $hwnd = [Kso.Win32]::GetConsoleWindow()
        if ($hwnd -ne [IntPtr]::Zero) { [Kso.Win32]::ShowWindow($hwnd, 0) | Out-Null }
    } catch {
        Write-KsoLog "Could not hide the console window: $($_.Exception.Message)" 'WARN'
    }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:Config = Get-KsoConfig
$script:LastFullCheck = [datetime]::MinValue
$script:PauseUntil = [datetime]::MinValue
$script:PendingRepair = $false
$script:NotifiedPending = $false
$script:LastState = ''

$script:RepairInProgress = $false
$script:RepairRunspace = $null
$script:RepairPs = $null
$script:RepairHandle = $null

$script:UpdateInProgress = $false
$script:UpdateRunspace = $null
$script:UpdatePs = $null
$script:UpdateHandle = $null
$script:UpdateManual = $false
$script:LastUpdateCheck = [datetime]::MinValue
$script:LocalVersion = Get-KsoLocalVersion

$script:Shared = [hashtable]::Synchronized(@{ DirtyAt = [datetime]::MinValue })

Write-KsoLog '=== KeepSpicetifyOn tray started ==='

function New-StatusIcon {
    param([System.Drawing.Color] $Fill)

    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([System.Drawing.Color]::Transparent)

        $brush = New-Object System.Drawing.SolidBrush $Fill
        $g.FillEllipse($brush, 1, 1, 14, 14)
        $brush.Dispose()

        $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(120, 0, 0, 0)), 1
        $g.DrawEllipse($pen, 1, 1, 13, 13)
        $pen.Dispose()

        $hl = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(90, 255, 255, 255))
        $g.FillEllipse($hl, 4, 3, 6, 4)
        $hl.Dispose()
    } finally {
        $g.Dispose()
    }

    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $bmp.Dispose()
    $icon
}

$script:IconHealthy = New-StatusIcon ([System.Drawing.Color]::FromArgb(30, 185, 84))
$script:IconBroken  = New-StatusIcon ([System.Drawing.Color]::FromArgb(220, 60, 60))
$script:IconWorking = New-StatusIcon ([System.Drawing.Color]::FromArgb(240, 175, 40))
$script:IconUnknown = New-StatusIcon ([System.Drawing.Color]::FromArgb(140, 140, 140))

$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon = $script:IconUnknown
$notify.Text = 'KeepSpicetifyOn'
$notify.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip

$miStatus = New-Object System.Windows.Forms.ToolStripMenuItem 'Checking...'
$miStatus.Enabled = $false
$menu.Items.Add($miStatus) | Out-Null

$miDetail = New-Object System.Windows.Forms.ToolStripMenuItem ''
$miDetail.Enabled = $false
$menu.Items.Add($miDetail) | Out-Null

$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$miCheck = New-Object System.Windows.Forms.ToolStripMenuItem 'Check now'
$menu.Items.Add($miCheck) | Out-Null

$miRepair = New-Object System.Windows.Forms.ToolStripMenuItem 'Repair now'
$menu.Items.Add($miRepair) | Out-Null

$miPause = New-Object System.Windows.Forms.ToolStripMenuItem 'Pause for 1 hour'
$miPause.CheckOnClick = $false
$menu.Items.Add($miPause) | Out-Null

$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$miStartup = New-Object System.Windows.Forms.ToolStripMenuItem 'Start automatically at logon'
$miStartup.CheckOnClick = $false
$menu.Items.Add($miStartup) | Out-Null

$miBlock = New-Object System.Windows.Forms.ToolStripMenuItem 'Block Spotify auto-updates'
$miBlock.CheckOnClick = $false
$menu.Items.Add($miBlock) | Out-Null

$miNotify = New-Object System.Windows.Forms.ToolStripMenuItem 'Show notifications'
$miNotify.CheckOnClick = $false
$menu.Items.Add($miNotify) | Out-Null

$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$miUpdate = New-Object System.Windows.Forms.ToolStripMenuItem 'Check for updates'
$menu.Items.Add($miUpdate) | Out-Null

$miAutoUpdate = New-Object System.Windows.Forms.ToolStripMenuItem 'Update automatically'
$miAutoUpdate.CheckOnClick = $false
$menu.Items.Add($miAutoUpdate) | Out-Null

$miLog = New-Object System.Windows.Forms.ToolStripMenuItem 'Open log'
$menu.Items.Add($miLog) | Out-Null

$miQuit = New-Object System.Windows.Forms.ToolStripMenuItem 'Quit'
$menu.Items.Add($miQuit) | Out-Null

$notify.ContextMenuStrip = $menu

function Show-KsoBalloon {
    param(
        [string] $Title,
        [string] $Body,
        [System.Windows.Forms.ToolTipIcon] $Icon = [System.Windows.Forms.ToolTipIcon]::Info
    )
    if (-not $script:Config.notifications) { return }
    $notify.BalloonTipTitle = $Title
    $notify.BalloonTipText = $Body
    $notify.BalloonTipIcon = $Icon
    $notify.ShowBalloonTip(8000)
}

function Update-TrayUi {
    param($S)

    $paused = (Get-Date) -lt $script:PauseUntil

    switch ($S.State) {
        'Healthy' {
            $notify.Icon = $script:IconHealthy
            $miStatus.Text = "Spicetify is on"
        }
        'NeedsRepair' {
            $notify.Icon = $script:IconBroken
            $miStatus.Text = "Spicetify is OFF"
        }
        default {
            $notify.Icon = $script:IconUnknown
            $miStatus.Text = $S.State
        }
    }

    if ($paused) {
        $notify.Icon = $script:IconUnknown
        $miStatus.Text += ' (paused)'
    }

    $detail = if ($S.SpotifyVersion) { "Spotify $($S.SpotifyVersion)" } else { $S.Reason }
    if ($script:LocalVersion) { $detail += "   -   KSO v$($script:LocalVersion)" }
    $miDetail.Text = $detail

    $tip = "KeepSpicetifyOn - $($miStatus.Text)"
    if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }
    $notify.Text = $tip

    $miPause.Text = if ($paused) {
        "Resume (paused until $($script:PauseUntil.ToString('HH:mm')))"
    } else {
        'Pause for 1 hour'
    }

    $miStartup.Checked = Test-KsoStartupTask
    $miBlock.Checked = [bool]$script:Config.blockSpotifyUpdates
    $miNotify.Checked = [bool]$script:Config.notifications
    $miAutoUpdate.Checked = [bool]$script:Config.autoUpdate
}

function Start-KsoUpdateCheck {
    <#
        Checks GitHub for a newer VERSION and, when appropriate, installs it.
        Runs on a background runspace so a slow or dead network cannot freeze
        the tray.
    #>
    param([switch] $Manual)

    if ($script:UpdateInProgress -or $script:RepairInProgress) { return }

    $script:UpdateInProgress = $true
    $script:UpdateManual = [bool]$Manual
    $script:LastUpdateCheck = Get-Date
    $miUpdate.Enabled = $false

    $install = ([bool]$script:Config.autoUpdate) -or [bool]$Manual
    $updatePath = Join-Path $PSScriptRoot 'Update.ps1'

    $script:UpdateRunspace = [runspacefactory]::CreateRunspace()
    $script:UpdateRunspace.Open()
    $script:UpdatePs = [powershell]::Create()
    $script:UpdatePs.Runspace = $script:UpdateRunspace
    $null = $script:UpdatePs.AddScript({
        param($UpdatePath, $Install)
        . $UpdatePath
        $status = Get-KsoUpdateStatus
        if ($status.Available -and $Install) {
            $result = Invoke-KsoSelfUpdate
            return [pscustomobject]@{ Kind = 'Install'; Status = $status; Result = $result }
        }
        [pscustomobject]@{ Kind = 'Check'; Status = $status; Result = $null }
    }).AddArgument($updatePath).AddArgument($install)

    $script:UpdateHandle = $script:UpdatePs.BeginInvoke()
}

function Complete-KsoUpdateCheck {
    $outcome = $null
    try {
        $output = $script:UpdatePs.EndInvoke($script:UpdateHandle)
        $outcome = $output | Where-Object { $_ -and $_.PSObject.Properties.Name -contains 'Kind' } | Select-Object -Last 1
    } catch {
        Write-KsoLog "Update check failed: $($_.Exception.Message)" 'ERROR'
    } finally {
        if ($script:UpdatePs) { $script:UpdatePs.Dispose() }
        if ($script:UpdateRunspace) { $script:UpdateRunspace.Dispose() }
        $script:UpdatePs = $null
        $script:UpdateRunspace = $null
        $script:UpdateHandle = $null
        $script:UpdateInProgress = $false
        $miUpdate.Enabled = $true
    }

    $manual = $script:UpdateManual
    $script:UpdateManual = $false

    if (-not $outcome) {
        if ($manual) { Show-KsoBalloon 'KeepSpicetifyOn' 'Could not check for updates. See the log.' ([System.Windows.Forms.ToolTipIcon]::Error) }
        return
    }

    if (-not $outcome.Status.Checked) {
        if ($manual) { Show-KsoBalloon 'KeepSpicetifyOn' 'Could not reach GitHub to check for updates.' ([System.Windows.Forms.ToolTipIcon]::Warning) }
        return
    }

    if (-not $outcome.Status.Available) {
        if ($manual) { Show-KsoBalloon 'KeepSpicetifyOn' "You're on the latest version (v$($outcome.Status.Local))." }
        return
    }

    if ($outcome.Kind -eq 'Install' -and $outcome.Result.Updated) {
        Show-KsoBalloon 'KeepSpicetifyOn updated' "Updated to v$($outcome.Result.NewVersion). Restarting..."
        Write-KsoLog 'Restarting after update.'
        Restart-KsoTray -DelaySeconds 5 | Out-Null
        $timer.Stop()
        $notify.Visible = $false
        [System.Windows.Forms.Application]::Exit()
        return
    }

    if ($outcome.Kind -eq 'Install') {
        Show-KsoBalloon 'Update failed' $outcome.Result.Message ([System.Windows.Forms.ToolTipIcon]::Error)
        return
    }

    Show-KsoBalloon 'Update available' "KeepSpicetifyOn v$($outcome.Status.Remote) is available. Use 'Check for updates' to install it." ([System.Windows.Forms.ToolTipIcon]::Info)
}

function Invoke-KsoCheck {
    param([switch] $FromWatcher)

    if ($script:RepairInProgress) { return $null }

    $script:LastFullCheck = Get-Date
    $s = Get-SpicetifyStatus

    if ($s.State -ne $script:LastState) {
        Write-KsoLog "State: $($s.State) - $($s.Reason)"
        $script:LastState = $s.State
    }

    Update-TrayUi $s

    if ((Get-Date) -lt $script:PauseUntil) { return $s }
    if ($s.State -ne 'NeedsRepair') {
        $script:PendingRepair = $false
        $script:NotifiedPending = $false
        return $s
    }

    switch ($script:Config.repairPolicy) {
        'RepairImmediately' {
            Start-KsoRepair
        }
        'AskFirst' {
            if (-not $script:NotifiedPending) {
                $script:NotifiedPending = $true
                Show-KsoBalloon 'Spicetify was removed' 'A Spotify update removed Spicetify. Click here to repair it now.' ([System.Windows.Forms.ToolTipIcon]::Warning)
            }
        }
        default {
            if ($s.SpotifyRunning) {
                $script:PendingRepair = $true
                if (-not $script:NotifiedPending) {
                    $script:NotifiedPending = $true
                    Show-KsoBalloon 'Spicetify will be restored' 'A Spotify update removed Spicetify. It will be re-applied as soon as you close Spotify.' ([System.Windows.Forms.ToolTipIcon]::Warning)
                }
            } else {
                Start-KsoRepair
            }
        }
    }
    $s
}

function Set-MenuBusy {
    param([bool] $Busy)
    $miCheck.Enabled = -not $Busy
    $miRepair.Enabled = -not $Busy
    $miBlock.Enabled = -not $Busy
}

function Start-KsoRepair {
    param(
        [switch] $Force,
        [switch] $Startup
    )

    if ($script:RepairInProgress) {
        Write-KsoLog 'Repair already in progress; ignoring the new request.'
        return
    }

    $script:RepairInProgress = $true
    $notify.Icon = $script:IconWorking
    $miStatus.Text = 'Repairing...'
    $miDetail.Text = 'This can take a few minutes'
    Set-MenuBusy $true

    $corePath = Join-Path $PSScriptRoot 'Core.ps1'

    $script:RepairRunspace = [runspacefactory]::CreateRunspace()
    $script:RepairRunspace.Open()

    $script:RepairPs = [powershell]::Create()
    $script:RepairPs.Runspace = $script:RepairRunspace
    $null = $script:RepairPs.AddScript({
        param($CorePath, $ForceFlag, $StartupFlag)
        . $CorePath
        Invoke-SpicetifyRepairPreservingState -Force:$ForceFlag -RestartSpotifyMinimised:$StartupFlag
    }).AddArgument($corePath).AddArgument([bool]$Force).AddArgument([bool]$Startup)

    $script:RepairHandle = $script:RepairPs.BeginInvoke()
    Write-KsoLog 'Repair dispatched to a background runspace.'
}

function Complete-KsoRepair {
    $result = $null
    try {
        $output = $script:RepairPs.EndInvoke($script:RepairHandle)
        $result = $output | Where-Object { $_ -and $_.PSObject.Properties.Name -contains 'Repaired' } | Select-Object -Last 1
    } catch {
        Write-KsoLog "Background repair failed: $($_.Exception.Message)" 'ERROR'
    } finally {
        if ($script:RepairPs) { $script:RepairPs.Dispose() }
        if ($script:RepairRunspace) { $script:RepairRunspace.Dispose() }
        $script:RepairPs = $null
        $script:RepairRunspace = $null
        $script:RepairHandle = $null
        $script:RepairInProgress = $false
        $script:PendingRepair = $false
        $script:NotifiedPending = $false
        Set-MenuBusy $false
    }

    if (-not $result) {
        Show-KsoBalloon 'Spicetify repair failed' 'The repair did not complete. See the log for details.' ([System.Windows.Forms.ToolTipIcon]::Error)
        Invoke-KsoCheck | Out-Null
        return
    }

    $script:LastState = $result.Status.State
    Update-TrayUi $result.Status

    if ($result.Repaired) {
        Show-KsoBalloon 'Spicetify restored' $result.Message ([System.Windows.Forms.ToolTipIcon]::Info)
    } elseif ($result.Status.State -ne 'Healthy') {
        Show-KsoBalloon 'Spicetify repair failed' $result.Message ([System.Windows.Forms.ToolTipIcon]::Error)
    }
}

$miCheck.Add_Click({ Invoke-KsoCheck | Out-Null })

$miRepair.Add_Click({ Start-KsoRepair -Force | Out-Null })

$miPause.Add_Click({
    if ((Get-Date) -lt $script:PauseUntil) {
        $script:PauseUntil = [datetime]::MinValue
        Write-KsoLog 'Resumed by user.'
    } else {
        $script:PauseUntil = (Get-Date).AddHours(1)
        Write-KsoLog "Paused until $($script:PauseUntil.ToString('HH:mm'))."
    }
    Invoke-KsoCheck | Out-Null
})

$miStartup.Add_Click({
    try {
        if (Test-KsoStartupTask) {
            Unregister-KsoStartupTask | Out-Null
        } else {
            Register-KsoStartupTask
        }
    } catch {
        Write-KsoLog "Startup task toggle failed: $($_.Exception.Message)" 'ERROR'
        Show-KsoBalloon 'Could not change startup setting' $_.Exception.Message ([System.Windows.Forms.ToolTipIcon]::Error)
    }
    $miStartup.Checked = Test-KsoStartupTask
})

$miBlock.Add_Click({
    $enable = -not [bool]$script:Config.blockSpotifyUpdates
    $verb = if ($enable) { 'block' } else { 'unblock' }

    $answer = [System.Windows.Forms.MessageBox]::Show(
        $(if ($enable) {
            "This patches Spotify.exe so the client stops updating itself.`n`nSpicetify will stop being removed, but you will no longer receive Spotify feature or security updates until you turn this back off.`n`nBlock Spotify auto-updates?"
        } else {
            "Allow Spotify to update itself again?`n`nKeepSpicetifyOn will keep re-applying Spicetify whenever an update removes it."
        }),
        'KeepSpicetifyOn',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    $r = Set-SpotifyUpdateBlocking -Enabled $enable
    if ($r.Success) {
        $script:Config.blockSpotifyUpdates = $enable
        Save-KsoConfig $script:Config
        Show-KsoBalloon 'KeepSpicetifyOn' $r.Message
    } else {
        Show-KsoBalloon 'KeepSpicetifyOn' $r.Message ([System.Windows.Forms.ToolTipIcon]::Error)
    }
    $miBlock.Checked = [bool]$script:Config.blockSpotifyUpdates
})

$miNotify.Add_Click({
    $script:Config.notifications = -not [bool]$script:Config.notifications
    Save-KsoConfig $script:Config
    $miNotify.Checked = [bool]$script:Config.notifications
})

$miUpdate.Add_Click({ Start-KsoUpdateCheck -Manual })

$miAutoUpdate.Add_Click({
    $script:Config.autoUpdate = -not [bool]$script:Config.autoUpdate
    Save-KsoConfig $script:Config
    $miAutoUpdate.Checked = [bool]$script:Config.autoUpdate
    Write-KsoLog "Automatic updates set to $($script:Config.autoUpdate)."
})

$miLog.Add_Click({
    $log = Get-KsoLogPath
    if (Test-Path -LiteralPath $log) {
        Start-Process notepad.exe -ArgumentList "`"$log`""
    } else {
        Show-KsoBalloon 'KeepSpicetifyOn' 'No log entries yet.'
    }
})

$notify.Add_BalloonTipClicked({
    if ($script:LastState -eq 'NeedsRepair') { Start-KsoRepair | Out-Null }
})

$notify.Add_MouseDoubleClick({ Invoke-KsoCheck | Out-Null })

$script:Watcher = $null
$script:WatcherEvents = @()

$spotifyRoot = Get-SpotifyRoot
if ($spotifyRoot) {
    $appsDir = Join-Path $spotifyRoot 'Apps'
    if (Test-Path -LiteralPath $appsDir) {
        try {
            $script:Watcher = New-Object System.IO.FileSystemWatcher
            $script:Watcher.Path = $appsDir
            $script:Watcher.Filter = 'xpui*'
            $script:Watcher.IncludeSubdirectories = $false
            $script:Watcher.NotifyFilter = [System.IO.NotifyFilters]::LastWrite -bor
                                           [System.IO.NotifyFilters]::FileName -bor
                                           [System.IO.NotifyFilters]::DirectoryName -bor
                                           [System.IO.NotifyFilters]::Size
            $script:Watcher.EnableRaisingEvents = $true

            foreach ($evt in @('Changed', 'Created', 'Deleted', 'Renamed')) {
                $script:WatcherEvents += Register-ObjectEvent -InputObject $script:Watcher `
                    -EventName $evt -MessageData $script:Shared -Action {
                        $Event.MessageData.DirtyAt = Get-Date
                    }
            }
            Write-KsoLog "Watching $appsDir for Spotify UI bundle changes."
        } catch {
            Write-KsoLog "Could not start the file watcher: $($_.Exception.Message)" 'WARN'
        }
    }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000

$timer.Add_Tick({
    try {
        $now = Get-Date

        if ($script:RepairInProgress) {
            if ($script:RepairHandle -and $script:RepairHandle.IsCompleted) {
                Complete-KsoRepair
            }
            return
        }

        if ($script:UpdateInProgress) {
            if ($script:UpdateHandle -and $script:UpdateHandle.IsCompleted) {
                Complete-KsoUpdateCheck
            }
            return
        }

        $updateEvery = [double]$script:Config.updateCheckHours
        if ($updateEvery -gt 0 -and ($now - $script:LastUpdateCheck).TotalHours -ge $updateEvery) {
            Start-KsoUpdateCheck
            return
        }

        $dirtyAt = $script:Shared.DirtyAt
        if ($dirtyAt -ne [datetime]::MinValue -and ($now - $dirtyAt).TotalSeconds -ge 10) {
            $script:Shared.DirtyAt = [datetime]::MinValue
            Write-KsoLog 'Spotify UI bundle changed on disk; re-checking.'
            Invoke-KsoCheck -FromWatcher | Out-Null
            return
        }

        if ($script:PendingRepair -and (Get-Date) -ge $script:PauseUntil) {
            if (-not (Get-SpotifyProcess)) {
                Write-KsoLog 'Spotify closed; running the queued repair.'
                Start-KsoRepair | Out-Null
                return
            }
        }

        $interval = [double]$script:Config.checkIntervalSeconds
        if (($now - $script:LastFullCheck).TotalSeconds -ge $interval) {
            Invoke-KsoCheck | Out-Null
        }
    } catch {
        Write-KsoLog "Tick failed: $($_.Exception.Message)" 'ERROR'
    }
})
$timer.Start()

$miQuit.Add_Click({
    Write-KsoLog 'Quit requested from the tray menu.'
    $timer.Stop()
    $notify.Visible = $false
    [System.Windows.Forms.Application]::Exit()
})

$startupTimer = New-Object System.Windows.Forms.Timer
$startupTimer.Interval = 400
$startupTimer.Add_Tick({
    $startupTimer.Stop()

    if ($script:Config.repairOnStartup) {
        Write-KsoLog 'Startup repair: re-applying Spicetify unconditionally.'
        Start-KsoRepair -Force -Startup
    } else {
        Invoke-KsoCheck | Out-Null
    }
})
$startupTimer.Start()

try {
    [System.Windows.Forms.Application]::Run()
} finally {
    Write-KsoLog '=== KeepSpicetifyOn tray stopped ==='
    $timer.Dispose()
    $startupTimer.Dispose()

    if ($script:RepairPs) {
        try { $script:RepairPs.Dispose() } catch { }
    }
    if ($script:RepairRunspace) {
        try { $script:RepairRunspace.Dispose() } catch { }
    }
    if ($script:UpdatePs) {
        try { $script:UpdatePs.Dispose() } catch { }
    }
    if ($script:UpdateRunspace) {
        try { $script:UpdateRunspace.Dispose() } catch { }
    }

    foreach ($sub in $script:WatcherEvents) {
        Unregister-Event -SubscriptionId $sub.Id -ErrorAction SilentlyContinue
    }
    if ($script:Watcher) {
        $script:Watcher.EnableRaisingEvents = $false
        $script:Watcher.Dispose()
    }

    $notify.Visible = $false
    $notify.Dispose()
    $menu.Dispose()

    $script:Mutex.ReleaseMutex()
    $script:Mutex.Dispose()
}
