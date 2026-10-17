$ErrorActionPreference = 'Stop'
try {
    . (Join-Path $PSScriptRoot 'runtime.ps1')
    # Refresh before connecting, never during an active transfer.
    $resolve = [Func[string]] { (Get-DogyStartupRuntime (Join-Path $PSScriptRoot 'runtime.json')).executable }
    exit [DogyBridge]::RunLazy($resolve, (Join-Path $PSScriptRoot 'catalog.json'))
} catch {
    [Console]::Error.WriteLine('DOGY plugin: ' + $_.Exception.Message)
    exit 1
}
