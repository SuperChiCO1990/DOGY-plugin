param([string]$TestRoot)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'runtime.ps1')
$TestRoot = Join-Path $TestRoot ([Guid]::NewGuid().ToString('N'))
$env:LOCALAPPDATA = $TestRoot
$env:USERPROFILE = Join-Path $TestRoot 'profile'
$env:PATH = Join-Path $env:SystemRoot 'System32'
$script:offline = $false
$script:badHash = $false
$script:badDoctor = $false
$script:requests = 0
$script:downloads = 0
$script:bytes = [Text.Encoding]::UTF8.GetBytes('verified-release-fixture')
$script:hash = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($script:bytes)).Replace('-', '').ToLower()
function Assert($value, [string]$message) { if (-not $value) { throw $message } }
function Test-Dogy([string]$candidate) {
    if (-not $candidate -or -not (Test-Path -LiteralPath $candidate)) { return $null }
    $version = '2.0.0'
    if ($candidate.EndsWith('old.exe')) { $version = '1.0.0' }
    elseif ($candidate.EndsWith('DOGY\DOGY.exe')) { $version = '1.0.3' }
    elseif ($script:badDoctor) { return $null }
    return @{ executable = $candidate; version = $version; ready = $true; can_merge = $true }
}
function Invoke-RestMethod($Uri, $Headers, $TimeoutSec) {
    $script:requests++
    if ($script:offline) { throw 'offline fixture' }
    $base = 'https://github.com/SuperChiCO1990/DOGY-plugin/releases/download/v2.0.0/'
    if ($Uri.EndsWith('/latest')) {
        return @{ tag_name = 'v2.0.0'; assets = @(
            @{ name = 'DOGY.exe'; browser_download_url = $base + 'DOGY.exe' },
            @{ name = 'dogy-release.json'; browser_download_url = $base + 'dogy-release.json' }) }
    }
    return @{ version = '2.0.0'; sha256 = $script:hash; asset = 'DOGY.exe'; size_bytes = $script:bytes.Length }
}
function Invoke-WebRequest($Uri, $Headers, $OutFile, $TimeoutSec, [switch]$UseBasicParsing) {
    $script:downloads++
    $bytes = if ($script:badHash) { [byte[]]@(1, 2, 3) } else { $script:bytes }
    [IO.File]::WriteAllBytes($OutFile, $bytes)
}
$directory = Join-Path $TestRoot 'MediaDownloader\DOGY'
[IO.Directory]::CreateDirectory($directory) | Out-Null
$old = Join-Path $TestRoot 'old.exe'
$local = Join-Path $directory 'DOGY.exe'
[IO.File]::WriteAllBytes($old, $script:bytes)
[IO.File]::WriteAllBytes($local, $script:bytes)
$selected = Find-DogyRuntime @{ executable = $old }
Assert ($selected.version -eq '1.0.3') 'Old recorded executable must not beat newer local executable.'
$path = Join-Path $TestRoot 'Agent\runtime.json'
Save-DogyRuntime $path @{ executable = $old; version = '1.0.0'; checked_at = 0; plugin_version = '1.1.0' }
$script:offline = $true
$selected = Update-DogyStartupRuntime $path
Assert ($selected.version -eq '1.0.3') 'Offline startup must preserve verified runtime.'
Assert ((Read-DogyRuntime $path).plugin_version -eq '1.1.0') 'Runtime refresh must preserve installed bootstrap version.'
$count = $script:requests
$selected = Update-DogyStartupRuntime $path
Assert ($script:requests -eq $count) 'Recent check must suppress repeated network requests.'
$script:launches = 0
function Start-Process($FilePath, $WindowStyle, $ArgumentList, $RedirectStandardError) {
    Assert ($WindowStyle -eq 'Hidden') 'Background update must not flash a window.'
    $script:launches++
}
$selected = Get-DogyStartupRuntime $path
Assert ($script:launches -eq 0) 'Recent check must not start an unnecessary worker.'
Save-DogyRuntime $path @{ executable = $old; version = '1.0.0'; checked_at = 0 }
$selected = Get-DogyStartupRuntime $path
Assert ($script:launches -eq 1 -and $script:requests -eq $count) 'Startup must dispatch refresh without waiting for network.'
$selected.checked_at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
Save-DogyRuntime $path $selected
$script:offline = $false
$script:badHash = $true
try { Update-DogyRuntime $selected | Out-Null; throw 'Bad hash accepted.' }
catch { Assert ($_.Exception.Message -match 'hash/size') ('Corrupt download must be rejected: ' + $_.Exception.Message) }
Assert (-not (Get-ChildItem -LiteralPath $directory -Recurse -Filter '*.exe' | Where-Object { $_.Directory.Name -eq $script:hash })) 'Corrupt release must not be installed.'
$script:badHash = $false
$script:badDoctor = $true
try { Update-DogyRuntime $selected | Out-Null; throw 'Bad doctor accepted.' }
catch { Assert ($_.Exception.Message -match 'doctor/version') 'Failed doctor must be rejected.' }
$script:badDoctor = $false
$new = Update-DogyRuntime $selected
Assert ($new.version -eq '2.0.0') 'New verified release must be selected.'
Assert ((Get-DogyHash $new.executable) -eq $script:hash) 'Installed file hash differs.'
$count = $script:downloads
$same = Update-DogyRuntime $new
Assert ($script:downloads -eq $count) 'Same version must not redownload.'
$new.version = '3.0.0'
$same = Update-DogyRuntime $new
Assert ($same.version -eq '3.0.0') 'Never downgrade a newer local version.'
Assert ((Read-DogyRuntime $path).version -eq '1.0.3') 'Failed release must not modify current runtime record.'
Assert (@(Get-ChildItem -LiteralPath $directory -Recurse -File | Where-Object { $_.Name -match '^[a-f0-9]{32}\.exe$' }).Count -eq 0) 'Temporary downloads leaked.'
Write-Output 'Runtime selection, offline fallback, check interval, hash/doctor rejection, upgrade and no downgrade: PASS'
