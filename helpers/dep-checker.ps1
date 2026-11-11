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

    # One lookup over the whole list - every individual Get-Command would rescan
    # the PATH from scratch. Application entries surface with their extension
    # (e.g. 'starship.exe'), so the extension-less form is matched as well in
    # case a shell function is requested next to an Application of another name.
    $known = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($item in (Get-Command -Name $Commands -ErrorAction SilentlyContinue | Select-Object -Unique))
    {
        $null = $known.Add($item.Name)
        $null = $known.Add([System.IO.Path]::GetFileNameWithoutExtension($item.Name))
    }

    $missing = @()
    foreach ($cmd in $Commands)
    {
        if (-not $known.Contains($cmd))
        {
            $missing += $cmd
        }
    }
    return $missing
}