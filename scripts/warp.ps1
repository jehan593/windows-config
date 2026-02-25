param([string]$Action)

$warpConf = "$env:USERPROFILE\windows-config-scripts\warp\warp.conf"
$warpDir  = "$env:USERPROFILE\windows-config-scripts\warp"
$tunnel   = "warp"

function _IsAdmin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function _ElevateAction {
    param([string]$Command)
    $exe = if ($PSEdition -eq "Core") { "pwsh" } else { "powershell.exe" }
    $arguments = "-NoExit -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" $Command"
    Start-Process $exe -ArgumentList $arguments -Verb RunAs
    exit
}

function _WarpOn {
    if (-not (_IsAdmin)) { _ElevateAction "on"; return }
    if (-not (Test-Path $warpConf)) {
        Write-Host " warp.conf not found. Run: warp rotate" -ForegroundColor Red; return
    }

    Write-Host ""
    Write-Host "   󰖂  WireGuard" -ForegroundColor Cyan
    Write-Host "     ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkBlue
    wireguard /installtunnelservice $warpConf
    Write-Host ("     󰤨  {0,-11} {1}" -f "Status", "CONNECTED") -ForegroundColor Green
    Write-Host "     ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`n" -ForegroundColor DarkBlue
}

function _WarpOff {
    if (-not (_IsAdmin)) { _ElevateAction "off"; return }

    Write-Host ""
    Write-Host "   󰖂  WireGuard" -ForegroundColor Cyan
    Write-Host "     ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkBlue
    wireguard /uninstalltunnelservice $tunnel
    Write-Host ("     󰤭  {0,-11} {1}" -f "Status", "DISCONNECTED") -ForegroundColor Red
    Write-Host "     ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`n" -ForegroundColor DarkBlue
}

function _WarpRotate {
    if (-not (_IsAdmin)) { _ElevateAction "rotate"; return }

    $svc = Get-Service -Name "WireGuardTunnel`$warp" -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") {
        Write-Host " Tunnel is active. Run: warp off first." -ForegroundColor Red; return
    }

    Write-Host " Rotating WARP credentials..." -ForegroundColor Cyan
    if (!(Test-Path $warpDir)) { New-Item -ItemType Directory -Path $warpDir -Force | Out-Null }
    Push-Location $warpDir

    try {
        if (Test-Path "$warpDir\wgcf-account.toml") {
            Write-Host " Updating existing account..." -ForegroundColor Cyan
            wgcf update
        } else {
            Write-Host " Registering new account..." -ForegroundColor Cyan
            wgcf register --accept-tos
        }

        wgcf generate
        $generated = Get-ChildItem -Path $warpDir -Filter "wgcf-profile.conf" | Select-Object -First 1
        if ($generated) {
            Copy-Item $generated.FullName $warpConf -Force
            Write-Host " New config generated." -ForegroundColor Green
        } else {
            Write-Host " Failed to generate config." -ForegroundColor Red
        }
    } finally {
        Pop-Location
    }
}

function _WarpStatus {
    $svc = Get-Service -Name "WireGuardTunnel`$warp" -ErrorAction SilentlyContinue
    Write-Host ""
    Write-Host "   󰖂  WireGuard WARP" -ForegroundColor Cyan
    Write-Host "     ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkBlue
    if ($svc -and $svc.Status -eq "Running") {
        Write-Host ("     󰤨  {0,-11} {1}" -f "Status", "CONNECTED") -ForegroundColor Green
    } else {
        Write-Host ("     󰤭  {0,-11} {1}" -f "Status", "DISCONNECTED") -ForegroundColor Red
    }
    if (Test-Path $warpConf) {
        Write-Host ("      {0,-11} {1}" -f "Config", $warpConf) -ForegroundColor Blue
    }
    Write-Host "     ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`n" -ForegroundColor DarkBlue
}

switch ($Action) {
    "on"     { _WarpOn }
    "off"    { _WarpOff }
    "rotate" { _WarpRotate }
    "status" { _WarpStatus }
    default {
        Write-Host "`n   󰖂  WARP Manager" -ForegroundColor Cyan
        Write-Host "     ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkBlue
        Write-Host "      on      󰤨 Connect tunnel"
        Write-Host "      off     󰤭 Disconnect tunnel"
        Write-Host "      rotate   Rotate WARP credentials"
        Write-Host "      status  󰖂 Show tunnel status"
        Write-Host "     ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`n" -ForegroundColor DarkBlue
    }
}