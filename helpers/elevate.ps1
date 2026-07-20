# ==============================================================================
# SELF-ELEVATION
# ==============================================================================
function Assert-Elevated
{
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$Title
    )

    if (([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
    {
        return
    }

    Write-Host "Requesting admin privileges..." -ForegroundColor Yellow
    $currentRuntime = (Get-Process -Id $PID).Path
    $psArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""

    if (Get-Command wt -ErrorAction SilentlyContinue)
    {
        Start-Process -FilePath wt -ArgumentList "new-tab --title `"$Title`" `"$currentRuntime`" $psArgs" -Verb RunAs
    }
    else
    {
        Start-Process -FilePath $currentRuntime -ArgumentList $psArgs -Verb RunAs
    }
    exit
}
