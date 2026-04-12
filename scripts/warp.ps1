param([string]$Action)

$warpConf = "$env:USERPROFILE\windows-config-scripts\warp\warp.conf"
$warpDir  = "$env:USERPROFILE\windows-config-scripts\warp"
$warpIcon = "$env:USERPROFILE\windows-config\assets\warp\warp.ico"
$tunnel   = "warp"

function _IsAdmin
{
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function _ElevateAction
{
    param([string]$Command)
    Write-Host " 󰮯 Elevating to Administrator..." -ForegroundColor Cyan
    Start-Process "wt" -ArgumentList "pwsh", "-NoExit", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"", "$Command" -Verb RunAs
    exit
}

function _PrintHeader
{
    param([string]$Icon, [string]$Title)
    Write-Host ""
    Write-Host "$Icon  $Title" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkBlue
}

function _PrintFooter
{
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`n" -ForegroundColor DarkBlue
}

function _PrintRow
{
    param([string]$Icon, [string]$Label, [string]$Value, [string]$Color = "White")
    Write-Host ("│  {0} {1,-12} {2}" -f $Icon, $Label, $Value) -ForegroundColor $Color
}

function _PassThru
{
    process
    { Write-Host "`e[38;2;118;138;161m│  $_`e[0m"
    }
}

$trayPidFile = "$env:TEMP\warp-tray.pid"

function _TrayStart
{
    $script = @"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

`$icon = New-Object System.Drawing.Icon "$warpIcon"
`$tray = New-Object System.Windows.Forms.NotifyIcon
`$tray.Icon    = `$icon
`$tray.Text    = "WARP Connected"
`$tray.Visible = `$true

[System.Windows.Forms.Application]::Run()
`$tray.Visible = `$false
"@

    $trayScript = "$env:TEMP\warp-tray-icon.ps1"
    $script | Set-Content $trayScript -Encoding UTF8

    $si                  = New-Object System.Diagnostics.ProcessStartInfo
    $si.FileName         = "pwsh.exe"
    $si.Arguments        = "-NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$trayScript`""
    $si.WindowStyle      = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $si.CreateNoWindow   = $true
    $si.UseShellExecute  = $false

    $proc = [System.Diagnostics.Process]::Start($si)
    $proc.Id | Set-Content $trayPidFile
}

function _TrayStop
{
    if (Test-Path $trayPidFile)
    {
        $trayPid = Get-Content $trayPidFile -ErrorAction SilentlyContinue
        if ($trayPid)
        {
            Stop-Process -Id $trayPid -Force -ErrorAction SilentlyContinue
        }
        Remove-Item $trayPidFile -Force -ErrorAction SilentlyContinue
    }
}

function _WarpOn
{
    if (-not (_IsAdmin))
    { _ElevateAction "on"; return
    }

    if (-not (Test-Path $warpConf))
    {
        Write-Host " 󰅍 Config not found. Auto-rotating credentials..." -ForegroundColor Cyan
        _WarpRotate
        if (-not (Test-Path $warpConf))
        {
            Write-Host " 󰅙 Failed to generate config. Aborting connection." -ForegroundColor Red
            return
        }
    }

    _PrintHeader "󰖂" "WireGuard WARP"
    wireguard /installtunnelservice $warpConf 2>&1 | _PassThru
    _TrayStart
    _PrintRow "󰤨" "Status" "CONNECTED" "Green"
    _PrintFooter
}

function _WarpOff
{
    if (-not (_IsAdmin))
    { _ElevateAction "off"; return
    }
    _PrintHeader "󰖂" "WireGuard WARP"
    wireguard /uninstalltunnelservice $tunnel 2>&1 | _PassThru
    _TrayStop
    _PrintRow "󰤭" "Status" "DISCONNECTED" "Red"
    _PrintFooter
}

function _WarpRotate
{
    if (-not (_IsAdmin))
    { _ElevateAction "rotate"; return
    }

    $svc = Get-Service -Name "WireGuardTunnel`$warp" -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running")
    {
        Write-Host " 󰅙 Tunnel is active. Run: warp off first." -ForegroundColor Red; return
    }

    _PrintHeader "󰖂" "Rotating WARP Credentials"
    if (!(Test-Path $warpDir))
    { New-Item -ItemType Directory -Path $warpDir -Force 2>&1 | _PassThru
    }
    Push-Location $warpDir

    try
    {
        if (Test-Path "$warpDir\wgcf-account.toml")
        {
            _PrintRow "󰚰" "Account" "Updating existing..." "Cyan"
            wgcf update 2>&1 | _PassThru
        } else
        {
            _PrintRow "󰀄" "Account" "Registering new..." "Cyan"
            wgcf register --accept-tos 2>&1 | _PassThru
        }

        wgcf generate 2>&1 | _PassThru
        $generated = Get-ChildItem -Path $warpDir -Filter "wgcf-profile.conf" | Select-Object -First 1
        if ($generated)
        {
            Copy-Item $generated.FullName $warpConf -Force
            _PrintRow "󰄬" "Config" "Generated successfully" "Green"
        } else
        {
            _PrintRow "󰅙" "Config" "Failed to generate" "Red"
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
    {
        _PrintRow "󰤨" "Status" "CONNECTED" "Green"
    } else
    {
        _PrintRow "󰤭" "Status" "DISCONNECTED" "Red"
    }
    if (Test-Path $warpConf)
    {
        _PrintRow "󱁤" "Config" $warpConf "Blue"
    }
    _PrintFooter
}

switch ($Action)
{
    "on"
    { _WarpOn
    }
    "off"
    { _WarpOff
    }
    "rotate"
    { _WarpRotate
    }
    "status"
    { _WarpStatus
    }
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
