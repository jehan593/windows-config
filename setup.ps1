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
# 2. PACKAGE MANAGERS & CORE TOOLS
# ==============================================================================
Clear-Host
Write-Host "--- Starting Full Environment Setup (ADMIN) ---" -ForegroundColor Cyan

# A. Chocolatey
Write-Host "`nInstalling Chocolatey..." -ForegroundColor Cyan
if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    Invoke-RestMethod https://community.chocolatey.org/install.ps1 | Invoke-Expression
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
    Write-Host "Chocolatey installed." -ForegroundColor Green
} else {
    Write-Host "Chocolatey already installed." -ForegroundColor Green
}

# B. Winget Apps
Write-Host "`nInstalling Dependencies via Winget..." -ForegroundColor Cyan
$apps = @("Starship.Starship", "junegunn.fzf", "Git.Git", "ajeetdsouza.zoxide", "vim.vim", "Microsoft.PowerShell", "sharkdp.fd", "NSSM.NSSM", "WireGuard.WireGuard", "ViRb3.wgcf")

foreach ($app in $apps) {
    $installed = winget list --id $app --exact --source winget 2>&1 | Out-String
    if ($installed -notmatch $app) {
        Write-Host "Installing $app..." -ForegroundColor Yellow
        winget install --id $app --silent --accept-package-agreements --accept-source-agreements
    } else {
        Write-Host "$app is already installed." -ForegroundColor Green
    }
}

# C. Chocolatey Apps
Write-Host "`nInstalling Chocolatey Apps..." -ForegroundColor Cyan
if (-not (Get-Command mpv -ErrorAction SilentlyContinue)) {
    choco install mpv -y
    Write-Host "mpv installed." -ForegroundColor Green
} else {
    Write-Host "mpv already installed." -ForegroundColor Green
}

# ==============================================================================
# 3. DOTFILES & CONFIG LINKING
# ==============================================================================

# D. PowerShell Profile
Write-Host "`nLinking PowerShell Profile..." -ForegroundColor Cyan
$RepoProfile = Join-Path $PSScriptRoot "profile\Microsoft.PowerShell_profile.ps1"
$Profiles = @(
    "$HOME\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1",
    "$HOME\Documents\PowerShell\Microsoft.PowerShell_profile.ps1"
)

foreach ($Path in $Profiles) {
    $Dir = Split-Path $Path
    if (!(Test-Path $Dir)) { New-Item -ItemType Directory -Path $Dir -Force }
    if (Test-Path $Path) {
        $existing = Get-Item $Path -Force
        if ($existing.LinkType -eq "SymbolicLink" -and $existing.Target -eq $RepoProfile) {
            Write-Host "Already linked: $Path" -ForegroundColor Gray
            continue
        }
        Remove-Item $Path -Force
    }
    New-Item -ItemType SymbolicLink -Path $Path -Value $RepoProfile -Force
    Write-Host "Linked: $Path" -ForegroundColor Green
}

# E. Vim
Write-Host "`nLinking Vim Configuration..." -ForegroundColor Cyan
$RepoVimrc = Join-Path $PSScriptRoot "configs\_vimrc"
$HomeVimrc = Join-Path $HOME "_vimrc"

if (Test-Path $RepoVimrc) {
    if (Test-Path $HomeVimrc) { Remove-Item $HomeVimrc -Force }
    New-Item -ItemType SymbolicLink -Path $HomeVimrc -Value $RepoVimrc -Force
    Write-Host "Linked: $HomeVimrc" -ForegroundColor Green
} 

Write-Host "`nInstalling Vim Nord Color Scheme..." -ForegroundColor Cyan
$VimColorsDir = Join-Path $HOME "vimfiles\colors"
if (!(Test-Path $VimColorsDir)) { New-Item -ItemType Directory -Path $VimColorsDir -Force | Out-Null }

try {
    Invoke-WebRequest -Uri "https://raw.githubusercontent.com/nordtheme/vim/main/colors/nord.vim" -OutFile (Join-Path $VimColorsDir "nord.vim") -UseBasicParsing -ErrorAction Stop
    Write-Host "Nord theme downloaded." -ForegroundColor Green
} catch {
    Write-Host "Failed to download Nord theme: $_" -ForegroundColor Red
}

# F. mpv
Write-Host "`nLinking mpv Configuration..." -ForegroundColor Cyan
$mpvConfigDir = "$env:APPDATA\mpv"
$repoMpvDir = Join-Path $PSScriptRoot "configs\mpv"

if (Test-Path $mpvConfigDir) { Remove-Item $mpvConfigDir -Recurse -Force }
New-Item -ItemType SymbolicLink -Path $mpvConfigDir -Value $repoMpvDir -Force | Out-Null
Write-Host "Linked: $mpvConfigDir" -ForegroundColor Green

# G. Brave Policies
Write-Host "`nApplying Brave Policies..." -ForegroundColor Cyan
$bravePolicySrc = Join-Path $PSScriptRoot "configs\brave\policies.json"

