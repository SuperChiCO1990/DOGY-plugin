# Shared setup/startup logic; all diagnostics stay off MCP stdout.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if (-not ('DogyBridge' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'bridge.cs') }

function Get-DogyHash([string]$path) {
    $stream = [IO.File]::OpenRead($path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '') }
    finally { $stream.Dispose(); $sha.Dispose() }
}

function Test-Dogy([string]$candidate) {
    if (-not $candidate -or -not (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $null }
    try {
        $doctor = [DogyBridge]::Doctor($candidate) | ConvertFrom-Json
        if ($doctor.ok -and $doctor.app -eq '抖记DOGY' -and $doctor.version -match '^\d+\.\d+\.\d+$') {
            return @{ executable = (Resolve-Path -LiteralPath $candidate).Path; version = $doctor.version;
                      ready = $doctor.ready; can_merge = $doctor.engines.can_merge }
        }
    } catch { [Console]::Error.WriteLine('DOGY candidate rejected: ' + $_.Exception.Message) }
    return $null
}

function Find-DogyRuntime($previous) {
    $candidates = @([string]$previous.executable,
        (Join-Path $env:LOCALAPPDATA 'MediaDownloader\DOGY\DOGY.exe'),
        (Join-Path $env:USERPROFILE 'Downloads\抖记DOGY.exe'),
        (Join-Path $env:USERPROFILE 'Desktop\抖记DOGY.exe'))
    $command = Get-Command DOGY.exe -ErrorAction SilentlyContinue
    if ($command) { $candidates += $command.Source }
    $selected = $null
    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        $runtime = Test-Dogy $candidate
        if ($runtime -and (-not $selected -or [version]$runtime.version -gt [version]$selected.version)) {
            $selected = $runtime
        }
    }
    return $selected
}

function Read-DogyRuntime([string]$path) {
    if (Test-Path -LiteralPath $path) {
        try { return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json }
        catch { [Console]::Error.WriteLine('DOGY runtime record invalid: ' + $_.Exception.Message) }
    }
    return $null
}

