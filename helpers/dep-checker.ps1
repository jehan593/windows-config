# ==============================================================================
# DEPENDENCY CHECKING
# ==============================================================================
# Silent by design - returns the missing command names as a string array
# (empty when everything is present); callers own the reporting.
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
    return $missing
}