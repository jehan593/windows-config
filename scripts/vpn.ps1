param([string]$Action, [string]$Name, [string]$ConfigPath)

# Elevate entire script if not admin
if (-not (_IsAdmin))
{
    if (-not (_AssertGsudo)) { exit 1 }
    gsudo pwsh -File "$PSCommandPath" -Action "$Action" -Name "$Name" -ConfigPath "$ConfigPath"
    exit
}

# ─── Paths ────────────────────────────────────────────────────────────────────
$vpnRoot    = "$env:LOCALAPPDATA\windows-config\vpn"
$configsDir = "$vpnRoot\configs"
$statusFile = "$vpnRoot\active_tunnel"
$warpConf   = "$env:LOCALAPPDATA\windows-config\warp\warp.conf"

# ─── Helpers ──────────────────────────────────────────────────────────────────

function _EnsureDirs {
    @($vpnRoot, $configsDir) | ForEach-Object {
        if (-not (Test-Path $_)) { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
    }
}

function _GetAllConfigs {
    $list = [System.Collections.Generic.List[hashtable]]::new()
    $list.Add(@{ Name = "warp"; Path = $warpConf; Builtin = $true })
    if (Test-Path $configsDir) {
        Get-ChildItem "$configsDir\*.conf" -ErrorAction SilentlyContinue |
            Where-Object { $_.BaseName -ne "warp" } |
            Sort-Object Name |
            ForEach-Object {
                $list.Add(@{ Name = $_.BaseName; Path = $_.FullName; Builtin = $false })
            }
    }
    return $list
}

function _GetActiveTunnel {
    if (Test-Path $statusFile) {
        $val = (Get-Content $statusFile -Raw).Trim() -replace '^[^\s]+\s+', ''
        if ($val) { return $val }
    }
    return Get-Service -Name "WireGuardTunnel*" -ErrorAction SilentlyContinue |
           Where-Object { $_.Status -eq "Running" } |
           Select-Object -First 1 |
           ForEach-Object { $_.Name -replace "WireGuardTunnel$", "" }
}

function _SetActiveTunnel {
    param([string]$TunnelName)
    _EnsureDirs
    Set-Content $statusFile "󰌆 $TunnelName" -Encoding utf8
}

function _ClearActiveTunnel {
    if (Test-Path $statusFile) { Set-Content $statusFile "" -Encoding utf8 }
}

# ─── FZF picker ───────────────────────────────────────────────────────────────
function _PickConfig {
    param([string]$Prompt = "Select VPN profile")

    $configs = _GetAllConfigs

    if ($configs.Count -eq 0) {
        Write-Host "󰅙  No VPN configs available." -ForegroundColor Red
        return $null
    }

    $lines = $configs | ForEach-Object { $_.Name }

    $selected = $lines | fzf --prompt="$Prompt > " --reverse --height=40%

    if (-not $selected) { return $null }

    return $configs | Where-Object { $_.Name -eq $selected.Trim() } | Select-Object -First 1
}

# ─── Actions ──────────────────────────────────────────────────────────────────
function _VpnOn {
    _EnsureDirs

    $active = _GetActiveTunnel
    if ($active) {
        Write-Host "󰅙  '$active' is active. Run 'vpn off' first." -ForegroundColor Red
        return
    }

    $vpnProfile = _PickConfig "Connect to"
    if (-not $vpnProfile) { Write-Host "󰅙  Cancelled." -ForegroundColor DarkGray; return }

    if (-not (Test-Path $vpnProfile.Path)) {
        if ($vpnProfile.Builtin -and $vpnProfile.Name -eq "warp") {
            Write-Host "󰖂  Warp config not found. Generating with wgcf..." -ForegroundColor Cyan
            $warpDir = Split-Path $vpnProfile.Path -Parent
            if (-not (Test-Path $warpDir)) { New-Item -ItemType Directory -Path $warpDir -Force | Out-Null }
            Push-Location $warpDir
            try {
                wgcf register --accept-tos 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) { Write-Host "󰅙  wgcf register failed." -ForegroundColor Red; return }
                wgcf generate 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) { Write-Host "󰅙  wgcf generate failed." -ForegroundColor Red; return }
                $generated = Join-Path $warpDir "wgcf-profile.conf"
                if (Test-Path $generated) {
                    Move-Item $generated $vpnProfile.Path -Force
                    Write-Host "󰄬  Warp config generated: $($vpnProfile.Path)" -ForegroundColor Green
                } else {
                    Write-Host "󰅙  wgcf did not produce a config file." -ForegroundColor Red
                    return
                }
            } catch {
                Write-Host "󰅙  wgcf failed: $_" -ForegroundColor Red
                return
            } finally {
                Pop-Location
            }
        } else {
            Write-Host "󰅙  Config file not found: $($vpnProfile.Path)" -ForegroundColor Red
            return
        }
    }

    _PrintHeader "󰖂" "Connecting: $($vpnProfile.Name)"
    wireguard /installtunnelservice $vpnProfile.Path

    if ($LASTEXITCODE -ne 0) {
        Write-Host "󰅙  Connection failed (exit $LASTEXITCODE)" -ForegroundColor Red
    } else {
        Write-Host "󰤨  Connected to $($vpnProfile.Name)" -ForegroundColor Green
        _SetActiveTunnel $vpnProfile.Name
    }
    _PrintFooter
}

function _VpnOff {

    $active = _GetActiveTunnel

    if (-not $active) {
        Write-Host "󰤭  No active tunnel found." -ForegroundColor DarkGray
        return
    }

    _PrintHeader "󰖂" "Disconnecting: $active"
    wireguard /uninstalltunnelservice $active

    if ($LASTEXITCODE -ne 0) {
        Write-Host "󰅙  Disconnect failed (exit $LASTEXITCODE)" -ForegroundColor Red
    } else {
        Write-Host "󰤭  Disconnected from $active" -ForegroundColor Gray
        _ClearActiveTunnel
    }
    _PrintFooter
}

