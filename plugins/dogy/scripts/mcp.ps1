$ErrorActionPreference = 'Stop'
try {
    . (Join-Path $PSScriptRoot 'runtime.ps1')
    # Refresh before connecting, never during an active transfer.
    $runtime = Get-DogyStartupRuntime (Join-Path $PSScriptRoot 'runtime.json')
    exit [DogyBridge]::Run($runtime.executable)
} catch {
    [Console]::Error.WriteLine('DOGY plugin: ' + $_.Exception.Message)
    exit 1
}
