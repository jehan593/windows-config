param([string]$Action, [string]$Arg1, [string]$Arg2, [string]$Arg3)

$ConfigPath = $env:WINDOWS_CONFIG_PATH
. "$ConfigPath\helpers\dep-checker.ps1"
. "$ConfigPath\helpers\backup-wg-configs.ps1"
. "$ConfigPath\helpers\wpm-helper.ps1"

# wireproxy is found on the PATH like any other program. Whoever put it there
# - gitget, winget, a manual install - wpm does not care.
function _ResolveWireproxyPath
{
    $cmd = Get-Command wireproxy -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return $cmd.Source }

    # The session PATH can be older than the persisted one, so look there too.
    $paths = @(
        [Environment]::GetEnvironmentVariable("Path", "User")
        [Environment]::GetEnvironmentVariable("Path", "Machine")
    )
    foreach ($path in $paths)
    {
        if (-not $path) { continue }
        foreach ($entry in ($path -split ';'))
        {
            if (-not $entry) { continue }
            $candidate = Join-Path $entry.Trim() "wireproxy.exe"
            if (Test-Path $candidate) { return $candidate }
        }
    }

    return $null
}

$wireproxyPath = _ResolveWireproxyPath

$missingDeps = @(_TestDependencies -Commands "gsudo", "fzf", "servy-cli")
if (-not $wireproxyPath) { $missingDeps += "wireproxy" }
if ($missingDeps.Count -gt 0)
{
    Write-Host "Missing: $($missingDeps -join ', ')" -ForegroundColor Red
    Write-Host "Stopped." -ForegroundColor Red
    return
}

$confDir = "$env:LOCALAPPDATA\windows-config-files\wpm\configs"
New-Item -ItemType Directory -Path $confDir -Force > $null

# ==============================================================================
# HELPERS
# ==============================================================================

function _GetSocksPort([string]$ConfFile)
{
    if (-not (Test-Path $ConfFile)) { return "missing conf" }
    $line = Get-Content $ConfFile | 
            Where-Object { $_ -match "^\s*BindAddress" } | 
            Select-Object -First 1         
    if ($line) { return ($line -split ':')[-1].Trim() }
    return "unknown"
}

function _SelectTunnelsInteractively([string]$Header)
{
    $services = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*-wpm" })
    if (-not $services)
    {
        Write-Host "No tunnels found." -ForegroundColor Yellow
        return $null
    }

    $entries = $services | ForEach-Object {
        $confFile = "$confDir\$($_.Name -replace '-wpm','').conf"
        $port = _GetSocksPort $confFile
        
        $displayLine = "{0,-40} [{1,-7}] (Port: {2})" -f $_.Name, $_.Status, $port
        
        [PSCustomObject]@{
            Line = $displayLine
            Svc  = $_
        }
    }

    $fzfFlags = @("--reverse", "--height=70%", "--header=$Header", "--prompt=Tunnel> ", "--multi")

    $picked = $entries.Line | fzf $fzfFlags
    if (-not $picked) { return $null }

    return ,($entries | Where-Object { $_.Line -in $picked })
}

function _ServyBatchAction
{
    param(
        [Parameter(Mandatory)][ValidateSet("start", "stop", "restart")][string]$Verb,
        [Parameter(Mandatory)][string[]]$ServiceNames
    )

    gsudo {
        param($v, $svcNames)
        $success = $true
        foreach ($name in $svcNames) {
            servy-cli $v --name="$name"
            if ($LASTEXITCODE -ne 0) { $success = $false }
        }
        if ($success) { exit 0 } else { exit 1 }
    } -args $Verb, $ServiceNames

    return ($LASTEXITCODE -eq 0)
}

# ==============================================================================
# ACTIONS
# ==============================================================================

