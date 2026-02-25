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
    $exe = if ($PSEdition -eq "Core") { "pwsh" } else { "powershell.exe" }
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    Start-Process $exe -ArgumentList $arguments -Verb RunAs
    exit
}

# ==============================================================================
# 2. DOTFILES & CONFIG LINKING
# ==============================================================================
Clear-Host
Write-Host "--- Starting Unsetup ---" -ForegroundColor Cyan

# A. PowerShell Profile Symlinks
Write-Host "`nRemoving PowerShell Profile Symlinks..." -ForegroundColor Yellow
$Profiles = @(
    "$HOME\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1",
    "$HOME\Documents\PowerShell\Microsoft.PowerShell_profile.ps1"
)
foreach ($Path in $Profiles) {
    if (Test-Path $Path) {
        $item = Get-Item $Path -Force
        if ($item.LinkType -eq "SymbolicLink") {
            Remove-Item $Path -Force
            Write-Host "Removed symlink: $Path" -ForegroundColor Green
        } else {
            Write-Host "Skipping (not a symlink): $Path" -ForegroundColor Gray
        }
    } else {
        Write-Host "Not found, skipping: $Path" -ForegroundColor Gray
    }
}

# B. Vim
Write-Host "`nRemoving Vim Configuration..." -ForegroundColor Yellow
$HomeVimrc = Join-Path $HOME "_vimrc"
if (Test-Path $HomeVimrc) {
    $item = Get-Item $HomeVimrc -Force
    if ($item.LinkType -eq "SymbolicLink") {
        Remove-Item $HomeVimrc -Force
        Write-Host "Removed symlink: $HomeVimrc" -ForegroundColor Green
    } else {
        Write-Host "Skipping (not a symlink): $HomeVimrc" -ForegroundColor Gray
    }
} else {
    Write-Host "Not found, skipping: $HomeVimrc" -ForegroundColor Gray
}

$NordPath = Join-Path $HOME "vimfiles\colors\nord.vim"
if (Test-Path $NordPath) {
    Remove-Item $NordPath -Force
    Write-Host "Removed: $NordPath" -ForegroundColor Green
} else {
    Write-Host "Not found, skipping." -ForegroundColor Gray
}

$undoDir = Join-Path $HOME "vimfiles\undodir"
if (Test-Path $undoDir) {
    Remove-Item $undoDir -Recurse -Force
    Write-Host "Removed: $undoDir" -ForegroundColor Green
} else {
    Write-Host "Not found, skipping." -ForegroundColor Gray
}

# C. mpv
Write-Host "`nRemoving mpv Configuration..." -ForegroundColor Yellow
$mpvConfigDir = "$env:APPDATA\mpv"
if (Test-Path $mpvConfigDir) {
    $item = Get-Item $mpvConfigDir -Force
    if ($item.LinkType -eq "SymbolicLink") {
        Remove-Item $mpvConfigDir -Force
        Write-Host "Removed symlink: $mpvConfigDir" -ForegroundColor Green
    } else {
        Write-Host "Skipping (not a symlink): $mpvConfigDir" -ForegroundColor Gray
    }
} else {
    Write-Host "Not found, skipping." -ForegroundColor Gray
}

# D. Brave Policies
Write-Host "`nRemoving Brave Policies..." -ForegroundColor Yellow
$regPath = "HKLM:\SOFTWARE\Policies\BraveSoftware\Brave"
if (Test-Path $regPath) {
    Remove-Item $regPath -Recurse -Force
    Write-Host "Removed Brave policies from registry." -ForegroundColor Green
} else {
    Write-Host "Not found, skipping." -ForegroundColor Gray
}

# ==============================================================================
# 3. ASSETS & THEMING
# ==============================================================================

# D. Windows Terminal Nord Theme
Write-Host "`nRemoving Windows Terminal Nord Theme..." -ForegroundColor Yellow
$wtFragmentPath = "$Env:LocalAppData\Microsoft\Windows Terminal\Fragments\nord"
if (Test-Path $wtFragmentPath) {
    Remove-Item $wtFragmentPath -Recurse -Force
    Write-Host "Removed: $wtFragmentPath" -ForegroundColor Green
} else {
    Write-Host "Not found, skipping." -ForegroundColor Gray
}

