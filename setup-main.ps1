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
    Write-Host ">>  $Title" -ForegroundColor Cyan
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
Write-Host "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓" -ForegroundColor Cyan
Write-Host "┃        Windows Config Setup                ┃" -ForegroundColor Cyan
Write-Host "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛" -ForegroundColor Cyan

# ==============================================================================
# 3. PACKAGE MANAGERS & CORE TOOLS
# ==============================================================================
_PrintHeader "Windows Store & App Installer"
_Info "Updating Windows Store..."
winget install --id 9WZDNCRFJBMP --source msstore --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
_Ok "Windows Store updated."
_Info "Updating App Installer (winget)..."
winget install --id Microsoft.AppInstaller --source msstore --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
_Ok "App Installer updated."
_PrintFooter

_PrintHeader "Chocolatey"
if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    _Info "Installing Chocolatey..."
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    Invoke-RestMethod https://community.chocolatey.org/install.ps1 | Invoke-Expression
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
    _Ok "Chocolatey installed."
} else {
    _Ok "Chocolatey already installed."
}
_PrintFooter

_PrintHeader "Winget Apps"
$apps = @(
    "Starship.Starship", "junegunn.fzf", "Git.Git", "ajeetdsouza.zoxide",
    "vim.vim", "sharkdp.fd", "NSSM.NSSM",
    "WireGuard.WireGuard", "ViRb3.wgcf", "Microsoft.WindowsTerminal", "sylikc.JPEGView"
)
foreach ($app in $apps) {
    $installed = winget list --id $app --exact --source winget 2>&1 | Out-String
    if ($installed -notmatch $app) {
        _Info "Installing $app..."
        winget install --id $app --source winget --silent --accept-package-agreements --accept-source-agreements
        _Ok "$app installed."
    } else {
        _Ok "$app already installed."
    }
}
_PrintFooter

_PrintHeader "PowerShell Modules"
if (-not (Get-Module -ListAvailable -Name Microsoft.WinGet.Client)) {
    _Info "Installing Microsoft.WinGet.Client..."
    Install-Module -Name Microsoft.WinGet.Client -Force -Scope CurrentUser
    _Ok "Microsoft.WinGet.Client installed."
} else {
    _Ok "Microsoft.WinGet.Client already installed."
}
_PrintFooter

_PrintHeader "Chocolatey Apps"
if (-not (Get-Command mpv -ErrorAction SilentlyContinue)) {
    _Info "Installing mpv..."
    choco install mpv -y
    _Ok "mpv installed."
} else {
    _Ok "mpv already installed."
}
_PrintFooter

