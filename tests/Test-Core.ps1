Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\src\Core.ps1')
. (Join-Path $PSScriptRoot '..\src\Update.ps1')

$script:Pass = 0
$script:Fail = 0

function Assert-Equal {
    param($Expected, $Actual, [string] $Name)
    if ($Expected -eq $Actual) {
        $script:Pass++
        Write-Host "  [pass] $Name" -ForegroundColor Green
    } else {
        $script:Fail++
        Write-Host "  [FAIL] $Name" -ForegroundColor Red
        Write-Host "         expected: '$Expected'" -ForegroundColor Red
        Write-Host "         actual  : '$Actual'" -ForegroundColor Red
    }
}

function Assert-True {
    param($Condition, [string] $Name)
    Assert-Equal -Expected $true -Actual ([bool]$Condition) -Name $Name
}

Write-Host ''
Write-Host 'Get-VersionCore' -ForegroundColor Cyan

Assert-Equal '1.2.95.453' (Get-VersionCore '1.2.95.453.g0eeebbed') 'strips a trailing git hash'
Assert-Equal '1.2.95.453' (Get-VersionCore '1.2.95.453')           'leaves a plain version alone'
Assert-Equal '1.2.94'     (Get-VersionCore '1.2.94')               'handles three components'
Assert-Equal ''           (Get-VersionCore '')                     'empty string yields empty'
Assert-Equal ''           (Get-VersionCore $null)                  'null yields empty'
Assert-Equal ''           (Get-VersionCore 'gabcdef')              'non-numeric leading segment yields empty'

Write-Host ''
Write-Host 'Test-VersionMatch' -ForegroundColor Cyan

Assert-True  (Test-VersionMatch '1.2.95.453' '1.2.95.453.g0eeebbed') 'matches across the git suffix'
Assert-Equal $false (Test-VersionMatch '1.2.95.453' '1.2.94.583.g60394bd5') 'detects a Spotify update'
Assert-Equal $false (Test-VersionMatch '1.2.95.453' '')     'empty backup version never matches'
Assert-Equal $false (Test-VersionMatch '' '1.2.95.453')     'empty Spotify version never matches'
Assert-Equal $false (Test-VersionMatch $null $null)         'two nulls never match'

Write-Host ''
Write-Host 'Read-IniSectionValue' -ForegroundColor Cyan

$tmpIni = Join-Path ([System.IO.Path]::GetTempPath()) "kso-test-$PID.ini"
@'
[Setting]
spotify_path           = C:\Users\Test\AppData\Roaming\Spotify
current_theme          = marketplace

[Patch]

; DO NOT CHANGE!
[Backup]
version = 1.2.95.453.g0eeebbed
with    = 2.44.0
'@ | Set-Content -LiteralPath $tmpIni -Encoding utf8

