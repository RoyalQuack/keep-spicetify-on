if (-not (Get-Command Write-KsoLog -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'Core.ps1')
}

$script:KsoTaskName = 'KeepSpicetifyOn'

function Get-KsoTaskName { $script:KsoTaskName }

function Get-KsoTrayScriptPath {
    Join-Path $PSScriptRoot 'KeepSpicetifyOn.ps1'
}

function Test-KsoStartupTask {
    $null -ne (Get-ScheduledTask -TaskName $script:KsoTaskName -ErrorAction SilentlyContinue)
}

function Register-KsoStartupTask {
    [CmdletBinding()]
    param(
        [string] $ScriptPath = (Get-KsoTrayScriptPath)
    )

    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        throw "Tray script not found at $ScriptPath"
    }

    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = @(
        '-NoProfile'
        '-NonInteractive'
        '-WindowStyle Hidden'
        '-ExecutionPolicy Bypass'
        "-File `"$ScriptPath`""
    ) -join ' '

    $action = New-ScheduledTaskAction -Execute $psExe -Argument $arguments

    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $trigger.Delay = 'PT30S'

    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
        -LogonType Interactive -RunLevel Limited

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit ([TimeSpan]::Zero)

    Register-ScheduledTask -TaskName $script:KsoTaskName `
        -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
        -Description 'Keeps Spicetify applied to Spotify by re-applying it after Spotify auto-updates.' `
        -Force | Out-Null

    Write-KsoLog "Registered logon task '$($script:KsoTaskName)'." 'OK'
}

function Unregister-KsoStartupTask {
    if (Test-KsoStartupTask) {
        Unregister-ScheduledTask -TaskName $script:KsoTaskName -Confirm:$false
        Write-KsoLog "Removed logon task '$($script:KsoTaskName)'." 'OK'
        return $true
    }
    $false
}
