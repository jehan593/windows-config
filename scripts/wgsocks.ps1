param([string]$Action, [string]$Arg1, [string]$Arg2)

. (Join-Path $PSScriptRoot "helpers\elevate.ps1")
. (Join-Path $PSScriptRoot "helpers\printers.ps1")

$confDir = "$env:LOCALAPPDATA\windows-config\wg-socks\configs"

# ==============================================================================
# HELPERS
# ==============================================================================

function _GetSocksPort([string]$ConfFile)
{
    if (-not (Test-Path $ConfFile)) { return "missing conf" }
    $line = Get-Content $ConfFile | Where-Object { $_ -match "BindAddress" } | Select-Object -First 1
    if ($line) { return ($line -split ':')[-1].Trim() }
    return "unknown"
}

# ==============================================================================
# ACTIONS
# ==============================================================================

function _AddSocks
{
    param([string]$ConfigPath, [string]$Port)

    if (-not $ConfigPath -or -not $Port)
    {
        Write-Host "Usage: wgsocks add <config_path> <port>" -ForegroundColor Yellow
        return
    }

    if ($Port -notmatch '^\d+$' -or [int]$Port -lt 1 -or [int]$Port -gt 65535)
    {
        Write-Host "Error: Invalid port '$Port'. Must be 1-65535." -ForegroundColor Red
        return
    }

    $resolvedPath = Resolve-Path $ConfigPath -ErrorAction SilentlyContinue
    if (-not $resolvedPath)
    {
        Write-Host "Error: File not found: $ConfigPath" -ForegroundColor Red
        return
    }
    $ConfigPath = $resolvedPath.Path

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
        Write-Host "Error: wireproxy not found. Run setup-main.ps1 first." -ForegroundColor Red
        return
    }

    _PrintHeader "Adding Tunnel: $serviceName"

    servy-cli install --name="$serviceName" --path="$wireproxyPath" --params="-c `"$confDest`"" --startupType=Automatic --enableHealth --heartbeatInterval=10 --maxFailedChecks=3 --recoveryAction=RestartProcess --maxRestartAttempts=10 --quiet

    if ($LASTEXITCODE -ne 0)
    { Write-Host "Error: Install failed (exit $LASTEXITCODE)" -ForegroundColor Red; _PrintFooter; return }

    servy-cli start --name="$serviceName" --quiet

    if ($LASTEXITCODE -ne 0)
    { Write-Host "Error: Start failed (exit $LASTEXITCODE)" -ForegroundColor Red; _PrintFooter; return }

    Write-Host "Active on port $Port" -ForegroundColor Green
    _PrintFooter
}

function _ListSocks
{
    $services = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*-wgsocks" }

    _PrintHeader "WireGuard SOCKS5 Tunnels"

    if (-not $services)
    {
        Write-Host "No tunnels found." -ForegroundColor Gray
        _PrintFooter
        return
    }

    Write-Host ("  {0,-35} {1,-12} {2}" -f "SERVICE NAME", "STATUS", "PORT") -ForegroundColor DarkGray
    foreach ($svc in $services)
    {
        $confFile = "$confDir\$($svc.Name -replace '-wgsocks','').conf"
        $port = _GetSocksPort $confFile

        $color = if ($svc.Status -eq "Running") { "Green" } else { "Red" }
        Write-Host ("  {0,-35} {1,-12} {2}" -f $svc.Name, $svc.Status, $port) -ForegroundColor $color
    }
    _PrintFooter
}

function _RemoveSocks
{
    $services = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*-wgsocks" })
    if (-not $services)
    {
        Write-Host "No tunnels found." -ForegroundColor Gray
        
        return
    }

    if (-not (Get-Command fzf -ErrorAction SilentlyContinue))
    {
        Write-Host "Error: fzf not found. Install it first (e.g. winget install fzf)." -ForegroundColor Red
        return
    }

    $entries = $services | ForEach-Object {
        [PSCustomObject]@{
            Line = $_.Name
            Svc  = $_
        }
    }

    $picked = $entries.Line | fzf --reverse --multi --height=70% --header="TAB to select, ENTER to confirm removal" --prompt="Remove> "
    if (-not $picked) { _PrintFooter; return }

    _PrintHeader "Remove Tunnels"

    $backupDir = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "wg-socks-backup"
    if (!(Test-Path $backupDir))
    {
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    }

    foreach ($line in $picked)
    {
        $entry = $entries | Where-Object { $_.Line -eq $line } | Select-Object -First 1
        if (-not $entry)
        {
            Write-Host "Error: Could not resolve selection: $line" -ForegroundColor Red
            continue
        }

        $svc      = $entry.Svc
        $confFile = "$confDir\$($svc.Name -replace '-wgsocks','').conf"

        if (Test-Path $confFile)
        {
            Copy-Item $confFile $backupDir -Force
            Write-Host "Backed up $($svc.Name)" -ForegroundColor Cyan
        }

        servy-cli stop      --name="$($svc.Name)" --quiet
        servy-cli uninstall --name="$($svc.Name)" --quiet
        if ($LASTEXITCODE -ne 0)
        {
            Write-Host "Error: Failed to uninstall $($svc.Name)" -ForegroundColor Red
            continue
        }
        Remove-Item $confFile -ErrorAction SilentlyContinue

        Write-Host "Removed $($svc.Name)" -ForegroundColor Green
    }
    _PrintFooter
}

function _RefreshSocks
{
    $services = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*-wgsocks" }

    _PrintHeader "Refresh Tunnels"

    if (-not $services)
    {
        Write-Host "No tunnels found." -ForegroundColor Gray
        _PrintFooter
        return
    }

    foreach ($svc in $services)
    {
        servy-cli restart --name="$($svc.Name)" --quiet
        if ($LASTEXITCODE -eq 0)
        { Write-Host "Restarted: $($svc.Name)" -ForegroundColor Green }
        else
        { Write-Host "Failed:    $($svc.Name)" -ForegroundColor Red }
    }
    _PrintFooter
}

function _UpdateWireproxy
{
    _PrintHeader "Update wireproxy"

    $services = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*-wgsocks" }
    foreach ($svc in $services)
    {
        servy-cli stop --name="$($svc.Name)" --quiet
        Write-Host "Stopped $($svc.Name)" -ForegroundColor Yellow
    }

    if (-not (Get-Command gup -ErrorAction SilentlyContinue))
    {
        Write-Host "gup not found. Install it with: go install github.com/nao1215/gup@latest" -ForegroundColor Red
        _PrintFooter
        return
    }

    gup update wireproxy

    if ($LASTEXITCODE -ne 0)
    { Write-Host "Error: gup update failed" -ForegroundColor Red; _PrintFooter; return }

    Write-Host "wireproxy updated successfully" -ForegroundColor Green

    $services = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*-wgsocks" }
    foreach ($svc in $services)
    {
        servy-cli start --name="$($svc.Name)" --quiet
        if ($LASTEXITCODE -eq 0)
        { Write-Host "Started: $($svc.Name)" -ForegroundColor Green }
        else
        { Write-Host "Failed:  $($svc.Name)" -ForegroundColor Red }
    }
    _PrintFooter
}

# ==============================================================================
# MAIN ENTRY
# ==============================================================================

if (-not (Get-Command wireproxy -ErrorAction SilentlyContinue))
{
    Write-Host "Error: wireproxy not found. Run setup-main.ps1 first." -ForegroundColor Red
    exit
}

# Define operations that strictly require local administrative elevation.
# (If you want "list" to completely bypass elevation checks, keep it out of this array)
$RequiresAdminActions = @("add", "remove", "refresh", "update")

if ($Action -in $RequiresAdminActions -and -not (_IsAdmin))
{
    if (-not (_AssertGsudo)) { exit 1 }
    gsudo pwsh -File "$PSCommandPath" -Action "$Action" -Arg1 "$Arg1" -Arg2 "$Arg2"
    exit
}

switch ($Action)
{
    "add"       { _AddSocks $Arg1 $Arg2 }
    "list"      { _ListSocks }
    "remove"    { _RemoveSocks }
    "refresh"   { _RefreshSocks }
    "update"    { _UpdateWireproxy }
    default
    {
        _PrintHeader "WireGuard SOCKS5 Manager"
        _PrintRow "add"       "<path> <port>  Create tunnel"
        _PrintRow "list"      "List all tunnels"
        _PrintRow "refresh"   "Restart all tunnels"
        _PrintRow "remove"    "Remove tunnel(s)"
        _PrintRow "update"    "Update wireproxy binary"
        _PrintFooter
    }
}