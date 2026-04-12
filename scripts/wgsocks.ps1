param([string]$Action, [string]$Arg1, [string]$Arg2)

$binaryPath = "$env:USERPROFILE\windows-config-scripts\wg-socks\wireproxy.exe"
$confDir = "$env:USERPROFILE\windows-config-scripts\wg-socks\configs"

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

function _InstallSocks
{
    param([string]$ConfigPath, [string]$Port)

    if (-not (_IsAdmin))
    {
        $fullPath = Resolve-Path $ConfigPath -ErrorAction SilentlyContinue
        if (-not $fullPath)
        {
            Write-Host "󰅙 Error: File not found: $ConfigPath" -ForegroundColor Red; return
        }
        _ElevateAction "install `"$fullPath`" $Port"
        return
    }

    if (-not $ConfigPath -or -not $Port)
    {
        Write-Host "󰋖 Usage: wgsocks install <config_path> <port>" -ForegroundColor Red; return
    }
    if (-not (Test-Path $ConfigPath))
    {
        Write-Host "󰅙 Error: File not found: $ConfigPath" -ForegroundColor Red; return
    }
    if ($Port -notmatch '^\d+$' -or [int]$Port -lt 1 -or [int]$Port -gt 65535)
    {
        Write-Host "󰅙 Error: Invalid port '$Port'. Must be between 1 and 65535." -ForegroundColor Red; return
    }

    $configBase = [System.IO.Path]::GetFileNameWithoutExtension($ConfigPath)
    $serviceName = "$configBase-wgsocks"
    $confDest = "$confDir\$configBase.conf"

    if (!(Test-Path $confDir))
    { New-Item -ItemType Directory -Path $confDir -Force 2>&1 | _PassThru
    }
    Copy-Item $ConfigPath $confDest -Force

    $content = Get-Content $confDest
    if ($content -match "BindAddress")
    {
        $content = $content -replace "BindAddress = .*", "BindAddress = 0.0.0.0:$Port"
    } else
    {
        $content += "`n[Socks5]`nBindAddress = 0.0.0.0:$Port"
    }
    $content | Set-Content $confDest

    _PrintHeader "󱌣" "Installing Tunnel: $serviceName"
    nssm install $serviceName $binaryPath "-c $confDest" 2>&1 | _PassThru
    nssm set $serviceName Start SERVICE_AUTO_START 2>&1 | _PassThru
    nssm start $serviceName 2>&1 | _PassThru
    _PrintRow "󰄬" "Status" "Active on port $Port" "Green"
    _PrintFooter
}

function _ListSocks
{
    $services = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*-wgsocks" }
    if (-not $services)
    {
        _PrintHeader "󰒄" "WireGuard SOCKS5 Tunnels"
        _PrintRow "󰋼" "Status" "No tunnels found" "Gray"
        _PrintFooter
        return
    }

    _PrintHeader "󰒄" "WireGuard SOCKS5 Tunnels"
    Write-Host ("│  {0,-35} {1,-12} {2}" -f "SERVICE NAME", "STATUS", "PORT") -ForegroundColor White
    foreach ($svc in $services)
    {
        $confFile = "$confDir\$($svc.Name -replace '-wgsocks','').conf"
        $port = (Get-Content $confFile | Where-Object { $_ -match "BindAddress" }) -replace '.*:', ''
        $color = if ($svc.Status -eq "Running")
        { "Green"
        } else
        { "Red"
        }
        Write-Host ("│  {0,-35} {1,-12} {2}" -f $svc.Name, $svc.Status, $port.Trim()) -ForegroundColor $color
    }
    _PrintFooter
}

function _UninstallSocks
{
    if (-not (_IsAdmin))
    { _ElevateAction "uninstall"; return
    }

    $services = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*-wgsocks" })
    if (-not $services)
    {
        Write-Host "󰋼 No tunnels found." -ForegroundColor Gray; return
    }

    _PrintHeader "󰗨" "Uninstall Tunnels"
    for ($i = 0; $i -lt $services.Count; $i++)
    {
        $confFile = "$confDir\$($services[$i].Name -replace '-wgsocks','').conf"
        $port = (Get-Content $confFile -ErrorAction SilentlyContinue | Where-Object { $_ -match "BindAddress" }) -replace '.*:', ''
        Write-Host ("│  {0,-4} {1,-35} {2}" -f "[$($i+1)]", $services[$i].Name, $port.Trim()) -ForegroundColor White
    }
    Write-Host "│"
    $inputs = Read-Host "│  Enter numbers to uninstall (comma separated)"
    if (-not $inputs)
    { _PrintFooter; return
    }

    $backupDir = Join-Path ([Environment]::GetFolderPath("Desktop")) "wg-socks-backup"
    if (!(Test-Path $backupDir))
    { New-Item -ItemType Directory -Path $backupDir -Force 2>&1 | _PassThru
    }

    $selected = $inputs -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' }
    foreach ($num in $selected)
    {
        $idx = [int]$num - 1
        if ($idx -lt 0 -or $idx -ge $services.Count)
        {
            Write-Host "│  󰅙 Invalid number: $num" -ForegroundColor Red; continue
        }
        $svc = $services[$idx]
        $confFile = "$confDir\$($svc.Name -replace '-wgsocks','').conf"

        if (Test-Path $confFile)
        {
            Copy-Item $confFile $backupDir -Force
            _PrintRow "󰄬" "Backup" "$($svc.Name) backed up to Desktop\wg-socks-backup" "Cyan"
        }

        nssm stop $svc.Name 2>&1 | _PassThru
        nssm remove $svc.Name confirm 2>&1 | _PassThru
        Remove-Item $confFile -ErrorAction SilentlyContinue
        _PrintRow "󰄬" "Removed" $svc.Name "Green"
    }
    _PrintFooter
}

function _RefreshSocks
{
    if (-not (_IsAdmin))
    { _ElevateAction "refresh"; return
    }

    $services = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*-wgsocks" }
    if (-not $services)
    {
        _PrintHeader "󰒄" "Refresh Tunnels"
        _PrintRow "󰋼" "Status" "No tunnels found" "Gray"
        _PrintFooter
        return
    }

    _PrintHeader "󰒄" "Refresh Tunnels"
    foreach ($svc in $services)
    {
        nssm restart $svc.Name 2>&1 | _PassThru
        _PrintRow "󰑐" $svc.Name "Restarted" "Green"
    }
    _PrintFooter
}

if (-not (Test-Path $binaryPath))
{
    Write-Host "󰅙 wireproxy.exe not found at: $binaryPath" -ForegroundColor Red; exit
}

switch ($Action)
{
    "install"
    { _InstallSocks $Arg1 $Arg2
    }
    "list"
    { _ListSocks
    }
    "uninstall"
    { _UninstallSocks
    }
    "refresh"
    { _RefreshSocks
    }
    default
    {
        _PrintHeader "󰒄" "WireGuard SOCKS5 Manager"
        _PrintRow "󱌣" "install"   "<path> <port>  Create tunnel"
        _PrintRow "󰒄" "list"      "List all tunnels"
        _PrintRow "󰑐" "refresh"   "Restart all tunnels"
        _PrintRow "󰗨" "uninstall" "Remove tunnel(s)"
        _PrintFooter
    }
}
