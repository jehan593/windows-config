# ==============================================================================
# wgm-helper.ps1
# ==============================================================================
function Get-WgmActiveTunnel {
    return (wg show interfaces 2>$null | Select-Object -First 1)?.Trim()
}

function Disconnect-WgmTunnel {
    param(
        [Parameter(Mandatory)][string]$TunnelName,
        [switch]$UseGsudo
    )
    if ($UseGsudo -and (Get-Command gsudo -ErrorAction SilentlyContinue))
    {
        gsudo wireguard /uninstalltunnelservice $TunnelName
    }
    else
    {
        wireguard /uninstalltunnelservice $TunnelName
    }

    return ($LASTEXITCODE -eq 0)
}
