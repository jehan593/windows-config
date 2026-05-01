param([string]$Action)

$warpConf = "$env:USERPROFILE\windows-config-scripts\warp\warp.conf"
$warpDir  = "$env:USERPROFILE\windows-config-scripts\warp"
$tunnel   = "warp"

function _IsAdmin
{
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function _ElevateAction
{
    param([string]$Command)
    Write-Host "󰮯 Elevating to Administrator..." -ForegroundColor Cyan
    $cwd     = (Get-Location).Path
    $cwdSafe = $cwd -replace "'", "''"
    $encoded = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes(
            "Set-Location '$cwdSafe'; & '$PSCommandPath' $Command"
        )
    )
    Start-Process "wt" -ArgumentList "pwsh", "-NoExit", "-ExecutionPolicy", "Bypass", "-EncodedCommand", $encoded -Verb RunAs
    exit
}

function _PrintHeader
{
    param([string]$Icon, [string]$Title)
    Write-Host ""
    Write-Host "$Icon  $Title" -ForegroundColor Cyan
    Write-Host "─────────────────────────────────────────────────────" -ForegroundColor DarkBlue
}

function _PrintFooter
{
    Write-Host "─────────────────────────────────────────────────────`n" -ForegroundColor DarkBlue
}

function _PrintRow
{
    param([string]$Icon, [string]$Label, [string]$Value, [string]$Color = "White")
    Write-Host ("│  {0} {1,-12} {2}" -f $Icon, $Label, $Value) -ForegroundColor $Color
}

function _WarpOn
{
    if (-not (_IsAdmin)) { _ElevateAction "on"; return }

    if (-not (Test-Path $warpConf))
    {
        Write-Host "󰅍 Config not found. Auto-rotating credentials..." -ForegroundColor Cyan
        _WarpRotate
        if (-not (Test-Path $warpConf))
        {
            Write-Host "󰅙  Failed to generate config. Aborting connection." -ForegroundColor Red
            return
        }
    }

    _PrintHeader "󰖂" "WireGuard WARP"
    wireguard /installtunnelservice $warpConf

    if ($LASTEXITCODE -ne 0)
    { Write-Host "󰅙  FAILED (exit $LASTEXITCODE)" -ForegroundColor Red }
    else
    { Write-Host "󰤨  CONNECTED" -ForegroundColor Green }

    _PrintFooter
}

function _WarpOff
{
    if (-not (_IsAdmin)) { _ElevateAction "off"; return }

    _PrintHeader "󰖂" "WireGuard WARP"
    wireguard /uninstalltunnelservice $tunnel

    if ($LASTEXITCODE -ne 0)
    { Write-Host "󰅙  FAILED (exit $LASTEXITCODE)" -ForegroundColor Red }
    else
    { Write-Host "󰤭  DISCONNECTED" -ForegroundColor Gray }

    _PrintFooter
}

function _WarpRotate
{
    if (-not (_IsAdmin)) { _ElevateAction "rotate"; return }

    $svc = Get-Service -Name "WireGuardTunnel`$warp" -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running")
    {
        Write-Host "󰅙  Tunnel is active. Run: warp off first." -ForegroundColor Red
        return
    }

    _PrintHeader "󰖂" "Rotating WARP Credentials"

    if (!(Test-Path $warpDir))
    {
        New-Item -ItemType Directory -Path $warpDir -Force | Out-Null
    }
    Push-Location $warpDir

    try
    {
        if (Test-Path "$warpDir\wgcf-account.toml")
        {
            Write-Host "󰚰  Updating existing account..." -ForegroundColor Cyan
            wgcf update
        } else
        {
            Write-Host "󰀄  Registering new account..." -ForegroundColor Cyan
            wgcf register --accept-tos
        }

        wgcf generate

        if ($LASTEXITCODE -ne 0)
        {
            Write-Host "󰅙  wgcf generate failed (exit $LASTEXITCODE)" -ForegroundColor Red
            return
        }

        $generatedPath = "$warpDir\wgcf-profile.conf"
        if (Test-Path $generatedPath)
        {
            Copy-Item $generatedPath $warpConf -Force
            Write-Host "󰄬  Config generated successfully" -ForegroundColor Green
        } else
        {
            Write-Host "󰅙  Failed to generate config" -ForegroundColor Red
        }
    } finally
    {
        Pop-Location
        _PrintFooter
    }
}

function _WarpStatus
{
    $svc = Get-Service -Name "WireGuardTunnel`$warp" -ErrorAction SilentlyContinue
    _PrintHeader "󰖂" "WireGuard WARP"
    if ($svc -and $svc.Status -eq "Running")
    { Write-Host "󰤨  CONNECTED" -ForegroundColor Green }
    else
    { Write-Host "󰤭  DISCONNECTED" -ForegroundColor Gray }
    if (Test-Path $warpConf)
    { Write-Host "󱁤  $warpConf" -ForegroundColor Blue }
    _PrintFooter
}

switch ($Action)
{
    "on"     { _WarpOn }
    "off"    { _WarpOff }
    "rotate" { _WarpRotate }
    "status" { _WarpStatus }
    default
    {
        _PrintHeader "󰖂" "WARP Manager"
        _PrintRow "󰤨" "on"     "Connect tunnel"
        _PrintRow "󰤭" "off"    "Disconnect tunnel"
        _PrintRow "󰚰" "rotate" "Rotate WARP credentials"
        _PrintRow "󰖂" "status" "Show tunnel status"
        _PrintFooter
    }
}