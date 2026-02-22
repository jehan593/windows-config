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
# 2. MAIN SETUP (Running as Admin)
# ==============================================================================
Clear-Host
Write-Host "--- Starting Full Environment Setup (ADMIN) ---" -ForegroundColor Cyan

# A. Install Chocolatey
Write-Host "Installing Chocolatey..." -ForegroundColor Cyan
if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    Invoke-RestMethod https://community.chocolatey.org/install.ps1 | Invoke-Expression
    Write-Host "Chocolatey installed." -ForegroundColor Green
} else {
    Write-Host "Chocolatey already installed." -ForegroundColor Green
}

# B. Install mpv via Chocolatey
Write-Host "`nInstalling mpv..." -ForegroundColor Cyan
if (-not (Get-Command mpv -ErrorAction SilentlyContinue)) {
    choco install mpv -y
    Write-Host "mpv installed." -ForegroundColor Green
} else {
    Write-Host "mpv already installed." -ForegroundColor Green
}

# C. Install Dependencies via Winget
$apps = @("Starship.Starship", "junegunn.fzf", "Git.Git", "ajeetdsouza.zoxide", "vim.vim", "Microsoft.PowerShell", "sharkdp.fd")

foreach ($app in $apps) {
    $installed = winget list --id $app --exact --source winget 2>&1 | Out-String
    if ($installed -notmatch $app) {
        Write-Host "Installing $app..." -ForegroundColor Yellow
        winget install --id $app --silent --accept-package-agreements --accept-source-agreements
    } else {
        Write-Host "$app is already installed." -ForegroundColor Green
    }
}

# D. Vim Configuration (Link _vimrc)
Write-Host "`nLinking Vim Configuration..." -ForegroundColor Cyan
$RepoVimrc = Join-Path $PSScriptRoot "_vimrc"
$HomeVimrc = Join-Path $HOME "_vimrc"

if (Test-Path $RepoVimrc) {
    if (Test-Path $HomeVimrc) { Remove-Item $HomeVimrc -Force }
    New-Item -ItemType SymbolicLink -Path $HomeVimrc -Value $RepoVimrc -Force
    Write-Host "Linked: $HomeVimrc" -ForegroundColor Green
}

# D.2 Vim Color Scheme (Nord)
Write-Host "`nInstalling Vim Color Scheme..." -ForegroundColor Cyan
$VimColorsDir = Join-Path $HOME "vimfiles\colors"
if (!(Test-Path $VimColorsDir)) {
    New-Item -ItemType Directory -Path $VimColorsDir -Force | Out-Null
}

$NordUrl = "https://raw.githubusercontent.com/nordtheme/vim/main/colors/nord.vim"
$NordPath = Join-Path $VimColorsDir "nord.vim"

try {
    Invoke-WebRequest -Uri $NordUrl -OutFile $NordPath -UseBasicParsing -ErrorAction Stop
    Write-Host "Downloaded Nord theme to: $NordPath" -ForegroundColor Green
} catch {
    Write-Host "Failed to download Nord theme: $_" -ForegroundColor Red
}

# E. Install Martian Mono Nerd Font
$fontName = "MartianMono"
$fontUrl = "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/$fontName.zip"
$tempZip = "$env:TEMP\fonts.zip"
$tempFolder = "$env:TEMP\MartianMonoFont"

if (!(Get-ChildItem "C:\Windows\Fonts" | Where-Object { $_.Name -like "*Martian*Nerd*" })) {
    Write-Host "Downloading and Installing Martian Mono Nerd Font..." -ForegroundColor Yellow
    try {
        Invoke-WebRequest -Uri $fontUrl -OutFile $tempZip -UseBasicParsing -ErrorAction Stop
        if (!(Test-Path $tempFolder)) { New-Item -ItemType Directory -Path $tempFolder }
        Expand-Archive -Path $tempZip -DestinationPath $tempFolder -Force

        $fontFiles = Get-ChildItem -Path $tempFolder -Include "*.ttf", "*.otf" -Recurse
        foreach ($file in $fontFiles) {
            $targetPath = Join-Path "C:\Windows\Fonts" $file.Name
            try {
                if (!(Test-Path $targetPath)) {
                    Copy-Item $file.FullName $targetPath -Force
                    $registryPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts"
                    New-ItemProperty -Path $registryPath -Name $file.Name -Value $file.Name -PropertyType String -Force | Out-Null
                }
            } catch { Write-Host "Could not install $($file.Name)" -ForegroundColor Gray }
        }
    } catch {
        Write-Host "Failed to download/install font: $_" -ForegroundColor Red
    } finally {
        Remove-Item $tempZip, $tempFolder -Recurse -ErrorAction SilentlyContinue
    }
}

# F. PowerShell Profile Linking
Write-Host "`nLinking Profile Scripts..." -ForegroundColor Cyan
$RepoProfile = Join-Path $PSScriptRoot "Microsoft.PowerShell_profile.ps1"
$Profiles = @(
    "$HOME\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1",
    "$HOME\Documents\PowerShell\Microsoft.PowerShell_profile.ps1"
)

foreach ($Path in $Profiles) {
    $Dir = Split-Path $Path
    if (!(Test-Path $Dir)) { New-Item -ItemType Directory -Path $Dir -Force }
    if (Test-Path $Path) { Remove-Item $Path -Force }
    New-Item -ItemType SymbolicLink -Path $Path -Value $RepoProfile -Force
    Write-Host "Linked: $Path" -ForegroundColor Green
}

# G. Windows Terminal Nord Theme
Write-Host "`nInstalling Windows Terminal Nord Theme..." -ForegroundColor Cyan
$wtFragmentPath = "$Env:LocalAppData\Microsoft\Windows Terminal\Fragments\nord"
$nordJson = Join-Path $PSScriptRoot "files\nord.json"

if (-not (Test-Path $nordJson)) {
    Write-Host "nord.json not found in repo folder." -ForegroundColor Red
} else {
    if (!(Test-Path $wtFragmentPath)) {
        New-Item -ItemType Directory -Path $wtFragmentPath -Force | Out-Null
    }
    Copy-Item -Path $nordJson -Destination $wtFragmentPath -Force
    Write-Host "Nord theme installed. Restart Windows Terminal and select it in your profile." -ForegroundColor Green
}

# H. Wallpapers
Write-Host "`nCopying Wallpapers..." -ForegroundColor Cyan
$wallpaperSrc = Join-Path $PSScriptRoot "files\wallpaper.jpg"
$wallpaperDst = Join-Path ([Environment]::GetFolderPath("MyPictures")) "Wallpapers"

if (-not (Test-Path $wallpaperSrc)) {
    Write-Host "Wallpaper not found in repo." -ForegroundColor Red
} else {
    if (!(Test-Path $wallpaperDst)) {
        New-Item -ItemType Directory -Path $wallpaperDst -Force | Out-Null
    }
    Copy-Item -Path $wallpaperSrc -Destination $wallpaperDst -Force
    Write-Host "Wallpaper copied to: $wallpaperDst" -ForegroundColor Green
}



# ==============================================================================
# 3. FINALIZATION
# ==============================================================================
Write-Host "`n--- SETUP COMPLETE ---" -ForegroundColor Magenta
Write-Host "Restart your Terminal for all changes to take effect." -ForegroundColor Yellow
Pause