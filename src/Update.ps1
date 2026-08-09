if (-not (Get-Command Write-KsoLog -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'Core.ps1')
}

$script:KsoRepo = 'RoyalQuack/keep-spicetify-on'
$script:KsoBranch = 'main'
$script:KsoVersionUrl = "https://raw.githubusercontent.com/$script:KsoRepo/$script:KsoBranch/VERSION"
$script:KsoZipUrl = "https://github.com/$script:KsoRepo/archive/refs/heads/$script:KsoBranch.zip"

function Get-KsoRepoUrl { "https://github.com/$script:KsoRepo" }

function Get-KsoInstallRoot {
    Split-Path -Parent $PSScriptRoot
}

function ConvertTo-KsoVersion {
    param([string] $Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

    $cleaned = ($Text -split "`n")[0].Trim().TrimStart('v', 'V')
    $parsed = $null
    if ([version]::TryParse($cleaned, [ref]$parsed)) { return $parsed }
    $null
}

function Get-KsoLocalVersion {
    $file = Join-Path (Get-KsoInstallRoot) 'VERSION'
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    ConvertTo-KsoVersion (Get-Content -LiteralPath $file -Raw -ErrorAction SilentlyContinue)
}

function Get-KsoRemoteVersion {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $response = Invoke-WebRequest -Uri $script:KsoVersionUrl -UseBasicParsing -TimeoutSec 20
        ConvertTo-KsoVersion $response.Content
    } catch {
        Write-KsoLog "Update check failed: $($_.Exception.Message)" 'WARN'
        $null
    }
}

function Get-KsoUpdateStatus {
    $local = Get-KsoLocalVersion
    $remote = Get-KsoRemoteVersion

    [pscustomobject]@{
        Local     = $local
        Remote    = $remote
        Available = ($null -ne $local -and $null -ne $remote -and $remote -gt $local)
        Checked   = ($null -ne $remote)
    }
}

function Invoke-KsoSelfUpdate {
    <#
        Downloads the current branch as a ZIP, verifies it looks like a real
        KeepSpicetifyOn tree and is actually newer, then copies it over the
        install directory. Nothing is touched until every check has passed, so a
        failed download cannot leave a half-updated install behind.

        Settings are not at risk: config and logs live in %LOCALAPPDATA%, not in
        the install directory.
    #>
    [CmdletBinding()]
    param([switch] $Force)

    $status = Get-KsoUpdateStatus
    if (-not $status.Checked) {
        return [pscustomobject]@{ Updated = $false; Message = 'Could not reach GitHub to check for updates.'; Status = $status }
    }
    if (-not $status.Available -and -not $Force) {
        return [pscustomobject]@{ Updated = $false; Message = "Already up to date (v$($status.Local))."; Status = $status }
    }

    $installRoot = Get-KsoInstallRoot
    $probe = Join-Path $installRoot '.kso-write-test'
    try {
        Set-Content -LiteralPath $probe -Value 'x' -ErrorAction Stop
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    } catch {
        return [pscustomobject]@{ Updated = $false; Message = "Cannot write to $installRoot - update it manually."; Status = $status }
    }

    $work = Join-Path ([System.IO.Path]::GetTempPath()) "kso-update-$([guid]::NewGuid().ToString('N'))"
    $zip = Join-Path $work 'source.zip'

    try {
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        Write-KsoLog "Downloading v$($status.Remote) from GitHub."

        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $script:KsoZipUrl -OutFile $zip -UseBasicParsing -TimeoutSec 180

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $work)

        $extracted = Get-ChildItem -LiteralPath $work -Directory | Select-Object -First 1
        if (-not $extracted) { throw 'The downloaded archive was empty.' }

        $required = @('VERSION', 'install.ps1', 'src\Core.ps1', 'src\KeepSpicetifyOn.ps1', 'src\Startup.ps1', 'src\launcher.vbs')
        foreach ($rel in $required) {
            if (-not (Test-Path -LiteralPath (Join-Path $extracted.FullName $rel))) {
                throw "The download is missing $rel - refusing to install it."
            }
        }

        $downloaded = ConvertTo-KsoVersion (Get-Content -LiteralPath (Join-Path $extracted.FullName 'VERSION') -Raw)
        if (-not $downloaded) { throw 'The download has no readable VERSION.' }
        if (-not $Force -and $downloaded -le $status.Local) {
            throw "The download is v$downloaded, not newer than v$($status.Local)."
        }

        Get-ChildItem -LiteralPath $extracted.FullName -Force | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $installRoot -Recurse -Force
        }

        Get-ChildItem -LiteralPath $installRoot -Recurse -Filter *.ps1 -ErrorAction SilentlyContinue |
            Unblock-File -ErrorAction SilentlyContinue

        Write-KsoLog "Updated to v$downloaded." 'OK'
        [pscustomobject]@{ Updated = $true; Message = "Updated to v$downloaded. Restarting..."; Status = $status; NewVersion = $downloaded }
    } catch {
        Write-KsoLog "Update failed: $($_.Exception.Message)" 'ERROR'
        [pscustomobject]@{ Updated = $false; Message = "Update failed: $($_.Exception.Message)"; Status = $status }
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Restart-KsoTray {
    <#
        Relaunches the tray after an update. The new instance is started with a
        delay so this one has exited and released the single-instance mutex
        first, otherwise the replacement would see itself as a duplicate and
        quit immediately.
    #>
    param([int] $DelaySeconds = 5)

    $launcher = Join-Path $PSScriptRoot 'launcher.vbs'
    if (-not (Test-Path -LiteralPath $launcher)) {
        Write-KsoLog 'Cannot restart: launcher.vbs is missing.' 'ERROR'
        return $false
    }

    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\wscript.exe') `
        -ArgumentList @('//nologo', "`"$launcher`"", ($DelaySeconds * 1000))
    Write-KsoLog "Restart queued in $DelaySeconds seconds."
    $true
}
