$ErrorActionPreference = 'Stop'
try {
    # Honor a verified local library relocation, including older packaged runtimes.
    if (-not $env:DOGY_LIBRARY_ROOT) {
        $marker = Join-Path $env:LOCALAPPDATA 'MediaDownloader\Library\location.json'
        if (Test-Path -LiteralPath $marker) {
            $location = Get-Content -LiteralPath $marker -Raw -Encoding UTF8 | ConvertFrom-Json
            if (-not [IO.Path]::IsPathRooted($location.root) -or
                -not (Test-Path -LiteralPath (Join-Path $location.root 'library.sqlite3') -PathType Leaf)) {
                throw '资料库迁移位置不可用，请恢复原目录，不创建空库'
            }
            $env:DOGY_LIBRARY_ROOT = $location.root
        }
    }
    . (Join-Path $PSScriptRoot 'runtime.ps1')
    # Refresh before connecting, never during an active transfer.
    $runtime = Get-DogyStartupRuntime (Join-Path $PSScriptRoot 'runtime.json')
    exit [DogyBridge]::Run($runtime.executable)
} catch {
    [Console]::Error.WriteLine('DOGY plugin: ' + $_.Exception.Message)
    exit 1
}