# ==============================================================================
# 4. DOTFILES & CONFIG LINKING
# ==============================================================================
_PrintHeader "PowerShell Profile"
$RepoProfile = Join-Path $PSScriptRoot "profile\Microsoft.PowerShell_profile.ps1"
$Profiles = @(
    "$HOME\Documents\PowerShell\Microsoft.PowerShell_profile.ps1"
)
foreach ($Path in $Profiles) {
    $Dir = Split-Path $Path
    if (!(Test-Path $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
    if (Test-Path $Path) {
        $existing = Get-Item $Path -Force
        if ($existing.LinkType -eq "SymbolicLink" -and $existing.Target -eq $RepoProfile) {
            _Info "Already linked: $Path"
            continue
        }
        Remove-Item $Path -Force
    }
    New-Item -ItemType SymbolicLink -Path $Path -Value $RepoProfile -Force | Out-Null
    _Ok "Linked: $Path"
}
_PrintFooter

_PrintHeader "Vim Configuration"
$RepoVimrc = Join-Path $PSScriptRoot "configs\_vimrc"
$HomeVimrc = Join-Path $HOME "_vimrc"
if (Test-Path $RepoVimrc) {
    if (Test-Path $HomeVimrc) { Remove-Item $HomeVimrc -Force }
    New-Item -ItemType SymbolicLink -Path $HomeVimrc -Value $RepoVimrc -Force | Out-Null
    _Ok "Linked: $HomeVimrc"
}

$VimColorsDir = Join-Path $HOME "vimfiles\colors"
if (!(Test-Path $VimColorsDir)) { New-Item -ItemType Directory -Path $VimColorsDir -Force | Out-Null }
try {
    Invoke-WebRequest -Uri "https://raw.githubusercontent.com/nordtheme/vim/main/colors/nord.vim" -OutFile (Join-Path $VimColorsDir "nord.vim") -UseBasicParsing -ErrorAction Stop
    _Ok "Nord vim theme downloaded."
} catch {
    _Err "Failed to download Nord theme: $_"
}
_PrintFooter

_PrintHeader "mpv Configuration"
$mpvConfigDir = "$env:APPDATA\mpv"
$repoMpvDir = Join-Path $PSScriptRoot "configs\mpv"
if (Test-Path $mpvConfigDir) { Remove-Item $mpvConfigDir -Recurse -Force }
New-Item -ItemType SymbolicLink -Path $mpvConfigDir -Value $repoMpvDir -Force | Out-Null
_Ok "Linked: $mpvConfigDir"
_PrintFooter

_PrintHeader "Brave Policies"
$bravePolicySrc = Join-Path $PSScriptRoot "configs\brave\policies.json"
if (Test-Path $bravePolicySrc) {
    $policies = Get-Content $bravePolicySrc | ConvertFrom-Json
    $regPath = "HKLM:\SOFTWARE\Policies\BraveSoftware\Brave"
    if (!(Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
    foreach ($key in $policies.PSObject.Properties) {
        New-ItemProperty -Path $regPath -Name $key.Name -Value $key.Value -PropertyType DWORD -Force | Out-Null
    }
    _Ok "Brave policies applied via registry."
}
_PrintFooter

_PrintHeader "JpegView Configuration"
$jpegviewSrc = Join-Path $PSScriptRoot "configs\jpegview\JPEGView.ini"
$jpegviewDst = "$env:APPDATA\JPEGView\JPEGView.ini"
$jpegviewDir = Split-Path $jpegviewDst

if (Test-Path $jpegviewSrc) {
    if (!(Test-Path $jpegviewDir)) { New-Item -ItemType Directory -Path $jpegviewDir -Force | Out-Null }
    if (Test-Path $jpegviewDst) { Remove-Item $jpegviewDst -Force }
    New-Item -ItemType SymbolicLink -Path $jpegviewDst -Value $jpegviewSrc -Force | Out-Null
    _Ok "Linked: $jpegviewDst"
} else {
    _Info "JPEGView config not found in repo, skipping."
}
_PrintFooter

# ==============================================================================
# 5. ASSETS & THEMING
# ==============================================================================
_PrintHeader "Martian Mono Nerd Font"
if (!(Get-ChildItem "C:\Windows\Fonts" | Where-Object { $_.Name -like "*Martian*Nerd*" })) {
    $tempZip = "$env:TEMP\fonts.zip"
    $tempFolder = "$env:TEMP\MartianMonoFont"
    try {
        _Info "Downloading font..."
        Invoke-WebRequest -Uri "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/MartianMono.zip" -OutFile $tempZip -UseBasicParsing -ErrorAction Stop
        if (!(Test-Path $tempFolder)) { New-Item -ItemType Directory -Path $tempFolder | Out-Null }
        Expand-Archive -Path $tempZip -DestinationPath $tempFolder -Force
        foreach ($file in (Get-ChildItem -Path $tempFolder -Include "*.ttf", "*.otf" -Recurse)) {
            $targetPath = Join-Path "C:\Windows\Fonts" $file.Name
            try {
                if (!(Test-Path $targetPath)) {
                    Copy-Item $file.FullName $targetPath -Force
                    New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts" -Name $file.Name -Value $file.Name -PropertyType String -Force | Out-Null
                }
            } catch { _Err "Could not install $($file.Name)" }
        }
        _Ok "Martian Mono Nerd Font installed."
    } catch {
        _Err "Failed to download/install font: $_"
    } finally {
        Remove-Item $tempZip, $tempFolder -Recurse -ErrorAction SilentlyContinue
    }
} else {
    _Ok "Martian Mono Nerd Font already installed."
}
_PrintFooter

_PrintHeader "Windows Terminal Nord Theme"
$nordJson = Join-Path $PSScriptRoot "assets\nord.json"
if (Test-Path $nordJson) {
    $wtFragmentPath = "$Env:LocalAppData\Microsoft\Windows Terminal\Fragments\nord"
    if (!(Test-Path $wtFragmentPath)) { New-Item -ItemType Directory -Path $wtFragmentPath -Force | Out-Null }
    Copy-Item -Path $nordJson -Destination $wtFragmentPath -Force
    _Ok "Nord theme installed."
}
_PrintFooter

_PrintHeader "Wallpapers"
$wallpaperDst = Join-Path ([Environment]::GetFolderPath("MyPictures")) "config-wallpapers"
if (-not (Test-Path $wallpaperDst)) {
    _Info "Cloning wallpapers..."
    git clone https://github.com/jehan593/my-wallpapers.git $wallpaperDst
    _Ok "Wallpapers cloned to: $wallpaperDst"
} else {
    _Info "Wallpapers already exist, pulling latest..."
    git -C $wallpaperDst pull --rebase --autostash
    _Ok "Wallpapers updated."
}
_PrintFooter

# ==============================================================================
# 6. TOOLS & SCRIPTS
# ==============================================================================
_PrintHeader "wg-socks Setup"
$configScriptsDir = "$env:USERPROFILE\windows-config-scripts"
$wgsocksDir = "$configScriptsDir\wg-socks"
$wgsocksConf = "$wgsocksDir\configs"
$wireproxyExe = "$wgsocksDir\wireproxy.exe"

if (!(Test-Path $configScriptsDir)) { New-Item -ItemType Directory -Path $configScriptsDir -Force | Out-Null }
if (!(Test-Path $wgsocksDir)) { New-Item -ItemType Directory -Path $wgsocksDir -Force | Out-Null }
if (!(Test-Path $wgsocksConf)) { New-Item -ItemType Directory -Path $wgsocksConf -Force | Out-Null }
_Ok "Folder structure created."

if (-not (Test-Path $wireproxyExe)) {
    $tempFile = "$env:TEMP\wireproxy.tar.gz"
    $tempFolder = "$env:TEMP\wireproxy"
    try {
        _Info "Downloading wireproxy..."
        Invoke-WebRequest -Uri "https://github.com/whyvl/wireproxy/releases/download/v1.0.9/wireproxy_windows_amd64.tar.gz" -OutFile $tempFile -UseBasicParsing -ErrorAction Stop
        if (!(Test-Path $tempFolder)) { New-Item -ItemType Directory -Path $tempFolder -Force | Out-Null }
        tar -xzf $tempFile -C $tempFolder
        $innerArchive = Get-ChildItem -Path $tempFolder -Recurse | Where-Object { $_.Extension -match "\.gz|\.tar" } | Select-Object -First 1
        if ($innerArchive) { tar -xzf $innerArchive.FullName -C $tempFolder }
        $wireproxyBin = Get-ChildItem -Path $tempFolder -Recurse -Filter "wireproxy.exe" | Select-Object -First 1
        if ($wireproxyBin) {
            Copy-Item $wireproxyBin.FullName $wireproxyExe -Force
            _Ok "wireproxy installed."
        } else {
            _Err "Could not find wireproxy.exe after extraction."
        }
    } catch {
        _Err "Failed to install wireproxy: $_"
    } finally {
        Remove-Item $tempFile, $tempFolder -Recurse -ErrorAction SilentlyContinue
    }
} else {
    _Ok "wireproxy already installed."
}
_PrintFooter

_PrintHeader "Windows Terminal Configuration"
$wtSettingsPath = "$env:LocalAppData\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
if (Test-Path $wtSettingsPath) {
    $settings = Get-Content $wtSettingsPath -Raw | ConvertFrom-Json

    $pwshProfile = $settings.profiles.list | Where-Object { $_.name -like "*PowerShell*" -and $_.name -notlike "*Windows*" } | Select-Object -First 1
    if ($pwshProfile) {
        $settings.defaultProfile = $pwshProfile.guid
        _Ok "Default profile set to PowerShell 7."
    } else {
        _Info "PowerShell 7 profile not found, skipping."
    }

    if (-not $settings.profiles.defaults) {
        $settings.profiles | Add-Member -NotePropertyName "defaults" -NotePropertyValue ([PSCustomObject]@{}) -Force
    }

    $settings.profiles.defaults | Add-Member -NotePropertyName "font" -NotePropertyValue ([PSCustomObject]@{
        face = "MartianMono Nerd Font Mono"
        size = 9
    }) -Force
    $settings.profiles.defaults | Add-Member -NotePropertyName "colorScheme" -NotePropertyValue "Nord" -Force

    _Ok "Font set to MartianMono Nerd Font Mono size 9."
    _Ok "Color scheme set to Nord."

    $settings | ConvertTo-Json -Depth 20 | Set-Content $wtSettingsPath -Encoding UTF8
    _Ok "Windows Terminal settings saved."
} else {
    _Info "Windows Terminal not found. Restart Terminal manually after setup and re-run to apply settings."
}
_PrintFooter

# ==============================================================================
# 7. FINALIZATION
# ==============================================================================
try {
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force -ErrorAction Stop
} catch {}
_Ok "Execution policy set."

Write-Host ""
Write-Host "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓" -ForegroundColor Green
Write-Host "┃           Setup Complete!                   ┃" -ForegroundColor Green
Write-Host "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛" -ForegroundColor Green
Write-Host ""
Write-Host "  Set wallpapers manually from:  Pictures\config-wallpapers" -ForegroundColor White
Write-Host ""
Pause