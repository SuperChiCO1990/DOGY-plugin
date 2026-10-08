[CmdletBinding()]
param([string]$ExePath = '', [switch]$ForceDownload)
. (Join-Path $PSScriptRoot 'runtime.ps1')
$data = Join-Path $env:LOCALAPPDATA 'MediaDownloader\Agent'
$runtimePath = Join-Path $data 'runtime.json'
try {
    if ($ExePath) {
        $runtime = Test-Dogy (Resolve-Path -LiteralPath $ExePath).Path
        if (-not $runtime) { throw 'The supplied EXE did not pass the DOGY doctor check.' }
    } else {
        $runtime = Find-DogyRuntime (Read-DogyRuntime $runtimePath)
        if (-not $runtime -or $ForceDownload) { $runtime = Update-DogyRuntime $runtime }
    }
    [IO.Directory]::CreateDirectory($data) | Out-Null
    foreach ($name in @('bridge.cs', 'mcp.ps1', 'runtime.ps1', 'refresh.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $data $name) -Force
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\release-source.json') -Destination (Join-Path $data 'release-source.json') -Force
    $runtime['checked_at'] = 0
    $plugin = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\.codex-plugin\plugin.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $runtime['plugin_version'] = $plugin.version
    Save-DogyRuntime $runtimePath $runtime
    @{ ok = $true; executable = $runtime.executable; version = $runtime.version;
       ready = $runtime.ready; can_merge = $runtime.can_merge } | ConvertTo-Json -Compress
} catch {
    [Console]::Error.WriteLine('DOGY setup: ' + $_.Exception.Message)
    exit 1
}