try {
    Assert-Equal '1.2.95.453.g0eeebbed' (Read-IniSectionValue -Path $tmpIni -Section 'Backup' -Key 'version') 'reads [Backup] version'
    Assert-Equal '2.44.0' (Read-IniSectionValue -Path $tmpIni -Section 'Backup' -Key 'with') 'reads [Backup] with'
    Assert-Equal 'C:\Users\Test\AppData\Roaming\Spotify' (Read-IniSectionValue -Path $tmpIni -Section 'Setting' -Key 'spotify_path') 'reads [Setting] spotify_path'
    Assert-Equal $null (Read-IniSectionValue -Path $tmpIni -Section 'Setting' -Key 'version') 'does not leak keys across sections'
    Assert-Equal $null (Read-IniSectionValue -Path $tmpIni -Section 'Nope' -Key 'version') 'unknown section yields null'
    Assert-Equal $null (Read-IniSectionValue -Path 'Z:\does\not\exist.ini' -Section 'Backup' -Key 'version') 'missing file yields null'
} finally {
    Remove-Item -LiteralPath $tmpIni -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host 'Live environment' -ForegroundColor Cyan

$status = Get-SpicetifyStatus
Assert-True ($status.State -in @('Healthy', 'NeedsRepair', 'SpotifyNotInstalled', 'SpicetifyNotInstalled')) "status reports a known state ($($status.State))"
Assert-True (-not [string]::IsNullOrWhiteSpace($status.Reason)) 'status always explains itself'

if ($status.State -in @('Healthy', 'NeedsRepair')) {
    Assert-True (Test-Path -LiteralPath $status.SpotifyRoot) 'resolved Spotify root exists'
    Assert-True (-not [string]::IsNullOrWhiteSpace($status.SpotifyVersion)) 'read a Spotify version'
    Assert-True ($status.SpicetifyVersion -match '^\d+\.\d+') "read a Spicetify version ($($status.SpicetifyVersion))"
    Assert-Equal 'Folder' $status.MarkerSource 'Spicetify v2 serves the UI from the Apps\xpui folder'

    $spa = Join-Path $status.SpotifyRoot 'Apps\xpui.spa'
    Assert-Equal (Test-Path -LiteralPath $spa) $status.ArchiveRestored 'ArchiveRestored tracks whether Apps\xpui.spa exists'

    if ($status.State -eq 'Healthy') {
        Assert-Equal $false (Test-Path -LiteralPath $spa) 'a healthy install has no xpui.spa in Apps'
        Assert-True (Test-Path -LiteralPath (Join-Path $env:APPDATA 'spicetify\Backup\xpui.spa')) 'the clean archive is held in Spicetify Backup'
    }

    $archiveToCheck = if (Test-Path -LiteralPath $spa) { $spa } else { Join-Path $env:APPDATA 'spicetify\Backup\xpui.spa' }
    if (Test-Path -LiteralPath $archiveToCheck) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($archiveToCheck)
        try {
            $entry = $zip.Entries | Where-Object { $_.FullName -eq 'index.html' } | Select-Object -First 1
            $reader = New-Object System.IO.StreamReader($entry.Open())
            try { $spaText = $reader.ReadToEnd() } finally { $reader.Dispose() }
        } finally { $zip.Dispose() }

        Assert-Equal $false ([bool]($spaText -match 'spicetify')) 'the backup archive is unpatched, so it is always a clean source'
    }
}

Write-Host ''
Write-Host 'Self-update versioning' -ForegroundColor Cyan

Assert-Equal ([version]'1.2.3') (ConvertTo-KsoVersion '1.2.3')        'parses a plain version'
Assert-Equal ([version]'1.2.3') (ConvertTo-KsoVersion "1.2.3`n")      'ignores a trailing newline'
Assert-Equal ([version]'1.2.3') (ConvertTo-KsoVersion '  v1.2.3  ')   'tolerates a v prefix and whitespace'
Assert-Equal $null (ConvertTo-KsoVersion 'not-a-version')             'rejects rubbish'
Assert-Equal $null (ConvertTo-KsoVersion '')                          'rejects empty'

# Ordering must be numeric, not lexical: "1.10.0" is newer than "1.9.0" even
# though it sorts earlier as a string.
Assert-True ((ConvertTo-KsoVersion '1.10.0') -gt (ConvertTo-KsoVersion '1.9.0')) 'compares numerically, not as text'
Assert-True ((ConvertTo-KsoVersion '2.0.0') -gt (ConvertTo-KsoVersion '1.99.99')) 'a major bump wins'

$localVersion = Get-KsoLocalVersion
Assert-True ($null -ne $localVersion) "the shipped VERSION file parses (v$localVersion)"

Write-Host ''
Write-Host 'Config' -ForegroundColor Cyan

$defaults = Get-KsoDefaultConfig
Assert-Equal 'WaitForSpotifyExit' $defaults.repairPolicy 'default policy never interrupts playback'
Assert-Equal $false $defaults.blockSpotifyUpdates 'update blocking is opt-in'
Assert-True ($defaults.checkIntervalSeconds -gt 0) 'check interval is positive'

$loaded = Get-KsoConfig
foreach ($key in $defaults.PSObject.Properties.Name) {
    Assert-True ($loaded.PSObject.Properties.Name -contains $key) "loaded config carries '$key'"
}

Write-Host ''
Write-Host ('-' * 46)
if ($script:Fail -eq 0) {
    Write-Host "  All $($script:Pass) checks passed." -ForegroundColor Green
} else {
    Write-Host "  $($script:Pass) passed, $($script:Fail) FAILED." -ForegroundColor Red
}
Write-Host ''

if ($script:Fail -gt 0) { exit 1 }
