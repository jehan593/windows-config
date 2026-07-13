# ==============================================================================
# wgm-helper.ps1
# ==============================================================================
function Get-WgmActiveTunnel {
    return (wg show interfaces 2>$null | Select-Object -First 1)?.Trim()
}

function Wait-WgmTunnelState {
    param(
        [string]$ExpectedTunnel,
        [int]$TimeoutMs = 8000,
        [int]$PollMs = 200
    )
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    do {
        $active = Get-WgmActiveTunnel
        if ($ExpectedTunnel) {
            if ($active -eq $ExpectedTunnel) { return $true }
        } elseif (-not $active) {
            return $true
        }
        Start-Sleep -Milliseconds $PollMs
    } while ((Get-Date) -lt $deadline)
    return $false
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
