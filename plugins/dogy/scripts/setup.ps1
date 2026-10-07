[CmdletBinding()]
param([string]$ExePath = '', [switch]$ForceDownload)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$utf8 = [Text.UTF8Encoding]::new($false)
$data = Join-Path $env:LOCALAPPDATA 'MediaDownloader\Agent'
$runtimePath = Join-Path $data 'runtime.json'
Add-Type -Path (Join-Path $PSScriptRoot 'bridge.cs')
function Test-Dogy([string]$candidate) {
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $null }
    try {
        $doctor = [DogyBridge]::Doctor($candidate) | ConvertFrom-Json
        if ($doctor.ok -and $doctor.app -eq '抖记DOGY' -and $doctor.version) { return $doctor }
    } catch { }
    return $null
}
function Assert-GitHubUrl([string]$url) {
    $uri = [Uri]$url
    if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'github.com' -or $uri.UserInfo) {
        throw 'Release URL must be HTTPS on github.com without credentials.'
    }
}
try {
    $selected = ''; $doctor = $null
    if ($ExePath) {
        $selected = (Resolve-Path -LiteralPath $ExePath).Path
        $doctor = Test-Dogy $selected
        if (-not $doctor) { throw 'The supplied EXE did not pass the DOGY doctor check.' }
    } elseif (-not $ForceDownload) {
        $candidates = @()
        if (Test-Path -LiteralPath $runtimePath) {
            $previous = Get-Content -LiteralPath $runtimePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $candidates += [string]$previous.executable
        }
        $candidates += @(
            (Join-Path $env:LOCALAPPDATA 'MediaDownloader\DOGY\DOGY.exe'),
            (Join-Path $env:USERPROFILE 'Downloads\抖记DOGY.exe'),
            (Join-Path $env:USERPROFILE 'Desktop\抖记DOGY.exe')
        )
        $command = Get-Command DOGY.exe -ErrorAction SilentlyContinue
        if ($command) { $candidates += $command.Source }
        foreach ($candidate in ($candidates | Select-Object -Unique)) {
            if (-not $candidate) { continue }
            $doctor = Test-Dogy $candidate
            if ($doctor) { $selected = (Resolve-Path -LiteralPath $candidate).Path; break }
        }
    }
    if (-not $selected) {
        $source = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\release-source.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($source.repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
            throw 'Publisher has not configured the GitHub release repository. Supply -ExePath to use your installed DOGY.'
        }
        $api = 'https://api.github.com/repos/' + $source.repository + '/releases/latest'
        $headers = @{ 'User-Agent' = 'DOGY-Plugin'; 'Accept' = 'application/vnd.github+json' }
        $release = Invoke-RestMethod -Uri $api -Headers $headers
        $asset = @($release.assets | Where-Object { $_.name -eq $source.executable_asset })
        $manifestAsset = @($release.assets | Where-Object { $_.name -eq $source.manifest_asset })
        if ($asset.Count -ne 1 -or $manifestAsset.Count -ne 1) { throw 'Release must contain DOGY.exe and dogy-release.json.' }
        foreach ($item in @($asset[0], $manifestAsset[0])) {
            Assert-GitHubUrl $item.browser_download_url
            if (-not $item.browser_download_url.StartsWith('https://github.com/' + $source.repository + '/releases/download/')) {
                throw 'Release asset URL belongs to a different repository.'
            }
        }
        $manifest = Invoke-RestMethod -Uri $manifestAsset[0].browser_download_url -Headers $headers
        if ($manifest.version -ne $release.tag_name.TrimStart('v') -or $manifest.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or $manifest.asset -ne $source.executable_asset) {
            throw 'Invalid release manifest or version mismatch.'
        }
        $install = Join-Path $env:LOCALAPPDATA ('MediaDownloader\DOGY\' + $manifest.sha256.ToLower())
        [IO.Directory]::CreateDirectory($install) | Out-Null
        $selected = Join-Path $install 'DOGY.exe'
        if (-not (Test-Path -LiteralPath $selected) -or (Get-FileHash -LiteralPath $selected -Algorithm SHA256).Hash -ne $manifest.sha256) {
            $temporary = Join-Path $install ([Guid]::NewGuid().ToString('N') + '.download')
            try {
                Invoke-WebRequest -UseBasicParsing -Uri $asset[0].browser_download_url -Headers $headers -OutFile $temporary
                if ((Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash -ne $manifest.sha256) { throw 'Downloaded EXE hash mismatch.' }
                if ((Get-Item -LiteralPath $temporary).Length -ne [long]$manifest.size_bytes) { throw 'Downloaded EXE size mismatch.' }
                Move-Item -LiteralPath $temporary -Destination $selected -Force
            } finally {
                if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
            }
        }
        $doctor = Test-Dogy $selected
        if (-not $doctor -or $doctor.version -ne $manifest.version) { throw 'Downloaded DOGY did not pass version/doctor validation.' }
    }
    [IO.Directory]::CreateDirectory($data) | Out-Null
    foreach ($name in @('bridge.cs', 'mcp.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $data $name) -Force
    }
    $record = @{ executable = $selected; version = $doctor.version }
    $temporary = Join-Path $data ([Guid]::NewGuid().ToString('N') + '.json')
    [IO.File]::WriteAllText($temporary, ($record | ConvertTo-Json), $utf8)
    Move-Item -LiteralPath $temporary -Destination $runtimePath -Force
    @{ ok = $true; executable = $selected; version = $doctor.version; ready = $doctor.ready; can_merge = $doctor.engines.can_merge } | ConvertTo-Json -Compress
} catch {
    [Console]::Error.WriteLine('DOGY setup: ' + $_.Exception.Message)
    exit 1
}
