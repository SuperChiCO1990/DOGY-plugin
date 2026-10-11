[CmdletBinding()]
param([string]$ExePath = '', [switch]$ForceDownload)
. (Join-Path $PSScriptRoot 'runtime.ps1')
$data = Join-Path $env:LOCALAPPDATA 'MediaDownloader\Agent'
$runtimePath = Join-Path $data 'runtime.json'
$warning = ''
try {
    $plugin = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\.codex-plugin\plugin.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $requiredVersion = [version]$plugin.version
    if ($ExePath) {
        $runtime = Test-Dogy (Resolve-Path -LiteralPath $ExePath).Path
        if (-not $runtime) { throw 'The supplied EXE did not pass the DOGY doctor check.' }
    } else {
        $runtime = Find-DogyRuntime (Read-DogyRuntime $runtimePath)
        if (-not $runtime -or $ForceDownload -or [version]$runtime.version -lt $requiredVersion) {
            try { $runtime = Update-DogyRuntime $runtime }
            catch {
                if (-not $runtime) { throw }
                $warning = 'DOGY update failed; keeping the verified local program: ' + $_.Exception.Message
            }
        }
    }
    $videoMemoryAvailable = [version]$runtime.version -ge [version]'1.1.0'
    $denseFramesAvailable = [version]$runtime.version -ge [version]'1.1.1'
    $efficientAnalysisAvailable = [version]$runtime.version -ge [version]'1.2.0'
    if (-not $denseFramesAvailable) {
        $warning += ' Denser frame analysis requires DOGY 1.1.1 or later; the selected program keeps its previous sampling policy.'
    }
    if (-not $videoMemoryAvailable) {
        $warning += ' DOGY ' + $runtime.version + ' is selected. Download tools remain available; video memory requires DOGY 1.1.0 or later.'
    }
    if (-not $efficientAnalysisAvailable) {
        $warning += ' Overview and time-range analysis require DOGY 1.2.0 or later.'
    }
    if ($warning) { [Console]::Error.WriteLine('DOGY setup: ' + $warning.Trim()) }
    [IO.Directory]::CreateDirectory($data) | Out-Null
    foreach ($name in @('bridge.cs', 'mcp.ps1', 'runtime.ps1', 'refresh.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $data $name) -Force
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\release-source.json') -Destination (Join-Path $data 'release-source.json') -Force
    $runtime['checked_at'] = 0
    $runtime['plugin_version'] = $plugin.version
    Save-DogyRuntime $runtimePath $runtime
    @{ ok = $true; executable = $runtime.executable; version = $runtime.version;
       ready = $runtime.ready; can_merge = $runtime.can_merge;
       video_memory_available = $videoMemoryAvailable; dense_frames_available = $denseFramesAvailable;
       efficient_analysis_available = $efficientAnalysisAvailable; required_version = $requiredVersion.ToString();
       warning = $warning.Trim() } | ConvertTo-Json -Compress
} catch {
    [Console]::Error.WriteLine('DOGY setup: ' + $_.Exception.Message)
    exit 1
}
