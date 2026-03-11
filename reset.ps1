# ==============================================================================
# 1. SELF-ELEVATION BLOCK
# ==============================================================================
if (-not $PSScriptRoot) {
    Write-Host "Run this as a script file, not dot-sourced." -ForegroundColor Red
    exit
}

$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Requesting Administrative privileges..." -ForegroundColor Yellow
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    Start-Process pwsh -ArgumentList $arguments -Verb RunAs
    exit
}

# ==============================================================================
# UI HELPERS
# ==============================================================================
function _PrintHeader {
    param([string]$Title)
    Write-Host ""
    Write-Host "!!  $Title" -ForegroundColor Red
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkBlue
}

function _PrintFooter {
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`n" -ForegroundColor DarkBlue
}

function _Ok   { param([string]$Msg) Write-Host ("│  [OK]    {0}" -f $Msg) -ForegroundColor Green }
function _Info { param([string]$Msg) Write-Host ("│  [INFO]  {0}" -f $Msg) -ForegroundColor Blue }
function _Err  { param([string]$Msg) Write-Host ("│  [ERR]   {0}" -f $Msg) -ForegroundColor Red }

# ==============================================================================
# 2. PRE-FLIGHT
# ==============================================================================
Clear-Host
Write-Host ""
Write-Host "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓" -ForegroundColor Red
Write-Host "┃         Windows Config Reset               ┃" -ForegroundColor Red
Write-Host "┃    This will UNDO everything setup did!    ┃" -ForegroundColor Yellow
Write-Host "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛" -ForegroundColor Red

_PrintHeader "Pre-flight"
$confirm = Read-Host "│  [WARN]  Are you sure you want to reset? (y/N)"
if ($confirm -notmatch '^[Yy]$') { _Info "Aborted."; _PrintFooter; exit }
_PrintFooter

# ==============================================================================
# 3. DOTFILES & CONFIG LINKING
# ==============================================================================
_PrintHeader "Removing PowerShell Profile Symlinks"
$Profiles = @(
    "$HOME\Documents\PowerShell\Microsoft.PowerShell_profile.ps1"
)
foreach ($Path in $Profiles) {
    if (Test-Path $Path) {
        $item = Get-Item $Path -Force
        if ($item.LinkType -eq "SymbolicLink") {
            Remove-Item $Path -Force
            _Ok "Removed symlink: $Path"
        } else {
            _Info "Not a symlink, skipping: $Path"
        }
    } else {
        _Info "Not found, skipping: $Path"
    }
}
_PrintFooter

_PrintHeader "Removing Vim Configuration"
$HomeVimrc = Join-Path $HOME "_vimrc"
if (Test-Path $HomeVimrc) {
    $item = Get-Item $HomeVimrc -Force
    if ($item.LinkType -eq "SymbolicLink") {
        Remove-Item $HomeVimrc -Force
        _Ok "Removed symlink: $HomeVimrc"
    } else {
        _Info "Not a symlink, skipping: $HomeVimrc"
    }
} else {
    _Info "Not found, skipping: $HomeVimrc"
}

$NordPath = Join-Path $HOME "vimfiles\colors\nord.vim"
if (Test-Path $NordPath) {
    Remove-Item $NordPath -Force
    _Ok "Removed Nord vim theme."
} else {
    _Info "Nord vim theme not found, skipping."
}

$undoDir = Join-Path $HOME "vimfiles\undodir"
if (Test-Path $undoDir) {
    Remove-Item $undoDir -Recurse -Force
    _Ok "Removed undo directory."
} else {
    _Info "Undo directory not found, skipping."
}
_PrintFooter

_PrintHeader "Removing mpv Configuration"
$mpvConfigDir = "$env:APPDATA\mpv"
if (Test-Path $mpvConfigDir) {
    $item = Get-Item $mpvConfigDir -Force
    if ($item.LinkType -eq "SymbolicLink") {
        Remove-Item $mpvConfigDir -Force
        _Ok "Removed symlink: $mpvConfigDir"
    } else {
        _Info "Not a symlink, skipping: $mpvConfigDir"
    }
} else {
    _Info "Not found, skipping."
}
_PrintFooter

_PrintHeader "Removing Brave Policies"
$regPath = "HKLM:\SOFTWARE\Policies\BraveSoftware\Brave"
if (Test-Path $regPath) {
    Remove-Item $regPath -Recurse -Force
    _Ok "Removed Brave policies from registry."
} else {
    _Info "Not found, skipping."
}
_PrintFooter

# ==============================================================================
# 4. ASSETS & THEMING
# ==============================================================================
_PrintHeader "Removing Windows Terminal Nord Theme"
$wtFragmentPath = "$Env:LocalAppData\Microsoft\Windows Terminal\Fragments\nord"
if (Test-Path $wtFragmentPath) {
    Remove-Item $wtFragmentPath -Recurse -Force
    _Ok "Removed Nord theme fragment."
} else {
    _Info "Not found, skipping."
}
_PrintFooter

_PrintHeader "Removing Wallpapers"
$wallpaperDst = Join-Path ([Environment]::GetFolderPath("MyPictures")) "config-wallpapers"
if (Test-Path $wallpaperDst) {
    $removeWallpapers = Read-Host "│  Remove wallpapers folder? (y/N)"
    if ($removeWallpapers -match '^[Yy]$') {
        Remove-Item $wallpaperDst -Recurse -Force
        _Ok "Removed wallpapers."
    } else {
        _Info "Skipping wallpapers removal."
    }
} else {
    _Info "Not found, skipping."
}
_PrintFooter

# ==============================================================================
# 5. TOOLS & SCRIPTS
# ==============================================================================
_PrintHeader "Removing wg-socks"
$services = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*-wgsocks" }
$configScriptsDir = "$env:USERPROFILE\windows-config-scripts"

if ($services) {
    $stopTunnels = Read-Host "│  Remove existing tunnels and backup configs? (y/N)"
    if ($stopTunnels -match '^[Yy]$') {
        $wgsocksConf = "$configScriptsDir\wg-socks\configs"
        if (Test-Path $wgsocksConf) {
            $backupDir = Join-Path ([Environment]::GetFolderPath("Desktop")) "wg-socks-backup"
            if (!(Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
            Copy-Item -Path "$wgsocksConf\*.conf" -Destination $backupDir -Force
            _Ok "Configs backed up to: $backupDir"
        }
        foreach ($svc in $services) {
            nssm stop $svc.Name 2>&1 | Out-Null
            nssm remove $svc.Name confirm 2>&1 | Out-Null
            _Ok "Removed service: $($svc.Name)"
        }
        if (Test-Path $configScriptsDir) {
            Remove-Item $configScriptsDir -Recurse -Force
            _Ok "Removed: $configScriptsDir"
        }
    } else {
        _Info "Skipping tunnel removal."
        Get-ChildItem $configScriptsDir -Exclude "wg-socks" | Remove-Item -Recurse -Force
        _Ok "Removed all except wg-socks."
    }
} else {
    if (Test-Path $configScriptsDir) {
        Remove-Item $configScriptsDir -Recurse -Force
        _Ok "Removed: $configScriptsDir"
    } else {
        _Info "Not found, skipping."
    }
}
_PrintFooter

_PrintHeader "Removing Init Caches"
@("$env:TEMP\starship_init.ps1", "$env:TEMP\zoxide_init.ps1", "$env:TEMP\winget_search_cache.txt") | ForEach-Object {
    if (Test-Path $_) {
        Remove-Item $_ -Force
        _Ok "Removed: $_"
    } else {
        _Info "Not found, skipping: $_"
    }
}
_PrintFooter

_PrintHeader "Removing WARP Tunnel"
$svc = Get-Service -Name "WireGuardTunnel`$warp" -ErrorAction SilentlyContinue
if ($svc) {
    wireguard /uninstalltunnelservice warp
    _Ok "Tunnel removed."
} else {
    _Info "Tunnel not running, skipping."
}
_PrintFooter

# ==============================================================================
# 6. OPTIONAL - Uninstall Apps
# ==============================================================================
_PrintHeader "Optional: Package Removal"
_Info "Targets: Starship, fzf, Git, zoxide, vim, pwsh, fd, NSSM, WireGuard, wgcf, mpv"
Write-Host "│"
$response = Read-Host "│  Remove these packages? (y/N)"

if ($response -match '^[Yy]$') {
    $apps = @(
        "Starship.Starship", "junegunn.fzf", "Git.Git", "ajeetdsouza.zoxide",
        "vim.vim", "Microsoft.PowerShell", "sharkdp.fd", "NSSM.NSSM",
        "WireGuard.WireGuard", "ViRb3.wgcf"
    )
    foreach ($app in $apps) {
        winget uninstall --id $app --exact --silent 2>&1 | Out-Null
        _Ok "Uninstalled: $app"
    }
    if (Get-Command choco -ErrorAction SilentlyContinue) {
        choco uninstall mpv -y | Out-Null
        _Ok "Uninstalled: mpv"
    }
} else {
    _Info "Skipping package removal."
}
_PrintFooter

# ==============================================================================
# 7. WINDOWS TERMINAL RESTORE
# ==============================================================================
_PrintHeader "Restoring Windows Terminal Configuration"
$wtSettingsPath = "$env:LocalAppData\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"

if (Test-Path $wtSettingsPath) {
    $settings = Get-Content $wtSettingsPath -Raw | ConvertFrom-Json

    $ps5Profile = $settings.profiles.list | Where-Object { $_.name -like "*Windows PowerShell*" } | Select-Object -First 1
    if ($ps5Profile) {
        $settings.defaultProfile = $ps5Profile.guid
        _Ok "Default profile restored to Windows PowerShell."
    } else {
        _Info "Windows PowerShell profile not found, skipping."
    }

    if (-not $settings.profiles.defaults) {
        $settings.profiles | Add-Member -NotePropertyName "defaults" -NotePropertyValue ([PSCustomObject]@{}) -Force
    }

    $settings.profiles.defaults | Add-Member -NotePropertyName "font" -NotePropertyValue ([PSCustomObject]@{
        face = "Cascadia Mono"
        size = 12
    }) -Force
    $settings.profiles.defaults | Add-Member -NotePropertyName "colorScheme" -NotePropertyValue "Campbell" -Force

    _Ok "Font restored to Cascadia Mono size 12."
    _Ok "Color scheme restored to Campbell."

    $settings | ConvertTo-Json -Depth 20 | Set-Content $wtSettingsPath -Encoding UTF8
    _Ok "Windows Terminal settings saved."
} else {
    _Info "Windows Terminal settings not found, skipping."
}
_PrintFooter

# ==============================================================================
# 8. FINALIZATION
# ==============================================================================
Write-Host ""
Write-Host "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓" -ForegroundColor Green
Write-Host "┃           Reset Complete!                   ┃" -ForegroundColor Green
Write-Host "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛" -ForegroundColor Green
Write-Host ""
Write-Host "  Set a different wallpaper manually if prevous one from config-wallpapers:" -ForegroundColor White
Write-Host ""
Pause