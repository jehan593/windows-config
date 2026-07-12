# ==============================================================================
# DEPENDENCY CHECKING
# ==============================================================================
function _TestDependencies
{
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Commands
    )

    $missing = @()

    foreach ($cmd in $Commands)
    {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue))
        {
            $missing += $cmd
        }
    }
    if ($missing.Count -gt 0)
    {
        foreach ($app in $missing)
        {
            Write-Host "$app not found" -ForegroundColor Red
        }
        return $false
    }
    return $true
}