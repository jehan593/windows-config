# ==============================================================================
# 1. SELF-ELEVATION BLOCK
# ==============================================================================
if (-not $PSScriptRoot)
{
    Write-Host "Run this as a script file, not dot-sourced." -ForegroundColor Red
    exit
}

$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
{
    Write-Host "Requesting Administrative privileges..." -ForegroundColor Yellow
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    Start-Process pwsh -ArgumentList $arguments -Verb RunAs
    exit
}

# ==============================================================================
# UI HELPERS
# ==============================================================================
function _PrintHeader
{
    param([string]$Title)
    Write-Host ""
    Write-Host "!!  $Title" -ForegroundColor Red
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkBlue
}

function _PrintFooter
{
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`n" -ForegroundColor DarkBlue
}

function _Ok
{ param([string]$Msg) Write-Host ("│  [OK]    {0}" -f $Msg) -ForegroundColor Green
}
function _Info
{ param([string]$Msg) Write-Host ("│  [INFO]  {0}" -f $Msg) -ForegroundColor Blue
}
function _Err
{ param([string]$Msg) Write-Host ("│  [ERR]   {0}" -f $Msg) -ForegroundColor Red
}

function _PassThru
{
    process
    { Write-Host "`e[38;2;118;138;161m│  $_`e[0m"
    }
}

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
if ($confirm -notmatch '^[Yy]$')
{ _Info "Aborted."; _PrintFooter; exit
}
_PrintFooter

# ==============================================================================
# 3. DOTFILES & CONFIG LINKING
# ==============================================================================
_PrintHeader "Removing PowerShell Profile Symlinks"
$Profiles = @(
    "$HOME\Documents\PowerShell\Microsoft.PowerShell_profile.ps1"
)
foreach ($Path in $Profiles)
{
    if (Test-Path $Path)
    {
        $item = Get-Item $Path -Force
        if ($item.LinkType -eq "SymbolicLink")
        {
            Remove-Item $Path -Force
            _Ok "Removed symlink: $Path"
        } else
        {
            _Info "Not a symlink, skipping: $Path"
        }
    } else
    {
        _Info "Not found, skipping: $Path"
    }
}
_PrintFooter

_PrintHeader "Removing Vim Configuration"
$HomeVimrc = Join-Path $HOME "_vimrc"
if (Test-Path $HomeVimrc)
{
    $item = Get-Item $HomeVimrc -Force
    if ($item.LinkType -eq "SymbolicLink")
    {
        Remove-Item $HomeVimrc -Force
        _Ok "Removed symlink: $HomeVimrc"
    } else
    {
        _Info "Not a symlink, skipping: $HomeVimrc"
    }
} else
{
    _Info "Not found, skipping: $HomeVimrc"
}

$NordPath = Join-Path $HOME "vimfiles\colors\nord.vim"
if (Test-Path $NordPath)
{
    Remove-Item $NordPath -Force
    _Ok "Removed Nord vim theme."
} else
{
    _Info "Nord vim theme not found, skipping."
}

$undoDir = Join-Path $HOME "vimfiles\undodir"
if (Test-Path $undoDir)
{
    Remove-Item $undoDir -Recurse -Force
    _Ok "Removed undo directory."
} else
{
    _Info "Undo directory not found, skipping."
}
_PrintFooter

_PrintHeader "Removing mpv Configuration"
$mpvConfigDir = "$env:APPDATA\mpv"
if (Test-Path $mpvConfigDir)
{
    $item = Get-Item $mpvConfigDir -Force
    if ($item.LinkType -eq "SymbolicLink")
    {
        Remove-Item $mpvConfigDir -Force
        _Ok "Removed symlink: $mpvConfigDir"
    } else
    {
        _Info "Not a symlink, skipping: $mpvConfigDir"
    }
} else
{
    _Info "Not found, skipping."
}
_PrintFooter

_PrintHeader "Removing Brave Policies"
$regPath = "HKLM:\SOFTWARE\Policies\BraveSoftware\Brave"
if (Test-Path $regPath)
{
    Remove-Item $regPath -Recurse -Force
    _Ok "Removed Brave policies from registry."
} else
{
    _Info "Not found, skipping."
}
_PrintFooter

_PrintHeader "Removing JpegView Configuration"
$jpegviewDst = "$env:APPDATA\JPEGView\JPEGView.ini"
if (Test-Path $jpegviewDst)
{
    $item = Get-Item $jpegviewDst -Force
    if ($item.LinkType -eq "SymbolicLink")
    {
        Remove-Item $jpegviewDst -Force
        _Ok "Removed symlink: $jpegviewDst"
    } else
    {
        _Info "Not a symlink, skipping."
    }
} else
{
    _Info "Not found, skipping."
}
_PrintFooter

# ==============================================================================
# 4. ASSETS & THEMING
# ==============================================================================
_PrintHeader "Removing Windows Terminal Nord Theme"
$wtFragmentPath = "$Env:LocalAppData\Microsoft\Windows Terminal\Fragments\nord"
if (Test-Path $wtFragmentPath)
{
    Remove-Item $wtFragmentPath -Recurse -Force
    _Ok "Removed Nord theme fragment."
} else
{
    _Info "Not found, skipping."
}
_PrintFooter

_PrintHeader "Removing Wallpapers"
$wallpaperDst = Join-Path ([Environment]::GetFolderPath("MyPictures")) "config-wallpapers"
if (Test-Path $wallpaperDst)
{
    $removeWallpapers = Read-Host "│  Remove wallpapers folder? (y/N)"
    if ($removeWallpapers -match '^[Yy]$')
    {
        Remove-Item $wallpaperDst -Recurse -Force
        _Ok "Removed wallpapers."
    } else
    {
        _Info "Skipping wallpapers removal."
    }
} else
{
    _Info "Not found, skipping."
}
_PrintFooter

# ==============================================================================
# 5. TOOLS & SCRIPTS
# ==============================================================================
_PrintHeader "Removing wg-socks"
$services = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*-wgsocks" }
$configScriptsDir = "$env:USERPROFILE\windows-config-scripts"
$removedTunnels = $false
if ($services)
{
    $stopTunnels = Read-Host "│  Remove existing tunnels and backup configs? (y/N)"
    if ($stopTunnels -match '^[Yy]$')
    {
        $removedTunnels = $true
        $wgsocksConf = "$configScriptsDir\wg-socks\configs"
        if (Test-Path $wgsocksConf)
        {
            $backupDir = Join-Path ([Environment]::GetFolderPath("Desktop")) "wg-socks-backup"
            if (!(Test-Path $backupDir))
            { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
            }
            Copy-Item -Path "$wgsocksConf\*.conf" -Destination $backupDir -Force
            _Ok "Configs backed up to: $backupDir"
        }
        foreach ($svc in $services)
        {
            servy-cli stop --name="$($svc.Name)" --quiet 2>&1 | _PassThru
            servy-cli uninstall --name="$($svc.Name)" --quiet 2>&1 | _PassThru
            _Ok "Removed service: $($svc.Name)"
        }
        if (Test-Path $configScriptsDir)
        {
            Remove-Item $configScriptsDir -Recurse -Force
            _Ok "Removed: $configScriptsDir"
        }
    } else
    {
        _Info "Skipping tunnel removal."
        Get-ChildItem $configScriptsDir -Exclude "wg-socks" | Remove-Item -Recurse -Force
        _Ok "Removed all except wg-socks."
    }
} else
{
    if (Test-Path $configScriptsDir)
    {
        Remove-Item $configScriptsDir -Recurse -Force
        _Ok "Removed: $configScriptsDir"
    } else
    {
        _Info "Not found, skipping."
    }
}
_PrintFooter

_PrintHeader "Removing Init Caches"
@("$env:TEMP\starship_init.ps1", "$env:TEMP\zoxide_init.ps1", "$env:TEMP\winget_search_cache.txt") | ForEach-Object {
    if (Test-Path $_)
    {
        Remove-Item $_ -Force
        _Ok "Removed: $_"
    } else
    {
        _Info "Not found, skipping: $_"
    }
}
_PrintFooter

_PrintHeader "Removing WARP Tunnel"
$svc = Get-Service -Name "WireGuardTunnel`$warp" -ErrorAction SilentlyContinue
if ($svc)
{
    wireguard /uninstalltunnelservice warp 2>&1 | _PassThru
    _Ok "Tunnel removed."
} else
{
    _Info "Tunnel not running, skipping."
}
_PrintFooter

# ==============================================================================
# 6. OPTIONAL - Uninstall Apps
# ==============================================================================
_PrintHeader "Optional: Package Removal"
_Info "Targets: Starship, fzf, Git, zoxide, vim, pwsh, bat, fd, WireGuard, wgcf, mpv$(if ($removedTunnels) { ', Servy' })"
Write-Host "│"
$response = Read-Host "│  Remove these packages? (y/N)"

if ($response -match '^[Yy]$')
{
    $apps = @(
        "Starship.Starship", "junegunn.fzf", "Git.Git", "ajeetdsouza.zoxide",
        "vim.vim", "Microsoft.PowerShell", "sharkdp.bat", "sharkdp.fd",
        "WireGuard.WireGuard", "ViRb3.wgcf"
    )
    if ($removedTunnels)
    {
        $apps += "aelassas.Servy"
    } else
    {
        _Info "Skipping Servy uninstall (tunnels still active)."
    }
    foreach ($app in $apps)
    {
        winget uninstall --id $app --exact --silent 2>&1 | _PassThru
        _Ok "Uninstalled: $app"
    }
    if (Get-Command choco -ErrorAction SilentlyContinue)
    {
        choco uninstall mpv -y 2>&1 | _PassThru
        _Ok "Uninstalled: mpv"
    }
} else
{
    _Info "Skipping package removal."
}
_PrintFooter

# ==============================================================================
# 7. WINDOWS TERMINAL RESTORE
# ==============================================================================
_PrintHeader "Restoring Windows Terminal Configuration"
$wtSettingsPath = "$env:LocalAppData\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
$customGuid = "{a3e97d4f-2b1c-4e8a-9f0d-6c5b3a7e1d2f}"

if (Test-Path $wtSettingsPath)
{
    $settings = Get-Content $wtSettingsPath -Raw | ConvertFrom-Json

    # Remove custom profile from list
    $list = [System.Collections.Generic.List[object]]($settings.profiles.list ?? @())
    $before = $list.Count
    $list = [System.Collections.Generic.List[object]]($list | Where-Object { $_.guid -ne $customGuid })
    if ($list.Count -lt $before)
    {
        _Ok "Removed PowerShell 7 custom profile."
    } else
    {
        _Info "Custom profile not found, skipping removal."
    }
    $settings.profiles | Add-Member -NotePropertyName "list" -NotePropertyValue $list.ToArray() -Force

    # Restore default profile to Windows PowerShell
    $ps5Profile = $list | Where-Object { $_.name -like "*Windows PowerShell*" } | Select-Object -First 1
    if ($ps5Profile)
    {
        $settings | Add-Member -NotePropertyName "defaultProfile" -NotePropertyValue $ps5Profile.guid -Force
        _Ok "Default profile restored to Windows PowerShell."
    } else
    {
        # Fallback to well-known Windows PowerShell GUID
        $settings | Add-Member -NotePropertyName "defaultProfile" -NotePropertyValue "{61c54bbd-c2c6-5271-96e7-009a87ff44bf}" -Force
        _Ok "Default profile restored to Windows PowerShell (fallback GUID)."
    }

    $settings | ConvertTo-Json -Depth 20 | Set-Content $wtSettingsPath -Encoding UTF8
    _Ok "Windows Terminal settings saved."
} else
{
    _Info "Windows Terminal settings not found, skipping."
}
_PrintFooter

# ==============================================================================
# 8. FINALIZATION
# ==============================================================================
Write-Host ""
Write-Host "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓" -ForegroundColor Green
Write-Host "┃           Reset Complete!                  ┃" -ForegroundColor Green
Write-Host "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛" -ForegroundColor Green
Write-Host ""
Write-Host "  Set a different wallpaper manually if prevous one from config-wallpapers:" -ForegroundColor White
Write-Host ""
Pause
