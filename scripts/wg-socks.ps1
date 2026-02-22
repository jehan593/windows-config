param([string]$Action, [string]$Arg1, [string]$Arg2)

$binaryPath = "C:\Program Files\wireproxy\wireproxy.exe"
$confDir = "C:\ProgramData\wireproxy"

function Is-Admin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Elevate-Action {
    param([string]$Command)
    $exe = if ($PSEdition -eq "Core") { "pwsh" } else { "powershell.exe" }
    $arguments = "-NoExit -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" $Command"
    Start-Process $exe -ArgumentList $arguments -Verb RunAs
    exit
}

function Install-Socks {
    param([string]$ConfigPath, [string]$Port)

    if (-not (Is-Admin)) {
        $fullPath = Resolve-Path $ConfigPath -ErrorAction SilentlyContinue
        if (-not $fullPath) {
            Write-Host " Error: File not found: $ConfigPath" -ForegroundColor Red; return
        }
        Elevate-Action "install `"$fullPath`" $Port"
        return
    }

    if (-not (Get-Command nssm -ErrorAction SilentlyContinue)) {
        Write-Host " nssm not found. Please install it (winget install nssm)." -ForegroundColor Red; return
    }

    if (-not $ConfigPath -or -not $Port) {
        Write-Host "󰋖 Usage: wg-socks install <config_path> <port>" -ForegroundColor Red; return
    }
    if (-not (Test-Path $ConfigPath)) {
        Write-Host " Error: File not found: $ConfigPath" -ForegroundColor Red; return
    }
    if ($Port -notmatch '^\d+$' -or [int]$Port -lt 1 -or [int]$Port -gt 65535) {
        Write-Host " Error: Invalid port '$Port'. Must be between 1 and 65535." -ForegroundColor Red; return
    }

    $configBase = [System.IO.Path]::GetFileNameWithoutExtension($ConfigPath)
    $serviceName = "$configBase-wgsocks"
    $confDest = "$confDir\$configBase.conf"

    if (!(Test-Path $confDir)) { New-Item -ItemType Directory -Path $confDir -Force | Out-Null }
    Copy-Item $ConfigPath $confDest -Force

    $content = Get-Content $confDest
    if ($content -match "BindAddress") {
        $content = $content -replace "BindAddress = .*", "BindAddress = 0.0.0.0:$Port"
    } else {
        $content += "`n[Socks5]`nBindAddress = 0.0.0.0:$Port"
    }
    $content | Set-Content $confDest

    Write-Host "󱌣 Installing Windows Service: $serviceName..." -ForegroundColor Cyan
    nssm install $serviceName $binaryPath "-c $confDest"
    nssm set $serviceName Start SERVICE_AUTO_START
    nssm start $serviceName
    Write-Host " SUCCESS: $serviceName is active on port $Port" -ForegroundColor Green
}

function List-Socks {
    $services = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*-wgsocks" }
    if (-not $services) { Write-Host "󰒄 No tunnels found." -ForegroundColor Gray; return }

    Write-Host "`n 󰒄 Active WireGuard Tunnels" -ForegroundColor Cyan
    Write-Host " ------------------------------------------------------------" -ForegroundColor DarkGray
    "{0,-3} {1,-30} {2,-12} {3,-10}" -f "", "SERVICE NAME", "STATUS", "PORT" | Write-Host -ForegroundColor White

    foreach ($svc in $services) {
        $confFile = "$confDir\$($svc.Name -replace '-wgsocks','').conf"
        $port = (Get-Content $confFile | Where-Object { $_ -match "BindAddress" }) -replace '.*:', ''

        $icon = if ($svc.Status -eq "Running") { " " } else { "󰜺 " }
        $color = if ($svc.Status -eq "Running") { "Green" } else { "Red" }

        "{0,-3} {1,-30} {2,-12} {3,-10}" -f $icon, $svc.Name, $svc.Status, $port.Trim() | Write-Host -ForegroundColor $color
    }
    Write-Host ""
}

function Test-Socks {
    param([string]$Name)
    if (-not $Name) { Write-Host "󰋖 Usage: wg-socks test <name>" -ForegroundColor Red; return }

    $baseName = $Name -replace '-wgsocks', ''
    $confFile = "$confDir\$baseName.conf"
    if (-not (Test-Path $confFile)) {
        Write-Host " Error: Config not found for '$Name'" -ForegroundColor Red; return
    }

    $port = (Get-Content $confFile | Where-Object { $_ -match "BindAddress" }) -replace '.*:', ''
    $port = $port.Trim()
    Write-Host " Testing proxy on port $port..." -ForegroundColor Cyan

    try {
        $ip = Invoke-RestMethod -Uri "https://ifconfig.me/ip" -Proxy "socks5://127.0.0.1:$port" -ErrorAction Stop
        Write-Host " Proxy Working! IP: $ip" -ForegroundColor Green
    } catch {
        Write-Host " Test Failed. Is the service running? Check with: wg-socks list" -ForegroundColor Red
    }
}

function Remove-Socks {
    param([string]$Name)
    if (-not $Name) { Write-Host "󰋖 Usage: wg-socks remove <name>" -ForegroundColor Red; return }

    if (-not (Is-Admin)) { Elevate-Action "remove $Name"; return }

    if (-not (Get-Command nssm -ErrorAction SilentlyContinue)) {
        Write-Host " nssm not found. Please install it (winget install nssm)." -ForegroundColor Red; return
    }

    $confFile = "$confDir\$($Name -replace '-wgsocks','').conf"
    Write-Host "󰗨 Stopping and removing $Name..." -ForegroundColor Yellow
    nssm stop $Name
    nssm remove $Name confirm
    Remove-Item $confFile -ErrorAction SilentlyContinue
    Write-Host " Removed successfully." -ForegroundColor Green
}

# Only check wireproxy at the top since it's relevant to all actions
if (-not (Test-Path $binaryPath)) {
    Write-Host " wireproxy.exe not found at: $binaryPath" -ForegroundColor Red; exit
}

switch ($Action) {
    "install" { Install-Socks $Arg1 $Arg2 }
    "list"    { List-Socks }
    "remove"  { Remove-Socks $Arg1 }
    "test"    { Test-Socks $Arg1 }
    default {
        Write-Host "`n 󰒄 WireGuard SOCKS5 Manager" -ForegroundColor Cyan
        Write-Host " ---------------------------------------------------" -ForegroundColor DarkGray
        Write-Host "  install <path> <port> 󱌣 Create new tunnel service"
        Write-Host "  list                   List all tunnels"
        Write-Host "  test <name>           󰒄 Test tunnel connectivity"
        Write-Host "  remove <name>         󰗨 Remove tunnel service"
        Write-Host " ---------------------------------------------------`n"
    }
}