param(
    [string]$Action,
    [string]$Name,
    [string]$SourcePath
)

$ConfigPath = $env:WINDOWS_CONFIG_PATH
. "$ConfigPath\helpers\dep-checker.ps1"

if (-not (_TestDependencies -Commands "gsudo", "fzf", "wireguard"))
{
    Write-Host "Script stopped due to missing dependencies.`n" -ForegroundColor Red
    return
}

. "$ConfigPath\helpers\backup-wg-configs.ps1"
. "$ConfigPath\helpers\wgm-helper.ps1"

# --- Paths --------------------------------------------------------------------
$wgmRoot    = "$env:LOCALAPPDATA\windows-config-files\wgm"
$configsDir = "$wgmRoot\configs"
New-Item -ItemType Directory -Path $configsDir -Force > $null
$warpConf   = "$env:LOCALAPPDATA\windows-config-files\wgm\configs\warp\warp.conf"

# --- Helpers ------------------------------------------------------------------

function _GetAllConfigs {
    $list = [System.Collections.Generic.List[hashtable]]::new()
    $list.Add(@{ Name = "warp"; Path = $warpConf; Builtin = $true })
    Get-ChildItem "$configsDir\*.conf" -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -ne "warp" } |
        Sort-Object Name |
        ForEach-Object {
            $list.Add(@{ Name = $_.BaseName; Path = $_.FullName; Builtin = $false })
        }
    return $list
}

# --- FZF picker ---------------------------------------------------------------
function _PickConfig {
    param([string]$Prompt = "Select WireGuard profile")
    $configs = _GetAllConfigs
    if ($configs.Count -eq 0) {
        Write-Host "No WireGuard configs available." -ForegroundColor Yellow
        return $null
    }
    $lines = $configs | ForEach-Object { $_.Name }
    [string]$selected = $lines | fzf --prompt="$Prompt > " --reverse --height=40%
    if (-not $selected) { return $null }
    return $configs | Where-Object { $_.Name -eq $selected.Trim() } | Select-Object -First 1
}

# --- Actions ------------------------------------------------------------------
function _WgOn
{
    $wgProfile = _PickConfig "Connect to"
    if (-not $wgProfile) { Write-Host "Cancelled." -ForegroundColor Yellow; return }

    $active = Get-WgmActiveTunnel
    if ($active) {
        if ($active -eq $wgProfile.Name) {
            Write-Host "'$active' is already active and running." -ForegroundColor Yellow
            return
        }
        
        Write-Host "Switching profiles... Turning off active tunnel '$active' first." -ForegroundColor Yellow
        
        if (-not (Disconnect-WgmTunnel -TunnelName $active -UseGsudo)) {
            Write-Host "Failed to disconnect '$active'. Aborting profile switch." -ForegroundColor Red
            return
        }
        Write-Host "Successfully disconnected from '$active'." -ForegroundColor Green
        Start-Sleep -Milliseconds 1000 
    }

    if (-not (Test-Path $wgProfile.Path)) {
        if ($wgProfile.Builtin -and $wgProfile.Name -eq "warp") {
            Write-Host "Warp config not found. Generating with wgcf..." -ForegroundColor Yellow
            $warpDir = Split-Path $wgProfile.Path -Parent
            New-Item -ItemType Directory -Path $warpDir -Force | Out-Null
            Push-Location $warpDir
            try {
                wgcf register --accept-tos
                wgcf generate
                $generated = Join-Path $warpDir "wgcf-profile.conf"
                Move-Item $generated $wgProfile.Path -Force -ErrorAction Stop
                Write-Host "Warp config generated: $($wgProfile.Path)" -ForegroundColor Green
            } catch {
                Write-Host "wgcf failed: $($_.Exception.Message)" -ForegroundColor Red
                return
            } finally {
                Pop-Location
            }
        } else {
            Write-Host "Config file not found: $($wgProfile.Path)" -ForegroundColor Red
            return
        }
    }
 
    gsudo wireguard /installtunnelservice $wgProfile.Path
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Connected to $($wgProfile.Name) successfully!" -ForegroundColor Green
        Start-Sleep -Milliseconds 1000
    } else {
        Write-Host "Failed to connect to $($wgProfile.Name)." -ForegroundColor Red
    }
}

function _WgOff
{
    $active = Get-WgmActiveTunnel 
    if (-not $active) {
        Write-Host "No active tunnel found." -ForegroundColor Yellow
        return
    }    
    if (Disconnect-WgmTunnel -TunnelName $active -UseGsudo) {
        Write-Host "Disconnected from $active" -ForegroundColor Green
        Start-Sleep -Milliseconds 1000
    } else {
        Write-Host "Disconnect failed" -ForegroundColor Red
    }
}

