# ==============================================================================
# DEPENDENCY CHECKING
# ==============================================================================
# Silent - returns missing command names as a string array (empty = all present).
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