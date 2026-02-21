# ==============================================================================
# 1. SELF-ELEVATION BLOCK (Request Admin Privileges)
# ==============================================================================
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Requesting Administrative privileges..." -ForegroundColor Yellow
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    Start-Process powershell.exe -ArgumentList $arguments -Verb RunAs
    exit
}

# ==============================================================================
# 2. MAIN SETUP (Running as Admin)
# ==============================================================================
Clear-Host
Write-Host "--- Starting Full Environment Setup (ADMIN) ---" -ForegroundColor Cyan

# A. Install Dependencies via Winget
$apps = @("Starship.Starship", "junegunn.fzf", "Git.Git", "ajeetdsouza.zoxide", "vim.vim", "Microsoft.PowerShell", "sharkdp.fd")

foreach ($app in $apps) {
    winget list --id $app --exact --source winget > $null 2>&1
    if (!$?) {
        Write-Host "Installing $app..." -ForegroundColor Yellow
        winget install --id $app --silent --accept-package-agreements --accept-source-agreements
    } else {
        Write-Host "$app is already installed." -ForegroundColor Green
    }
}

# B. Vim Configuration (Link _vimrc)
Write-Host "`nLinking Vim Configuration..." -ForegroundColor Cyan
$RepoVimrc = Join-Path $PSScriptRoot "_vimrc"
$HomeVimrc = Join-Path $HOME "_vimrc"

if (Test-Path $RepoVimrc) {
    if (Test-Path $HomeVimrc) { Remove-Item $HomeVimrc -Force }
    New-Item -ItemType SymbolicLink -Path $HomeVimrc -Value $RepoVimrc -Force
    Write-Host "Linked: $HomeVimrc" -ForegroundColor Green
}

# B.2 Vim Color Scheme (Nord)
Write-Host "`nInstalling Vim Color Scheme..." -ForegroundColor Cyan
$VimColorsDir = Join-Path $HOME "vimfiles\colors"
if (!(Test-Path $VimColorsDir)) { 
    New-Item -ItemType Directory -Path $VimColorsDir -Force | Out-Null 
}

$NordUrl = "https://raw.githubusercontent.com/nordtheme/vim/main/colors/nord.vim"
$NordPath = Join-Path $VimColorsDir "nord.vim"

try {
    Invoke-WebRequest -Uri $NordUrl -OutFile $NordPath
    Write-Host "Downloaded Nord theme to: $NordPath" -ForegroundColor Green
} catch {
    Write-Host "Failed to download Nord theme. Check your internet connection." -ForegroundColor Red
}

# C. Install Martian Mono Nerd Font
$fontName = "MartianMono"
$fontUrl = "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/$fontName.zip"
$tempZip = "$env:TEMP\fonts.zip"
$tempFolder = "$env:TEMP\MartianMonoFont"

if (!(Get-ChildItem "C:\Windows\Fonts" | Where-Object { $_.Name -like "*Martian*Nerd*" })) {
    Write-Host "Downloading and Installing Martian Mono Nerd Font..." -ForegroundColor Yellow
    Invoke-WebRequest -Uri $fontUrl -OutFile $tempZip
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
    Remove-Item $tempZip, $tempFolder -Recurse -ErrorAction SilentlyContinue
}

# D. PowerShell Profile Linking
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

# ==============================================================================
# 3. FINALIZATION
# ==============================================================================
Write-Host "`n--- SETUP COMPLETE ---" -ForegroundColor Magenta
Write-Host "Restart your Terminal for all changes (Environment Variables) to take effect." -ForegroundColor Yellow
Pause