function _AddSocks
{
    param([string]$Name, [string]$ConfigPath, [string]$Port)

    if (-not $Name -or -not $ConfigPath -or -not $Port)
    {
        Write-Host "Usage: wpm add <name> <config_path> <port>" -ForegroundColor Yellow
        return
    }

    if ($Name -notmatch '^[a-zA-Z0-9_-]+$')
    {
        Write-Host "Invalid name '$Name'" -ForegroundColor Red
        return
    }

    if ($Port -notmatch '^\d+$' -or [int]$Port -lt 1 -or [int]$Port -gt 65535)
    {
        Write-Host "Invalid port '$Port'" -ForegroundColor Red
        return
    }

    $resolvedPath = Resolve-Path $ConfigPath -ErrorAction SilentlyContinue
    if (-not $resolvedPath)
    {
        Write-Host "File not found: $ConfigPath" -ForegroundColor Red
        return
    }
    $ConfigPath = $resolvedPath.Path
    $serviceName = "$Name-wpm"
    $confDest    = "$confDir\$Name.conf"

    if ((Get-Service -Name $serviceName -ErrorAction SilentlyContinue) -or (Test-Path $confDest))
    {
        Write-Host "'$Name' already exists" -ForegroundColor Red
        return
    }

    Copy-Item $ConfigPath $confDest -Force

    $content      = Get-Content $confDest -Raw
    $socksPattern = '(?ms)(\[Socks5\][^\[]*?BindAddress\s*=\s*)[^\r\n]+'
    if ($content -match $socksPattern)
    { $content = $content -replace $socksPattern, "`${1}0.0.0.0:$Port" }
    else
    { $content = $content.TrimEnd() + "`n`n[Socks5]`nBindAddress = 0.0.0.0:$Port`n" }
    $content | Set-Content $confDest -NoNewline

    $wireproxyExe = $wireproxyPath

    gsudo {
            param($sName, $wPath, $cDest)
            servy-cli install --name="$sName" --path="$wPath" --params="-c `"$cDest`"" --startupType=Automatic --enableHealth --heartbeatInterval=10 --maxFailedChecks=3 --recoveryAction=RestartProcess --maxRestartAttempts=10
            if ($LASTEXITCODE -eq 0) {
                servy-cli start --name="$sName"
                exit 0 
            }
            exit 1
        } -args $serviceName, $wireproxyExe, $confDest

    if ($LASTEXITCODE -eq 0)
    {
        Write-Host "Active on port $Port" -ForegroundColor Green
    }
    else
    {
        Write-Host "Failed to start $serviceName" -ForegroundColor Red
    }
}

function _ListSocks
{
    $services = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*-wpm" }

    if (-not $services)
    {
        Write-Host "No tunnels found." -ForegroundColor Yellow
        return
    }

    Write-Host ("`n  {0,-25} {1,-12} {2}" -f "TUNNEL SERVICE NAME", "STATUS", "PORT") 
    Write-Host ("  {0,-25} {1,-12} {2}" -f "-------------------", "------", "----") -ForegroundColor Gray

    foreach ($svc in $services)
    {
        $confFile = "$confDir\$($svc.Name -replace '-wpm','').conf"
        $port = _GetSocksPort $confFile
        $msg_line = "  {0,-25} {1,-12} {2}" -f $svc.Name, $svc.Status, $port

        if ($svc.Status -eq "Running") { 
            Write-Host $msg_line -ForegroundColor Green
        } else { 
            Write-Host $msg_line -ForegroundColor Red
        }
    }
}

function _RemoveSocks
{
    $selected = _SelectTunnelsInteractively "TAB to select, ENTER to confirm removal"
    if (-not $selected) { return }

    $backupDir = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "windows-config-backup\wpm"

    $allOk = $true
    foreach ($entry in $selected)
    {
        $svcName  = $entry.Svc.Name
        $confFile = "$confDir\$($svcName -replace '-wpm','').conf"

        if (Test-Path $confFile)
        {
            if (-not (Backup-Configs -SourcePath $confFile -BackupDir $backupDir))
            { $allOk = $false }
        }

        if (Remove-WpmService -ServiceName $svcName -UseGsudo)
        {
            if (Test-Path $confFile)
            {
                Remove-Item $confFile -Force -ErrorAction SilentlyContinue
            }
        }
        else
        { $allOk = $false }
    }

    if ($allOk) {
        Write-Host "Tunnels removed, configs backed up." -ForegroundColor Green
    } else {
        Write-Host "Removal incomplete." -ForegroundColor Red
    }
}

function _RefreshSocks
{
    $services = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*-wpm" }

    if (-not $services)
    {
        Write-Host "No tunnels found." -ForegroundColor Yellow
        return
    }

    $serviceNames = $services | ForEach-Object { $_.Name }

    if (_ServyBatchAction -Verb "restart" -ServiceNames $serviceNames) {
        Write-Host "All tunnels restarted." -ForegroundColor Green
    } else {
        Write-Host "Failed to restart tunnels." -ForegroundColor Red
    }
}

# ==============================================================================
# CONTROLS & UPDATES
# ==============================================================================

function _StartSocks
{
    $serviceNames = $null
    if ($Arg1 -eq "all") { $serviceNames = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*-wpm" } | ForEach-Object { $_.Name }) }
    else {
        $selected = _SelectTunnelsInteractively "TAB to select, ENTER to start tunnels"
        if (-not $selected) { return }
        $serviceNames = @($selected | ForEach-Object { $_.Svc.Name })
    }

    if (-not $serviceNames) {
        Write-Host "No tunnels found." -ForegroundColor Yellow
        return
    }

    if (_ServyBatchAction -Verb "start" -ServiceNames $serviceNames) {
        Write-Host "Tunnels started." -ForegroundColor Green
    } else {
        Write-Host "Failed to start tunnels." -ForegroundColor Red
    }
}

function _StopSocks
{
    $serviceNames = $null
    if ($Arg1 -eq "all") { $serviceNames = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*-wpm" } | ForEach-Object { $_.Name }) }
    else {
        $selected = _SelectTunnelsInteractively "TAB to select, ENTER to stop tunnels" 
        if (-not $selected) { return }
        $serviceNames = @($selected | ForEach-Object { $_.Svc.Name })
    }

    if (-not $serviceNames) {
        Write-Host "No tunnels found." -ForegroundColor Yellow
        return
    }

    if (_ServyBatchAction -Verb "stop" -ServiceNames $serviceNames) {
        Write-Host "Tunnels stopped." -ForegroundColor Green
    } else {
        Write-Host "Failed to stop tunnels." -ForegroundColor Red
    }
}

function _RestartSocks
{
    $selected = _SelectTunnelsInteractively "TAB to select, ENTER to restart tunnels"
    if (-not $selected) { return }

    $serviceNames = $selected | ForEach-Object { $_.Svc.Name }

    if (_ServyBatchAction -Verb "restart" -ServiceNames $serviceNames) {
        Write-Host "Selected tunnels restarted." -ForegroundColor Green
    } else {
        Write-Host "Failed to restart tunnels." -ForegroundColor Red
    }
}

# ==============================================================================
# MAIN ENTRY
# ==============================================================================
switch ($Action)
{
    "add"      { _AddSocks $Arg1 $Arg2 $Arg3 }
    "ls"       { _ListSocks }
    "rm"       { _RemoveSocks }
    "refresh"  { _RefreshSocks }
    "start"    { _StartSocks }
    "stop"     { _StopSocks }
    "restart"  { _RestartSocks }
    default
    {
        Write-Host ">Wireproxy Manager" -ForegroundColor Blue
        Write-Host "Usage: wpm <action> [arguments]" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Actions:"
        Write-Host "  add      - Create tunnel (wpm add <name> <path> <port>)"
        Write-Host "  ls       - List all tunnels"
        Write-Host "  start    - Start target tunnel(s) (wpm start all for every tunnel)"
        Write-Host "  stop     - Stop target tunnel(s) (wpm stop all for every tunnel)"
        Write-Host "  restart  - Restart target tunnel(s)"
        Write-Host "  refresh  - Restart ALL tunnels"
        Write-Host "  rm       - Remove tunnel(s)"
        Write-Host ""
    }
}