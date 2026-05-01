param([string]$Action, [string]$Arg1, [string]$Arg2)

$confDir = "$env:APPDATA\windows-config\wg-socks\configs"

# ==============================================================================
# HELPERS
# ==============================================================================

function _IsAdmin
{
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function _ElevateAction
{
    if (Get-Command gsudo -ErrorAction SilentlyContinue) {
        Write-Host "󰮯 Elevating to Administrator..." -ForegroundColor Cyan
        
        # Explicitly name the parameters for the elevated call
        gsudo pwsh -File "$PSCommandPath" -Action "$Action" -Arg1 "$Arg1" -Arg2 "$Arg2"
        exit
    }
    else {
        Write-Error "gsudo is required for elevation. Install with 'winget install gsudo'."
        pause
        exit
    }
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

# ==============================================================================
# ACTIONS
# ==============================================================================

function _InstallSocks
{
    param([string]$ConfigPath, [string]$Port)

    if (-not $ConfigPath -or -not $Port)
    {
        Write-Host "󰋖 Usage: wgsocks install <config_path> <port>" -ForegroundColor Red
        return
    }

    if ($Port -notmatch '^\d+$' -or [int]$Port -lt 1 -or [int]$Port -gt 65535)
    {
        Write-Host "󰅙  Invalid port '$Port'. Must be between 1 and 65535." -ForegroundColor Red
        return
    }

    if (-not (_IsAdmin))
    {
        $fullPath = Resolve-Path $ConfigPath -ErrorAction SilentlyContinue
        if (-not $fullPath)
        {
            Write-Host "󰅙  File not found: $ConfigPath" -ForegroundColor Red
            return
        }
        # Update Arg1 to full path so the elevated process finds it
        $script:Arg1 = $fullPath.Path
        _ElevateAction
        return
    }

    if (-not (Test-Path $ConfigPath))
    {
        Write-Host "󰅙  File not found: $ConfigPath" -ForegroundColor Red
        return
    }

    $configBase  = [System.IO.Path]::GetFileNameWithoutExtension($ConfigPath)
    $serviceName = "$configBase-wgsocks"
    $confDest    = "$confDir\$configBase.conf"

    if (!(Test-Path $confDir))
    {
        New-Item -ItemType Directory -Path $confDir -Force | Out-Null
    }
    Copy-Item $ConfigPath $confDest -Force

    $content      = Get-Content $confDest -Raw
    $socksPattern = '(?ms)(\[Socks5\][^\[]*?BindAddress\s*=\s*)[^\r\n]+'
    if ($content -match $socksPattern)
    { $content = $content -replace $socksPattern, "`${1}0.0.0.0:$Port" }
    else
    { $content = $content.TrimEnd() + "`n`n[Socks5]`nBindAddress = 0.0.0.0:$Port`n" }
    $content | Set-Content $confDest -NoNewline

    $wireproxyPath = (Get-Command wireproxy -ErrorAction SilentlyContinue)?.Source
    if (-not $wireproxyPath)
    {
        Write-Host "󰅙  wireproxy not found in PATH. Run setup-main.ps1 first." -ForegroundColor Red
        return
    }

    _PrintHeader "󱌣" "Installing Tunnel: $serviceName"

    servy-cli install --name="$serviceName" --path="$wireproxyPath" --params="-c `"$confDest`"" --startupType=Automatic --enableHealth --heartbeatInterval=10 --maxFailedChecks=3 --recoveryAction=RestartProcess --maxRestartAttempts=10 --quiet

    if ($LASTEXITCODE -ne 0)
    { Write-Host "󰅙  Install FAILED (exit $LASTEXITCODE)" -ForegroundColor Red; _PrintFooter; return }

    servy-cli start --name="$serviceName" --quiet

    if ($LASTEXITCODE -ne 0)
    { Write-Host "󰅙  Start FAILED (exit $LASTEXITCODE)" -ForegroundColor Red; _PrintFooter; return }

    Write-Host "󰄬  Active on port $Port" -ForegroundColor Green
    _PrintFooter
}

function _ListSocks
{
    $services = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*-wgsocks" }

    _PrintHeader "󰒄" "WireGuard SOCKS5 Tunnels"

    if (-not $services)
    {
        Write-Host "    No tunnels found." -ForegroundColor Gray
        _PrintFooter
        return
    }

    Write-Host ("│  {0,-35} {1,-12} {2}" -f "SERVICE NAME", "STATUS", "PORT") -ForegroundColor White
    foreach ($svc in $services)
    {
        $confFile = "$confDir\$($svc.Name -replace '-wgsocks','').conf"
        $port = if (Test-Path $confFile)
        {
            $bindLine = Get-Content $confFile | Where-Object { $_ -match "BindAddress" } | Select-Object -First 1
            if ($bindLine) { ($bindLine -split ':')[-1].Trim() } else { "unknown" }
        } else { "missing conf" }

        $color = if ($svc.Status -eq "Running") { "Green" } else { "Red" }
        Write-Host ("│  {0,-35} {1,-12} {2}" -f $svc.Name, $svc.Status, $port) -ForegroundColor $color
    }
    _PrintFooter
}

function _UninstallSocks
{
    if (-not (_IsAdmin)) { _ElevateAction; return }

    $services = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*-wgsocks" })
    if (-not $services)
    {
        Write-Host "󰋼  No tunnels found." -ForegroundColor Gray
        return
    }

    _PrintHeader "󰗨" "Uninstall Tunnels"
    for ($i = 0; $i -lt $services.Count; $i++)
    {
        $confFile = "$confDir\$($services[$i].Name -replace '-wgsocks','').conf"
        $port = "unknown"
        if (Test-Path $confFile)
        {
            $bindLine = Get-Content $confFile -ErrorAction SilentlyContinue |
                Where-Object { $_ -match "BindAddress" } | Select-Object -First 1
            if ($bindLine) { $port = ($bindLine -split ':')[-1].Trim() }
        }
        Write-Host ("│  {0,-4} {1,-35} {2}" -f "[$($i+1)]", $services[$i].Name, $port) -ForegroundColor White
    }

    Write-Host "│"
    $inputs = Read-Host "│  Enter numbers to uninstall (comma separated)"
    if (-not $inputs) { _PrintFooter; return }

    $backupDir = Join-Path ([Environment]::GetFolderPath("Desktop")) "wg-socks-backup"
    if (!(Test-Path $backupDir))
    {
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    }

    $selected = $inputs -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' }
    foreach ($num in $selected)
    {
        $idx = [int]$num - 1
        if ($idx -lt 0 -or $idx -ge $services.Count)
        {
            Write-Host "󰅙  Invalid number: $num" -ForegroundColor Red
            continue
        }

        $svc      = $services[$idx]
        $confFile = "$confDir\$($svc.Name -replace '-wgsocks','').conf"

        if (Test-Path $confFile)
        {
            Copy-Item $confFile $backupDir -Force
            Write-Host "󰄬  Backed up $($svc.Name) → Desktop\wg-socks-backup" -ForegroundColor Cyan
        }

        servy-cli stop      --name="$($svc.Name)" --quiet
        servy-cli uninstall --name="$($svc.Name)" --quiet
        Remove-Item $confFile -ErrorAction SilentlyContinue

        Write-Host "󰄬  Removed $($svc.Name)" -ForegroundColor Green
    }
    _PrintFooter
}

function _RefreshSocks
{
    if (-not (_IsAdmin)) { _ElevateAction; return }

    $services = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*-wgsocks" }

    _PrintHeader "󰒄" "Refresh Tunnels"

    if (-not $services)
    {
        Write-Host "    No tunnels found." -ForegroundColor Gray
        _PrintFooter
        return
    }

    foreach ($svc in $services)
    {
        servy-cli restart --name="$($svc.Name)" --quiet
        if ($LASTEXITCODE -eq 0)
        { Write-Host "󰑐  $($svc.Name)" -ForegroundColor Green }
        else
        { Write-Host "󰅙  $($svc.Name)" -ForegroundColor Red }
    }
    _PrintFooter
}

function _UpdateWireproxy
{
    if (-not (_IsAdmin)) { _ElevateAction; return }

    _PrintHeader "󰚰" "Update wireproxy"

    $services = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*-wgsocks" }
    foreach ($svc in $services)
    {
        servy-cli stop --name="$($svc.Name)" --quiet
        Write-Host "󰄾  Stopped $($svc.Name)" -ForegroundColor Yellow
    }

    go install github.com/windtf/wireproxy/cmd/wireproxy@latest

    if ($LASTEXITCODE -ne 0)
    { Write-Host "󰅙  go install failed" -ForegroundColor Red; _PrintFooter; return }

    Write-Host "󰄬  wireproxy updated" -ForegroundColor Green

    foreach ($svc in $services)
    {
        servy-cli start --name="$($svc.Name)" --quiet
        if ($LASTEXITCODE -eq 0)
        { Write-Host "󰑐  $($svc.Name)" -ForegroundColor Green }
        else
        { Write-Host "󰅙  $($svc.Name)" -ForegroundColor Red }
    }
    _PrintFooter
}

# ==============================================================================
# MAIN ENTRY
# ==============================================================================

if (-not (Get-Command wireproxy -ErrorAction SilentlyContinue))
{
    Write-Host "󰅙  wireproxy not found in PATH. Run setup-main.ps1 first." -ForegroundColor Red
    exit
}

switch ($Action)
{
    "install"   { _InstallSocks $Arg1 $Arg2 }
    "list"      { _ListSocks }
    "uninstall" { _UninstallSocks }
    "refresh"   { _RefreshSocks }
    "update"    { _UpdateWireproxy }
    default
    {
        _PrintHeader "󰒄" "WireGuard SOCKS5 Manager"
        _PrintRow "󱌣" "install"   "<path> <port>  Create tunnel"
        _PrintRow "󰒄" "list"      "List all tunnels"
        _PrintRow "󰑐" "refresh"   "Restart all tunnels"
        _PrintRow "󰗨" "uninstall" "Remove tunnel(s)"
        _PrintRow "󰚰" "update"    "Update wireproxy binary"
        _PrintFooter
    }
}