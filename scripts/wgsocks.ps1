param([string]$Action, [string]$Arg1, [string]$Arg2)

$binaryPath = "$env:USERPROFILE\windows-config-scripts\wg-socks\wireproxy.exe"
$confDir = "$env:USERPROFILE\windows-config-scripts\wg-socks\configs"

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

function _PrintHeader {
    param([string]$Icon, [string]$Title)
    Write-Host ""
    Write-Host "$Icon  $Title" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkBlue
}

function _PrintFooter {
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`n" -ForegroundColor DarkBlue
}

function _PrintRow {
    param([string]$Icon, [string]$Label, [string]$Value, [string]$Color = "White")
    Write-Host ("│  {0} {1,-12} {2}" -f $Icon, $Label, $Value) -ForegroundColor $Color
}

function _InstallSocks {
    param([string]$ConfigPath, [string]$Port)

    if (-not (_IsAdmin)) {
        $fullPath = Resolve-Path $ConfigPath -ErrorAction SilentlyContinue
        if (-not $fullPath) {
            Write-Host "󰅙 Error: File not found: $ConfigPath" -ForegroundColor Red; return
        }
        _ElevateAction "install `"$fullPath`" $Port"
        return
    }

    if (-not $ConfigPath -or -not $Port) {
        Write-Host "󰋖 Usage: wgsocks install <config_path> <port>" -ForegroundColor Red; return
    }
    if (-not (Test-Path $ConfigPath)) {
        Write-Host "󰅙 Error: File not found: $ConfigPath" -ForegroundColor Red; return
    }
    if ($Port -notmatch '^\d+$' -or [int]$Port -lt 1 -or [int]$Port -gt 65535) {
        Write-Host "󰅙 Error: Invalid port '$Port'. Must be between 1 and 65535." -ForegroundColor Red; return
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

    _PrintHeader "󱌣" "Installing Tunnel: $serviceName"
    nssm install $serviceName $binaryPath "-c $confDest"
    nssm set $serviceName Start SERVICE_AUTO_START
    nssm start $serviceName
    _PrintRow "󰄬" "Status" "Active on port $Port" "Green"
    _PrintFooter
}

function _ListSocks {
    $services = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*-wgsocks" }
    if (-not $services) {
        _PrintHeader "󰒄" "WireGuard SOCKS5 Tunnels"
        _PrintRow "󰋼" "Status" "No tunnels found" "Gray"
        _PrintFooter
        return
    }

    _PrintHeader "󰒄" "WireGuard SOCKS5 Tunnels"
    Write-Host ("│  {0,-35} {1,-12} {2}" -f "SERVICE NAME", "STATUS", "PORT") -ForegroundColor White
    foreach ($svc in $services) {
        $confFile = "$confDir\$($svc.Name -replace '-wgsocks','').conf"
        $port = (Get-Content $confFile | Where-Object { $_ -match "BindAddress" }) -replace '.*:', ''
        $color = if ($svc.Status -eq "Running") { "Green" } else { "Red" }
        Write-Host ("│  {0,-35} {1,-12} {2}" -f $svc.Name, $svc.Status, $port.Trim()) -ForegroundColor $color
    }
    _PrintFooter
}

function _TestSocks {
    param([string]$Name)
    if (-not $Name) {
        Write-Host "󰋖 Usage: wgsocks test <name>" -ForegroundColor Red; return
    }

    $baseName = $Name -replace '-wgsocks', ''
    $confFile = "$confDir\$baseName.conf"
    if (-not (Test-Path $confFile)) {
        Write-Host "󰅙 Error: Config not found for '$Name'" -ForegroundColor Red; return
    }

    $port = (Get-Content $confFile | Where-Object { $_ -match "BindAddress" }) -replace '.*:', ''
    $port = $port.Trim()

    _PrintHeader "󰒄" "Testing Tunnel: $Name"
    _PrintRow "󰋼" "Port" $port "Cyan"
    try {
        $ip = Invoke-RestMethod -Uri "https://ifconfig.me/ip" -Proxy "socks5://127.0.0.1:$port" -ErrorAction Stop
        _PrintRow "󰄬" "Status" "Proxy Working" "Green"
        _PrintRow "󰩟" "IP" $ip "Green"
    } catch {
        _PrintRow "󰅙" "Status" "Test Failed. Is the service running?" "Red"
    }
    _PrintFooter
}

function _RemoveSocks {
    param([string]$Name)
    if (-not $Name) {
        Write-Host "󰋖 Usage: wgsocks remove <name>" -ForegroundColor Red; return
    }

    if (-not (_IsAdmin)) { _ElevateAction "remove $Name"; return }

    $confFile = "$confDir\$($Name -replace '-wgsocks','').conf"
    _PrintHeader "󰗨" "Removing Tunnel: $Name"
    nssm stop $Name
    nssm remove $Name confirm
    Remove-Item $confFile -ErrorAction SilentlyContinue
    _PrintRow "󰄬" "Status" "Removed successfully" "Green"
    _PrintFooter
}

if (-not (Test-Path $binaryPath)) {
    Write-Host "󰅙 wireproxy.exe not found at: $binaryPath" -ForegroundColor Red; exit
}

switch ($Action) {
    "install" { _InstallSocks $Arg1 $Arg2 }
    "list"    { _ListSocks }
    "remove"  { _RemoveSocks $Arg1 }
    "test"    { _TestSocks $Arg1 }
    default {
        _PrintHeader "󰒄" "WireGuard SOCKS5 Manager"
        _PrintRow "󱌣" "install" "<path> <port>  Create tunnel"
        _PrintRow "󰒄" "list" "List all tunnels"
        _PrintRow "󰄬" "test" "<name>         Test connectivity"
        _PrintRow "󰗨" "remove" "<name>         Remove tunnel"
        _PrintFooter
    }
}