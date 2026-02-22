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
            Write-Host "Error: File not found: $ConfigPath" -ForegroundColor Red; return
        }
        Elevate-Action "install `"$fullPath`" $Port"
        return
    }

    if (-not $ConfigPath -or -not $Port) {
        Write-Host "Usage: wg-socks install <config_path> <port>" -ForegroundColor Red; return
    }
    if (-not (Test-Path $ConfigPath)) {
        Write-Host "Error: File not found: $ConfigPath" -ForegroundColor Red; return
    }
    if ($Port -notmatch '^\d+$' -or [int]$Port -lt 1 -or [int]$Port -gt 65535) {
        Write-Host "Error: Invalid port '$Port'. Must be between 1 and 65535." -ForegroundColor Red; return
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

    nssm install $serviceName $binaryPath "-c $confDest"
    nssm set $serviceName Start SERVICE_AUTO_START
    nssm start $serviceName
    Write-Host "SUCCESS: $serviceName is active on port $Port" -ForegroundColor Green
}

function List-Socks {
    $services = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*-wgsocks" }
    if (-not $services) { Write-Host "No tunnels found." -ForegroundColor Gray; return }

    "{0,-30} {1,-10} {2,-10}" -f "SERVICE NAME", "STATUS", "PORT" | Write-Host -ForegroundColor Cyan
    Write-Host ("=" * 60)

    foreach ($svc in $services) {
        $confFile = "$confDir\$($svc.Name -replace '-wgsocks','').conf"
        $port = (Get-Content $confFile | Where-Object { $_ -match "BindAddress" }) -replace '.*:', ''
        "{0,-30} {1,-10} {2,-10}" -f $svc.Name, $svc.Status, $port.Trim() | Write-Host
    }
}

function Test-Socks {
    param([string]$Name)
    if (-not $Name) { Write-Host "Usage: wg-socks test <name>" -ForegroundColor Red; return }

    $baseName = $Name -replace '-wgsocks', ''
    $confFile = "$confDir\$baseName.conf"
    if (-not (Test-Path $confFile)) {
        Write-Host "Error: Config not found for '$Name'" -ForegroundColor Red; return
    }

    $port = (Get-Content $confFile | Where-Object { $_ -match "BindAddress" }) -replace '.*:', ''
    $port = $port.Trim()
    Write-Host "Testing proxy on port $port..." -ForegroundColor Cyan

    try {
        $ip = Invoke-RestMethod -Uri "https://ifconfig.me/ip" -Proxy "socks5://127.0.0.1:$port" -ErrorAction Stop
        Write-Host "Proxy Working! IP: $ip" -ForegroundColor Green
    } catch {
        Write-Host "Test Failed. Is the service running? Try: wg-socks restart $baseName" -ForegroundColor Red
    }
}

function Remove-Socks {
    param([string]$Name)
    if (-not $Name) { Write-Host "Usage: wg-socks remove <name>" -ForegroundColor Red; return }

    if (-not (Is-Admin)) { Elevate-Action "remove $Name"; return }

    $confFile = "$confDir\$($Name -replace '-wgsocks','').conf"
    nssm stop $Name
    nssm remove $Name confirm
    Remove-Item $confFile -ErrorAction SilentlyContinue
    Write-Host "Removed $Name." -ForegroundColor Green
}

if (-not (Get-Command nssm -ErrorAction SilentlyContinue)) {
    Write-Host "nssm not found." -ForegroundColor Red; exit
}
if (-not (Test-Path $binaryPath)) {
    Write-Host "wireproxy.exe not found at: $binaryPath" -ForegroundColor Red; exit
}

switch ($Action) {
    "install" { Install-Socks $Arg1 $Arg2 }
    "list"    { List-Socks }
    "remove"  { Remove-Socks $Arg1 }
    "test"    { Test-Socks $Arg1 }
    default {
        Write-Host "Usage: wg-socks {install|list|remove|test}" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  install <config_path> <port>  Install a new WireGuard SOCKS5 tunnel"
        Write-Host "  list                          List all tunnels and their status"
        Write-Host "  test <name>                   Test a tunnel by checking its public IP"
        Write-Host "  remove <name>                 Stop and remove a tunnel"
    }
}