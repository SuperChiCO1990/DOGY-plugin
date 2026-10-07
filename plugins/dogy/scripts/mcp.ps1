$ErrorActionPreference = 'Stop'
try {
    $runtime = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'runtime.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not (Test-Path -LiteralPath $runtime.executable -PathType Leaf)) {
        throw 'DOGY executable moved or missing. Run the plugin setup again.'
    }
    Add-Type -Path (Join-Path $PSScriptRoot 'bridge.cs')
    exit [DogyBridge]::Run($runtime.executable)
} catch {
    [Console]::Error.WriteLine('DOGY plugin: ' + $_.Exception.Message)
    exit 1
}