function _VpnAdd {
    if (-not $Name -or -not $ConfigPath) {
        Write-Host "Usage: vpn add <name> <path-to-conf>" -ForegroundColor Yellow
        return
    }
    if ($Name -eq "warp") {
        Write-Host "󰅙  'warp' is a built-in profile and cannot be overwritten." -ForegroundColor Red
        return
    }

    _EnsureDirs
    $src  = Resolve-Path $ConfigPath -ErrorAction SilentlyContinue
    if (-not $src) {
        Write-Host "󰅙  File not found: $ConfigPath" -ForegroundColor Red
        return
    }

    $dest = "$configsDir\$Name.conf"
    _PrintHeader "󰄬" "Add VPN Profile"
    Copy-Item $src.Path $dest -Force
    Write-Host "󰄬  Added profile '$Name'" -ForegroundColor Green
    Write-Host "   Path: $dest" -ForegroundColor DarkGray
    _PrintFooter
}

function _VpnRemove {
    $active = _GetActiveTunnel
    if ($active) {
        Write-Host "󰅙  '$active' is active. Run 'vpn off' first." -ForegroundColor Red
        return
    }

    $configs = _GetAllConfigs | Where-Object { -not $_.Builtin }

    if ($configs.Count -eq 0) {
        Write-Host "󰅙  No user-added profiles to remove." -ForegroundColor DarkGray
        return
    }

    $selected = ($configs | ForEach-Object { $_.Name }) |
        fzf --prompt="Remove profile > " --reverse --height=40%

    if (-not $selected) { Write-Host "󰅙  Cancelled." -ForegroundColor DarkGray; return }

    $target = "$configsDir\$selected.conf"
    if (Test-Path $target) {

        # ── Resolve the real (non-elevated) user's Documents folder ──────────
        # $env:USERPROFILE under gsudo still reflects the invoking user, but
        # if it ever resolves to Administrator we fall back to the registry.
        $realUserProfile = $env:USERPROFILE
        if ($realUserProfile -match '\\[Aa]dministrator$') {
            # Try to find the actual logged-on interactive user via WMI
            $interactiveUser = Get-CimInstance Win32_ComputerSystem |
                               Select-Object -ExpandProperty UserName
            if ($interactiveUser) {
                $interactiveUsername = $interactiveUser -replace '^.*\\', ''
                $candidate = "C:\Users\$interactiveUsername"
                if (Test-Path $candidate) { $realUserProfile = $candidate }
            }
        }
        $backupRoot = Join-Path $realUserProfile "Documents\vpn-configs-backup"
        # ─────────────────────────────────────────────────────────────────────

        if (-not (Test-Path $backupRoot)) {
            New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
        }

        $timestamp  = Get-Date -Format "yyyyMMdd_HHmmss"
        $backupFile = Join-Path $backupRoot "$selected`_$timestamp.conf"
        Copy-Item $target $backupFile -Force

        _PrintHeader "󰆴" "Remove VPN Profile"
        Remove-Item $target -Force
        Write-Host "󰆴  Removed profile '$selected'" -ForegroundColor Yellow
        Write-Host "   Backup saved to: $backupFile" -ForegroundColor DarkGray
        _PrintFooter
    } else {
        Write-Host "󰅙  Config file not found: $target" -ForegroundColor Red
    }
}

function _VpnStatus {
    $configs = _GetAllConfigs
    $runningSvcs = Get-Service -Name "WireGuardTunnel*" -ErrorAction SilentlyContinue |
                   Where-Object { $_.Status -eq "Running" } |
                   ForEach-Object { $_.Name -replace "WireGuardTunnel$", "" }

    _PrintHeader "󰖂" "VPN Status"

    if ($runningSvcs) {
        foreach ($svc in $runningSvcs) {
            Write-Host "│  󰤨  Connected: $svc" -ForegroundColor Green
        }
    } else {
        Write-Host "│  󰤭  No active tunnels" -ForegroundColor Gray
    }

    Write-Host "│" -ForegroundColor DarkBlue
    Write-Host "│  Registered profiles:" -ForegroundColor DarkGray

    foreach ($cfg in $configs) {
        $avail  = Test-Path $cfg.Path
        $bullet = if ($avail) { "󱁤" } else { "󰅙" }
        $color  = if ($avail) { "Blue" } else { "DarkRed" }
        $tag    = if ($cfg.Builtin) { " [warp]" } else { "" }
        $active_marker = if ($runningSvcs -contains $cfg.Name) { "  ← active" } else { "" }
        Write-Host ("│    {0}  {1}{2}{3}" -f $bullet, $cfg.Name, $tag, $active_marker) -ForegroundColor $color
    }

    _PrintFooter
}

# ─── Dispatch ─────────────────────────────────────────────────────────────────
switch ($Action) {
    "on"     { _VpnOn }
    "off"    { _VpnOff }
    "add"    { _VpnAdd }
    "remove" { _VpnRemove }
    "status" { _VpnStatus }
    default {
        _PrintHeader "󰖂" "VPN Manager"
        _PrintRow "󰤨" "on"     "Pick profile via fzf and connect"
        _PrintRow "󰤭" "off"    "Disconnect active tunnel"
        _PrintRow "󰄬" "add"    "Register a new WireGuard config"
        _PrintRow "󰅙" "remove" "Remove a registered profile"
        _PrintRow "󰖂" "status" "Show tunnel status + all profiles"
        _PrintFooter
        Write-Host "  Usage: vpn add <name> <path-to-conf>" -ForegroundColor DarkGray
        Write-Host ""
    }
}