function _WgAdd
{
    param([string]$Name, [string]$SourcePath)

    if (-not $Name -or -not $SourcePath) {
        Write-Host "Usage: wgm add <name> <path-to-conf>" -ForegroundColor Yellow
        return
    }
    
    $Name = $Name.ToLower().Trim()
    if ($Name -eq "warp") {
        Write-Host "'warp' is a built-in profile and cannot be overwritten." -ForegroundColor Red
        return
    }

    $existingConfigs = _GetAllConfigs
    if ($existingConfigs.Name -contains $Name) {
        Write-Host "A profile named '$Name' already exists. Choose a unique name or remove the old profile first." -ForegroundColor Red
        return
    }

    $src = Resolve-Path $SourcePath -ErrorAction SilentlyContinue
    if (-not $src) {
        Write-Host "Source file not found: $SourcePath" -ForegroundColor Red
        return
    }

    if ($src -is [array]) { $src = $src[0] }

    if (Test-Path -LiteralPath $src.Path -PathType Container) {
        Write-Host "Source path is a folder, not a file: $($src.Path)" -ForegroundColor Red
        return
    }

    $dest = "$configsDir\$Name.conf"
    $copySucceeded = $false
    try {
        Copy-Item -LiteralPath $src.Path -Destination $dest -Force -ErrorAction Stop
        $copySucceeded = $true
    } catch {
        Write-Host "Error copying file: $_" -ForegroundColor Red
        $copySucceeded = $false
    }

    if ($copySucceeded -and (Test-Path -LiteralPath $dest -PathType Leaf)) {
        Write-Host "Added profile '$Name' successfully." -ForegroundColor Green
        Write-Host "Saved & renamed config to: $dest" -ForegroundColor Green
    } else {
        Write-Host "Failed to copy or rename configuration profile." -ForegroundColor Red
        if (Test-Path -LiteralPath $dest -PathType Container) {
            Write-Host "A folder was created at '$dest' instead of a file - removing it." -ForegroundColor Red
            Remove-Item -LiteralPath $dest -Force -Recurse -ErrorAction SilentlyContinue
        }
    }
}

function _WgRemove
{
    $configs = _GetAllConfigs | Where-Object { -not $_.Builtin }

    if ($configs.Count -eq 0) {
        Write-Host "No user-added profiles to remove." -ForegroundColor Yellow
        return
    }

    $selected = ($configs | ForEach-Object { $_.Name }) |
        fzf --prompt="Remove profile > " --reverse --height=40%

    if (-not $selected) { Write-Host "Cancelled." -ForegroundColor Yellow; return }

    $target = "$configsDir\$selected.conf"
    if (Test-Path $target) {
        
        $active = Get-WgmActiveTunnel 
        if ($active -eq $selected) {
            Write-Host "'$selected' is currently active. Disconnecting first..." -ForegroundColor Yellow
            
            if (-not (Disconnect-WgmTunnel -TunnelName $active -UseGsudo)) {
                Write-Host "Failed to disconnect active tunnel. Aborting removal." -ForegroundColor Red
                return
            }
            
            Write-Host "Successfully disconnected." -ForegroundColor Green
        }

        $userDocs = [Environment]::GetFolderPath("MyDocuments")
        $backupRoot = Join-Path $userDocs "wgm-backup"
        $backupFile = Join-Path $backupRoot "$selected.conf"
        
        if (Backup-Configs -SourcePath $target -BackupDir $backupRoot) {
            try {
                Remove-Item $target -Force -ErrorAction Stop
                Write-Host "Removed profile: '$selected'." -ForegroundColor Green
                Write-Host "Backup saved to: $backupFile" -ForegroundColor Green
            } catch {
                Write-Host "Failed to delete configuration file: $_" -ForegroundColor Red
            }
        } else {
            Write-Host "Backup sequence failed. Aborting deletion for safety." -ForegroundColor Red  
        }
    } else {
        Write-Host "Config file not found: $target" -ForegroundColor Red
    }
}

function _WgStatus
{
    $configs = _GetAllConfigs
    $runningSvcs = Get-Service -Name "WireGuardTunnel*" -ErrorAction SilentlyContinue |
                   Where-Object { $_.Status -eq "Running" } |
                   ForEach-Object { $_.Name -replace "^WireGuardTunnel\\$", "" }

    if ($runningSvcs) {
        foreach ($svc in $runningSvcs) {
            Write-Host "Connected: $svc" -ForegroundColor Green
        }
    } else {
        Write-Host "No active tunnel" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "Registered profiles:"

    foreach ($cfg in $configs) {
        $avail        = Test-Path $cfg.Path
        $status_label = if ($avail) { "Available" } else { "Missing" }
        $tag          = if ($cfg.Builtin) { " [warp]" } else { "" }
        $active_marker = if ($runningSvcs -contains $cfg.Name) { " (active)" } else { "" }
        $msg_line     = "  {0}: {1}{2}{3}" -f $status_label, $cfg.Name, $tag, $active_marker

        if ($avail) {
            Write-Host $msg_line -ForegroundColor Green
        } else {
            Write-Host $msg_line -ForegroundColor Red
        }
    }
}

# ==============================================================================
# DISPATCH ENTRY
# ==============================================================================

switch ($Action) {
    "on"     { _WgOn }
    "off"    { _WgOff }
    "add"    { _WgAdd -Name $Name -SourcePath $SourcePath }
    "rm"     { _WgRemove } 
    "status" { _WgStatus }
    default {
        Write-Host ">WireGuard Manager" -ForegroundColor Blue
        Write-Host "Usage: wgm <action> [arguments]" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Actions:"
        Write-Host "  on       - Connect to a tunnel"
        Write-Host "  off      - Disconnect active tunnel"
        Write-Host "  add      - Add a new profile (wgm add <name> <path>)"
        Write-Host "  rm       - Remove a WireGuard Profile"
        Write-Host "  status   - Show tunnel status and all profiles"
        Write-Host ""
    }
}