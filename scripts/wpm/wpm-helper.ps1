# ==============================================================================
# wpm-helper.ps1
# ==============================================================================

function Remove-WpmService
{
    param(
        [Parameter(Mandatory)][string]$ServiceName,
        [switch]$UseGsudo
    )

    if ($UseGsudo -and (Get-Command gsudo -ErrorAction SilentlyContinue))
    {
        gsudo {
            param($n)
            servy-cli stop      --name="$n"
            servy-cli uninstall --name="$n"
            if ($LASTEXITCODE -eq 0) { exit 0 } else { exit 1 }
        } -args $ServiceName
    }
    else
    {
        servy-cli stop      --name="$ServiceName"
        servy-cli uninstall --name="$ServiceName"
    }

    return ($LASTEXITCODE -eq 0)
}