function Save-DogyRuntime([string]$path, $record) {
    $previous = Read-DogyRuntime $path
    if (-not $record.ContainsKey('plugin_version') -and $previous.plugin_version) {
        $record['plugin_version'] = $previous.plugin_version
    }
    $directory = Split-Path -Parent $path
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporary = Join-Path $directory ([Guid]::NewGuid().ToString('N') + '.json')
    try {
        [IO.File]::WriteAllText($temporary, ($record | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $path -Force
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
    }
}

function Assert-DogyAsset([string]$url, [string]$prefix) {
    $uri = [Uri]$url
    if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'github.com' -or $uri.UserInfo -or
        -not $url.StartsWith($prefix, [StringComparison]::Ordinal)) {
        throw 'Release asset must belong to the configured HTTPS GitHub release.'
    }
}

function Update-DogyStartupRuntime([string]$path) {
    $previous = Read-DogyRuntime $path
    $runtime = Find-DogyRuntime $previous
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $mutex = [Threading.Mutex]::new($false, 'Local\DOGY.Agent.Runtime.Update')
    $owned = $false
    try {
        try { $owned = $mutex.WaitOne(1000) } catch [Threading.AbandonedMutexException] { $owned = $true }
        if ($owned) {
            $latestRecord = Read-DogyRuntime $path
            if ($latestRecord.executable -ne $previous.executable) {
                $latestLocal = Test-Dogy ([string]$latestRecord.executable)
                if ($latestLocal -and (-not $runtime -or [version]$latestLocal.version -gt [version]$runtime.version)) { $runtime = $latestLocal }
            }
            if (-not $runtime -or $now - [long]$latestRecord.checked_at -ge 21600) {
                try { $runtime = Update-DogyRuntime $runtime }
                catch {
                    if (-not $runtime) { throw }
                    [Console]::Error.WriteLine('DOGY update check failed; using verified runtime: ' + $_.Exception.Message)
                }
                $runtime['checked_at'] = $now
            } else { $runtime['checked_at'] = [long]$latestRecord.checked_at }
            Save-DogyRuntime $path $runtime
        }
    } finally {
        if ($owned) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
    if (-not $runtime) { throw 'DOGY not ready. Run the plugin setup again.' }
    return $runtime
}

function Get-DogyStartupRuntime([string]$path) {
    $previous = Read-DogyRuntime $path
    $runtime = Find-DogyRuntime $previous
    if (-not $runtime) { throw 'DOGY not ready. Run the plugin setup again.' }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ($now - [long]$previous.checked_at -ge 21600) {
        try {
            $script = Join-Path $PSScriptRoot 'refresh.ps1'
            $shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            Start-Process -FilePath $shell -WindowStyle Hidden -RedirectStandardError (Join-Path (Split-Path -Parent $path) 'update-error.log') -ArgumentList @(
                '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                '-File', ('"' + $script + '"'), '-RuntimePath', ('"' + $path + '"'))
        } catch { [Console]::Error.WriteLine('DOGY refresh could not start: ' + $_.Exception.Message) }
    }
    return $runtime
}

function Update-DogyRuntime($current) {
    $sourcePath = Join-Path $PSScriptRoot 'release-source.json'
    if (-not (Test-Path -LiteralPath $sourcePath)) { $sourcePath = Join-Path $PSScriptRoot '..\release-source.json' }
    $source = Get-Content -LiteralPath $sourcePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($source.repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'Invalid release repository.' }
    $base = 'https://github.com/' + $source.repository + '/releases'
    $headers = @{ 'User-Agent' = 'DOGY-Plugin'; 'Accept' = 'application/vnd.github+json' }
    try {
        $release = Invoke-RestMethod -Uri ('https://api.github.com/repos/' + $source.repository + '/releases/latest') -Headers $headers -TimeoutSec 10
    } catch {
        $status = 0
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        if ($status -notin @(403, 429)) { throw }
        $manifest = Invoke-RestMethod -Uri ($base + '/latest/download/dogy-release.json') -Headers $headers -TimeoutSec 10
        if ($manifest.version -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid public release version.' }
        $release = @{ tag_name = 'v' + $manifest.version; assets = @(
            @{ name = $source.executable_asset; browser_download_url = $base + '/download/v' + $manifest.version + '/' + $source.executable_asset },
            @{ name = $source.manifest_asset; browser_download_url = $base + '/download/v' + $manifest.version + '/' + $source.manifest_asset }) }
    }
    if ($release.draft -or $release.prerelease -or $release.tag_name -notmatch '^v\d+\.\d+\.\d+$') { throw 'Invalid formal release.' }
    $version = $release.tag_name.Substring(1)
    if ($current -and [version]$current.version -ge [version]$version) { return $current }
    $asset = @($release.assets | Where-Object { $_.name -eq $source.executable_asset })
    $manifestAsset = @($release.assets | Where-Object { $_.name -eq $source.manifest_asset })
    if ($asset.Count -ne 1 -or $manifestAsset.Count -ne 1) { throw 'Release assets missing or duplicated.' }
    $prefix = $base + '/download/' + $release.tag_name + '/'
    foreach ($item in @($asset[0], $manifestAsset[0])) { Assert-DogyAsset $item.browser_download_url $prefix }
    $manifest = Invoke-RestMethod -Uri $manifestAsset[0].browser_download_url -Headers $headers -TimeoutSec 10
    if ($manifest.version -ne $version -or $manifest.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or
        $manifest.asset -ne $source.executable_asset -or $manifest.size_bytes -le 0 -or $manifest.size_bytes -gt 419430400) {
        throw 'Invalid release manifest, size or version.'
    }
    $install = Join-Path $env:LOCALAPPDATA ('MediaDownloader\DOGY\' + $manifest.sha256.ToLower())
    [IO.Directory]::CreateDirectory($install) | Out-Null
    $selected = Join-Path $install 'DOGY.exe'
    if (-not (Test-Path -LiteralPath $selected) -or (Get-DogyHash $selected) -ne $manifest.sha256 -or
        (Get-Item -LiteralPath $selected).Length -ne [long]$manifest.size_bytes) {
        $temporary = Join-Path $install ([Guid]::NewGuid().ToString('N') + '.exe')
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $asset[0].browser_download_url -Headers $headers -OutFile $temporary -TimeoutSec 120
            if ((Get-DogyHash $temporary) -ne $manifest.sha256 -or
                (Get-Item -LiteralPath $temporary).Length -ne [long]$manifest.size_bytes) { throw 'Downloaded EXE hash/size mismatch.' }
            $runtime = Test-Dogy $temporary
            if (-not $runtime -or $runtime.version -ne $version) { throw 'Downloaded DOGY doctor/version check failed.' }
            Move-Item -LiteralPath $temporary -Destination $selected -Force
        } finally {
            if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
        }
    }
    $runtime = Test-Dogy $selected
    if (-not $runtime -or $runtime.version -ne $version) { throw 'Installed DOGY doctor/version check failed.' }
    return $runtime
}
