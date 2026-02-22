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
# 2. MAIN UNSETUP
# ==============================================================================
Clear-Host
Write-Host "--- Starting Unsetup ---" -ForegroundColor Cyan

# A. Remove PowerShell Profile Symlinks
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

# B. Remove Vim Symlink
Write-Host "`nRemoving Vim Configuration Symlink..." -ForegroundColor Yellow
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

# C. Remove Vim Color Scheme
Write-Host "`nRemoving Vim Nord Theme..." -ForegroundColor Yellow
$NordPath = Join-Path $HOME "vimfiles\colors\nord.vim"
if (Test-Path $NordPath) {
    Remove-Item $NordPath -Force
    Write-Host "Removed: $NordPath" -ForegroundColor Green
} else {
    Write-Host "Not found, skipping." -ForegroundColor Gray
}

# D. Remove Vim Undo Directory
Write-Host "`nRemoving Vim Undo Directory..." -ForegroundColor Yellow
$undoDir = Join-Path $HOME "vimfiles\undodir"
if (Test-Path $undoDir) {
    Remove-Item $undoDir -Recurse -Force
    Write-Host "Removed: $undoDir" -ForegroundColor Green
} else {
    Write-Host "Not found, skipping." -ForegroundColor Gray
}

# E. Remove Windows Terminal Nord Theme
Write-Host "`nRemoving Windows Terminal Nord Theme..." -ForegroundColor Yellow
$wtFragmentPath = "$Env:LocalAppData\Microsoft\Windows Terminal\Fragments\nord"
if (Test-Path $wtFragmentPath) {
    Remove-Item $wtFragmentPath -Recurse -Force
    Write-Host "Removed: $wtFragmentPath" -ForegroundColor Green
} else {
    Write-Host "Not found, skipping." -ForegroundColor Gray
}

# F. Remove Wallpapers
Write-Host "`nRemoving Wallpapers..." -ForegroundColor Yellow
$wallpaperDst = Join-Path ([Environment]::GetFolderPath("MyPictures")) "Wallpapers"
if (Test-Path $wallpaperDst) {
    Remove-Item $wallpaperDst -Recurse -Force
    Write-Host "Removed: $wallpaperDst" -ForegroundColor Green
} else {
    Write-Host "Not found, skipping." -ForegroundColor Gray
}

# G.0 Backup WireGuard Configs
$wireproxyConf = "C:\ProgramData\wireproxy"
if (Test-Path $wireproxyConf) {
    $backupDir = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "wireproxy-backup"
    Write-Host "`nBacking up WireGuard configs to: $backupDir" -ForegroundColor Cyan
    if (!(Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
    Copy-Item -Path "$wireproxyConf\*.conf" -Destination $backupDir -Force
    Write-Host "Configs backed up." -ForegroundColor Green
} else {
    Write-Host "`nNo WireGuard configs found to backup." -ForegroundColor Gray
}

# G. Remove wireproxy and wg-socks
Write-Host "`nRemoving wireproxy and wg-socks..." -ForegroundColor Yellow

# Stop and remove all wg-socks services first
$services = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*-wgsocks" }
foreach ($svc in $services) {
    Write-Host "  Removing service: $($svc.Name)" -ForegroundColor Gray
    nssm stop $svc.Name 2>&1 | Out-Null
    nssm remove $svc.Name confirm 2>&1 | Out-Null
}

# Remove wireproxy directory
$wireproxyDir = "C:\Program Files\wireproxy"
if (Test-Path $wireproxyDir) {
    Remove-Item $wireproxyDir -Recurse -Force
    Write-Host "Removed: $wireproxyDir" -ForegroundColor Green
} else {
    Write-Host "Not found, skipping." -ForegroundColor Gray
}

# Remove wireproxy config directory
$wireproxyConf = "C:\ProgramData\wireproxy"
if (Test-Path $wireproxyConf) {
    Remove-Item $wireproxyConf -Recurse -Force
    Write-Host "Removed: $wireproxyConf" -ForegroundColor Green
} else {
    Write-Host "Not found, skipping." -ForegroundColor Gray
}

# Remove wireproxy from PATH
$currentPath = [Environment]::GetEnvironmentVariable("PATH", "Machine")
if ($currentPath -like "*$wireproxyDir*") {
    $newPath = ($currentPath -split ';' | Where-Object { $_ -ne $wireproxyDir }) -join ';'
    [Environment]::SetEnvironmentVariable("PATH", $newPath, "Machine")
    Write-Host "Removed wireproxy from PATH." -ForegroundColor Green
}

# H. Remove Init Caches
Write-Host "`nRemoving Init Caches..." -ForegroundColor Yellow
@("$env:TEMP\starship_init.ps1", "$env:TEMP\zoxide_init.ps1") | ForEach-Object {
    if (Test-Path $_) {
        Remove-Item $_ -Force
        Write-Host "Removed: $_" -ForegroundColor Green
    } else {
        Write-Host "Not found, skipping: $_" -ForegroundColor Gray
    }
}

# ==============================================================================
# 3. OPTIONAL - Uninstall Apps
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

    # Uninstall mpv via Chocolatey
    if (Get-Command choco -ErrorAction SilentlyContinue) {
        Write-Host "Uninstalling mpv..." -ForegroundColor Yellow
        choco uninstall mpv -y
        Write-Host "Done." -ForegroundColor Green
    }
} else {
    Write-Host "Skipping app uninstall." -ForegroundColor Gray
}

# ==============================================================================
# 4. FINALIZATION
# ==============================================================================
Write-Host "`n--- Unsetup Complete ---" -ForegroundColor Magenta
Write-Host "Restart your Terminal for all changes to take effect." -ForegroundColor Yellow
Write-Host "NOTE: If your Windows Terminal profile uses the Nord color scheme," -ForegroundColor Yellow
Write-Host "      you will need to change it in Settings > Profiles > Color Scheme." -ForegroundColor Yellow
Pause