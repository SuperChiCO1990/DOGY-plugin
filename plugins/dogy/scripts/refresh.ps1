param([Parameter(Mandatory = $true)][string]$RuntimePath)
try {
    . (Join-Path $PSScriptRoot 'runtime.ps1')
    Update-DogyStartupRuntime $RuntimePath | Out-Null
} catch {
    [Console]::Error.WriteLine('DOGY background update: ' + $_.Exception.Message)
    exit 1
}