# E. Wallpapers
Write-Host "`nRemoving Wallpapers..." -ForegroundColor Yellow
$wallpaperDst = Join-Path ([Environment]::GetFolderPath("MyPictures")) "Wallpapers"
if (Test-Path $wallpaperDst) {
    Remove-Item $wallpaperDst -Recurse -Force
    Write-Host "Removed: $wallpaperDst" -ForegroundColor Green
} else {
    Write-Host "Not found, skipping." -ForegroundColor Gray
}

# ==============================================================================
# 4. TOOLS & SCRIPTS
# ==============================================================================

# F. wg-socks
Write-Host "`nRemoving wg-socks..." -ForegroundColor Yellow

$wgsocksConf = "$env:USERPROFILE\windows-config-scripts\wg-socks\configs"
if (Test-Path $wgsocksConf) {
    $backupDir = Join-Path ([Environment]::GetFolderPath("Desktop")) "wg-socks-backup"
    Write-Host "Backing up WireGuard configs to: $backupDir" -ForegroundColor Cyan
    if (!(Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
    Copy-Item -Path "$wgsocksConf\*.conf" -Destination $backupDir -Force
    Write-Host "Configs backed up." -ForegroundColor Green
} else {
    Write-Host "No WireGuard configs found to backup." -ForegroundColor Gray
}

$services = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*-wgsocks" }
foreach ($svc in $services) {
    Write-Host "  Removing service: $($svc.Name)" -ForegroundColor Gray
    nssm stop $svc.Name 2>&1 | Out-Null
    nssm remove $svc.Name confirm 2>&1 | Out-Null
}

$configScriptsDir = "$env:USERPROFILE\windows-config-scripts"
if (Test-Path $configScriptsDir) {
    Remove-Item $configScriptsDir -Recurse -Force
    Write-Host "Removed: $configScriptsDir" -ForegroundColor Green
} else {
    Write-Host "Not found, skipping." -ForegroundColor Gray
}

# G. Init Caches
Write-Host "`nRemoving Init Caches..." -ForegroundColor Yellow
@("$env:TEMP\starship_init.ps1", "$env:TEMP\zoxide_init.ps1") | ForEach-Object {
    if (Test-Path $_) {
        Remove-Item $_ -Force
        Write-Host "Removed: $_" -ForegroundColor Green
    } else {
        Write-Host "Not found, skipping: $_" -ForegroundColor Gray
    }
}

# H. warp
Write-Host "`nRemoving warp..." -ForegroundColor Yellow
$svc = Get-Service -Name "WireGuardTunnel`$warp" -ErrorAction SilentlyContinue
if ($svc) {
    wireguard /uninstalltunnelservice warp
    Write-Host "Tunnel removed." -ForegroundColor Green
} else {
    Write-Host "Tunnel not running, skipping." -ForegroundColor Gray
}

# ==============================================================================
# 5. OPTIONAL - Uninstall Apps
# ==============================================================================
Write-Host "`nWould you like to uninstall apps installed by setup.ps1?" -ForegroundColor Cyan
Write-Host "  (Starship, fzf, Git, zoxide, vim, pwsh, fd, NSSM, mpv)" -ForegroundColor Gray
$response = Read-Host "Uninstall apps? (y/N)"

if ($response -eq 'y') {
    $apps = @("Starship.Starship", "junegunn.fzf", "Git.Git", "ajeetdsouza.zoxide", "vim.vim", "Microsoft.PowerShell", "sharkdp.fd", "NSSM.NSSM")
    foreach ($app in $apps) {
        Write-Host "Uninstalling $app..." -ForegroundColor Yellow
        winget uninstall --id $app --exact --silent 2>&1 | Out-Null
        Write-Host "Done." -ForegroundColor Green
    }

    if (Get-Command choco -ErrorAction SilentlyContinue) {
        Write-Host "Uninstalling mpv..." -ForegroundColor Yellow
        choco uninstall mpv -y
        Write-Host "Done." -ForegroundColor Green
    }
} else {
    Write-Host "Skipping app uninstall." -ForegroundColor Gray
}

# ==============================================================================
# 6. FINALIZATION
# ==============================================================================
Write-Host "`n--- Unsetup Complete ---" -ForegroundColor Magenta
Write-Host "`n NOTE: Change your Windows Terminal color scheme from Nord to a built-in one." -ForegroundColor Yellow
Write-Host "        Settings > Profiles > Color Scheme" -ForegroundColor Gray
Write-Host "`nRestart your Terminal for all changes to take effect." -ForegroundColor Yellow
Pause