if (Test-Path $bravePolicySrc) {
    $policies = Get-Content $bravePolicySrc | ConvertFrom-Json
    $regPath = "HKLM:\SOFTWARE\Policies\BraveSoftware\Brave"
    if (!(Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
    foreach ($key in $policies.PSObject.Properties) {
        New-ItemProperty -Path $regPath -Name $key.Name -Value $key.Value -PropertyType DWORD -Force | Out-Null
    }
    Write-Host "Brave policies applied via registry." -ForegroundColor Green
}

# ==============================================================================
# 4. ASSETS & THEMING
# ==============================================================================

# G. Martian Mono Nerd Font
Write-Host "`nInstalling Martian Mono Nerd Font..." -ForegroundColor Cyan
if (!(Get-ChildItem "C:\Windows\Fonts" | Where-Object { $_.Name -like "*Martian*Nerd*" })) {
    $tempZip = "$env:TEMP\fonts.zip"
    $tempFolder = "$env:TEMP\MartianMonoFont"
    try {
        Invoke-WebRequest -Uri "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/MartianMono.zip" -OutFile $tempZip -UseBasicParsing -ErrorAction Stop
        if (!(Test-Path $tempFolder)) { New-Item -ItemType Directory -Path $tempFolder }
        Expand-Archive -Path $tempZip -DestinationPath $tempFolder -Force

        foreach ($file in (Get-ChildItem -Path $tempFolder -Include "*.ttf", "*.otf" -Recurse)) {
            $targetPath = Join-Path "C:\Windows\Fonts" $file.Name
            try {
                if (!(Test-Path $targetPath)) {
                    Copy-Item $file.FullName $targetPath -Force
                    New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts" -Name $file.Name -Value $file.Name -PropertyType String -Force | Out-Null
                }
            } catch { Write-Host "Could not install $($file.Name)" -ForegroundColor Gray }
        }
        Write-Host "Martian Mono Nerd Font installed." -ForegroundColor Green
    } catch {
        Write-Host "Failed to download/install font: $_" -ForegroundColor Red
    } finally {
        Remove-Item $tempZip, $tempFolder -Recurse -ErrorAction SilentlyContinue
    }
} else {
    Write-Host "Martian Mono Nerd Font already installed." -ForegroundColor Green
}

# H. Windows Terminal Nord Theme
Write-Host "`nInstalling Windows Terminal Nord Theme..." -ForegroundColor Cyan
$nordJson = Join-Path $PSScriptRoot "assets\nord.json"

if (Test-Path $nordJson) {
    $wtFragmentPath = "$Env:LocalAppData\Microsoft\Windows Terminal\Fragments\nord"
    if (!(Test-Path $wtFragmentPath)) { New-Item -ItemType Directory -Path $wtFragmentPath -Force | Out-Null }
    Copy-Item -Path $nordJson -Destination $wtFragmentPath -Force
    Write-Host "Nord theme installed. Restart Windows Terminal and select it in your profile." -ForegroundColor Green
}

# I. Wallpapers
Write-Host "`nCopying Wallpapers..." -ForegroundColor Cyan
$wallpaperSrc = Join-Path $PSScriptRoot "assets\wallpaper.jpg"
$wallpaperDst = Join-Path ([Environment]::GetFolderPath("MyPictures")) "Wallpapers"

if (Test-Path $wallpaperSrc) {
    if (!(Test-Path $wallpaperDst)) { New-Item -ItemType Directory -Path $wallpaperDst -Force | Out-Null }
    Copy-Item -Path $wallpaperSrc -Destination $wallpaperDst -Force
    Write-Host "Wallpaper copied to: $wallpaperDst" -ForegroundColor Green
}

# ==============================================================================
# 5. TOOLS & SCRIPTS
# ==============================================================================

# J. wg-socks
Write-Host "`nSetting up wg-socks..." -ForegroundColor Cyan
$configScriptsDir = "$env:USERPROFILE\windows-config-scripts"
$wgsocksDir = "$configScriptsDir\wg-socks"
$wgsocksConf = "$wgsocksDir\configs"
$wireproxyExe = "$wgsocksDir\wireproxy.exe"

if (!(Test-Path $configScriptsDir)) { New-Item -ItemType Directory -Path $configScriptsDir -Force | Out-Null }
if (!(Test-Path $wgsocksDir)) { New-Item -ItemType Directory -Path $wgsocksDir -Force | Out-Null }
if (!(Test-Path $wgsocksConf)) { New-Item -ItemType Directory -Path $wgsocksConf -Force | Out-Null }
Write-Host "Folder structure created." -ForegroundColor Green

if (-not (Test-Path $wireproxyExe)) {
    $tempFile = "$env:TEMP\wireproxy.tar.gz"
    $tempFolder = "$env:TEMP\wireproxy"
    try {
        Invoke-WebRequest -Uri "https://github.com/whyvl/wireproxy/releases/download/v1.0.9/wireproxy_windows_amd64.tar.gz" -OutFile $tempFile -UseBasicParsing -ErrorAction Stop
        if (!(Test-Path $tempFolder)) { New-Item -ItemType Directory -Path $tempFolder -Force | Out-Null }
        tar -xzf $tempFile -C $tempFolder
        $innerArchive = Get-ChildItem -Path $tempFolder -Recurse | Where-Object { $_.Extension -match "\.gz|\.tar" } | Select-Object -First 1
        if ($innerArchive) { tar -xzf $innerArchive.FullName -C $tempFolder }
        $wireproxyBin = Get-ChildItem -Path $tempFolder -Recurse -Filter "wireproxy.exe" | Select-Object -First 1
        if ($wireproxyBin) {
            Copy-Item $wireproxyBin.FullName $wireproxyExe -Force
            Write-Host "wireproxy installed." -ForegroundColor Green
        } else {
            Write-Host "Could not find wireproxy.exe after extraction." -ForegroundColor Red
        }
    } catch {
        Write-Host "Failed to install wireproxy: $_" -ForegroundColor Red
    } finally {
        Remove-Item $tempFile, $tempFolder -Recurse -ErrorAction SilentlyContinue
    }
} else {
    Write-Host "wireproxy already installed." -ForegroundColor Green
}

# ==============================================================================
# 6. FINALIZATION
# ==============================================================================
Write-Host "`n--- SETUP COMPLETE ---" -ForegroundColor Magenta
Write-Host "Restart your Terminal for all changes to take effect." -ForegroundColor Yellow
Pause