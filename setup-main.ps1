# ==============================================================================
# 1. SELF-ELEVATION BLOCK
# ==============================================================================
if (-not $PSScriptRoot)
{
    Write-Host "[!!] Run this as a script file, not dot-sourced." -ForegroundColor Red
    exit
}
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
{
    Write-Host "[..] Requesting administrative privileges..." -ForegroundColor Yellow
    $arguments = "pwsh -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    Start-Process wt -ArgumentList $arguments -Verb RunAs
    exit
}

$RepoPath = $PSScriptRoot

# ==============================================================================
# UI HELPERS
# ==============================================================================
function _PrintHeader
{
    param([string]$Title)
    Write-Host ""
    Write-Host ">>  $Title" -ForegroundColor Cyan
    Write-Host "-----------------------------------------------------" -ForegroundColor DarkBlue
}

function _PrintFooter
{
    Write-Host "-----------------------------------------------------`n" -ForegroundColor DarkBlue
}

function _Ok   { param([string]$Msg) Write-Host ("[ok] {0}" -f $Msg) -ForegroundColor Green }
function _Info { param([string]$Msg) Write-Host ("[..] {0}" -f $Msg) -ForegroundColor Cyan }
function _Err  { param([string]$Msg) Write-Host ("[!!] {0}" -f $Msg) -ForegroundColor Red }

# ==============================================================================
# 2. PRE-FLIGHT
# ==============================================================================
Clear-Host
Write-Host ""
Write-Host "+--------------------------------------------+" -ForegroundColor Cyan
Write-Host "|        Windows Config Setup                |" -ForegroundColor Cyan
Write-Host "+--------------------------------------------+" -ForegroundColor Cyan

# ==============================================================================
# 3. PACKAGE MANAGERS & CORE TOOLS
# ==============================================================================
_PrintHeader "Winget Apps"
$apps = @(
    "Starship.Starship", "junegunn.fzf", "Git.Git", "ajeetdsouza.zoxide",
    "vim.vim", "sharkdp.bat", "sharkdp.fd", "aelassas.Servy",
    "WireGuard.WireGuard", "ViRb3.wgcf", "GoLang.Go", "gerardog.gsudo"
    "nomacs.nomacs", "mpv.net"
)
foreach ($app in $apps)
{
    $installed = winget list --id $app --exact --source winget 2>&1 | Out-String
    if ($installed -notmatch $app)
    {
        _Info "Installing $app..."
        winget install --id $app --source winget --interactive
        if ($LASTEXITCODE -eq 0)
        { _Ok "$app" }
        else
        { _Err "$app install failed" }
    } else
    {
        _Ok "$app already installed"
    }
}
_PrintFooter

_PrintHeader "PowerShell Modules"
if (-not (Get-Module -ListAvailable -Name Microsoft.WinGet.Client))
{
    _Info "Installing Microsoft.WinGet.Client..."
    Install-Module -Name Microsoft.WinGet.Client -Force -Scope CurrentUser
    _Ok "Microsoft.WinGet.Client"
} else
{
    _Ok "Microsoft.WinGet.Client already installed"
}

if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate))
{
    _Info "Installing PSWindowsUpdate..."
    Install-Module -Name PSWindowsUpdate -Force -Scope CurrentUser
    _Ok "PSWindowsUpdate"
} else
{
    _Ok "PSWindowsUpdate already installed"
}

if (-not (Get-Module -ListAvailable -Name Terminal-Icons))
{
    _Info "Installing Terminal-Icons..."
    Install-Module -Name Terminal-Icons -Force -Scope CurrentUser
    $nordThemePath = "$RepoPath\configs\ps-modules\Terminal-Icons\nord.psd1"
    if (Test-Path $nordThemePath)
    {
        Add-TerminalIconsColorTheme -Path $nordThemePath -Force
        Set-TerminalIconsTheme -ColorTheme 'Nord'
        _Ok "Terminal-Icons with Nord theme"
    } else
    {
        _Ok "Terminal-Icons installed (Nord theme not found in repo, skipped)"
    }
} else
{
    _Ok "Terminal-Icons already installed"
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
foreach ($Path in $Profiles)
{
    $Dir = Split-Path $Path
    if (!(Test-Path $Dir))
    { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
    if (Test-Path $Path)
    {
        $existing = Get-Item $Path -Force
        if ($existing.LinkType -eq "SymbolicLink" -and $existing.Target -eq $RepoProfile)
        {
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
if (Test-Path $RepoVimrc)
{
    if (Test-Path $HomeVimrc)
    { Remove-Item $HomeVimrc -Force }
    New-Item -ItemType SymbolicLink -Path $HomeVimrc -Value $RepoVimrc -Force | Out-Null
    _Ok "Linked: $HomeVimrc"
}

$VimColorsDir = Join-Path $HOME "vimfiles\colors"
if (!(Test-Path $VimColorsDir))
{ New-Item -ItemType Directory -Path $VimColorsDir -Force | Out-Null }
try
{
    Invoke-WebRequest -Uri "https://raw.githubusercontent.com/nordtheme/vim/main/colors/nord.vim" `
        -OutFile (Join-Path $VimColorsDir "nord.vim") -UseBasicParsing -ErrorAction Stop
    _Ok "Nord vim theme downloaded"
} catch
{
    _Err "Failed to download Nord theme: $_"
}
_PrintFooter

_PrintHeader "mpv Configuration"
$mpvConfigDir = "$env:APPDATA\mpv.net"
$repoMpvDir   = Join-Path $PSScriptRoot "configs\mpv"
New-Item -ItemType Directory -Path $mpvConfigDir -Force | Out-Null
foreach ($file in @("mpv.conf", "input.conf"))
{
    $target = Join-Path $mpvConfigDir $file
    $source = Join-Path $repoMpvDir $file
    if (Test-Path $target)
    { Remove-Item $target -Force }
    New-Item -ItemType SymbolicLink -Path $target -Value $source -Force | Out-Null
    _Ok "Linked: $target"
}
_PrintFooter

_PrintHeader "Brave Policies"
$bravePolicySrc = Join-Path $PSScriptRoot "configs\brave\policies.json"
if (Test-Path $bravePolicySrc)
{
    $policies = Get-Content $bravePolicySrc | ConvertFrom-Json
    $regPath  = "HKLM:\SOFTWARE\Policies\BraveSoftware\Brave"
    if (!(Test-Path $regPath))
    { New-Item -Path $regPath -Force | Out-Null }
    foreach ($key in $policies.PSObject.Properties)
    {
        New-ItemProperty -Path $regPath -Name $key.Name -Value $key.Value -PropertyType DWORD -Force | Out-Null
    }
    _Ok "Brave policies applied via registry"
} else
{
    _Info "Brave policies file not found in repo, skipping"
}
_PrintFooter

# ==============================================================================
# 5. ASSETS & THEMING
# ==============================================================================
_PrintHeader "Martian Mono Nerd Font"
if (!(Get-Module -ListAvailable -Name NerdFonts))
{
    _Info "Installing NerdFonts module..."
    Install-PSResource -Name NerdFonts -Quiet -TrustRepository
}
Import-Module -Name NerdFonts
Install-NerdFont -Name 'MartianMono'
if ($LASTEXITCODE -eq 0)
{ _Ok "Martian Mono Nerd Font installed" }
else
{ _Err "Font install failed" }
_PrintFooter

_PrintHeader "Windows Terminal Nord Theme"
$nordJson = Join-Path $PSScriptRoot "assets\nord.json"
if (Test-Path $nordJson)
{
    $wtFragmentPath = "$Env:LocalAppData\Microsoft\Windows Terminal\Fragments\nord"
    if (!(Test-Path $wtFragmentPath))
    { New-Item -ItemType Directory -Path $wtFragmentPath -Force | Out-Null }
    Copy-Item -Path $nordJson -Destination $wtFragmentPath -Force
    _Ok "Nord theme installed"
} else
{
    _Info "Nord theme JSON not found in repo, skipping"
}
_PrintFooter

_PrintHeader "Wallpapers"
$wallpaperDst = Join-Path ([Environment]::GetFolderPath("MyPictures")) "config-wallpapers"
if (-not (Test-Path $wallpaperDst))
{
    _Info "Cloning wallpapers..."
    git clone --depth 1 https://github.com/jehan593/my-wallpapers.git $wallpaperDst
    if ($LASTEXITCODE -eq 0)
    { _Ok "Cloned to: $wallpaperDst" }
    else
    { _Err "Clone failed" }
} else
{
    _Info "Wallpapers exist, pulling latest..."
    git -C $wallpaperDst pull --rebase --autostash
    if ($LASTEXITCODE -eq 0)
    { _Ok "Wallpapers updated" }
    else
    { _Err "Pull failed" }
}
_PrintFooter

# ==============================================================================
# 6. TOOLS & SCRIPTS
# ==============================================================================
_PrintHeader "wg-socks Setup"
$configScriptsDir = "$env:APPDATA\windows-config"
$wgsocksConf      = "$configScriptsDir\wg-socks\configs"
foreach ($dir in @($configScriptsDir, $wgsocksConf))
{
    if (!(Test-Path $dir))
    { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}
_Ok "Folder structure created"

$env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" +
            [System.Environment]::GetEnvironmentVariable("PATH", "User")

if (Get-Command go -ErrorAction SilentlyContinue)
{
    _Info "Installing wireproxy..."
    go install github.com/windtf/wireproxy/cmd/wireproxy@latest
    if ($LASTEXITCODE -eq 0)
    { _Ok "wireproxy installed" }
    else
    { _Err "go install failed. Check Go installation." }
} else
{
    _Err "go not found in PATH. Restart terminal and re-run, or install Go manually."
}
_PrintFooter

_PrintHeader "Windows Terminal Configuration"
$wtSettingsPath = "$env:LocalAppData\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
$wtDir          = Split-Path $wtSettingsPath
if (-not (Test-Path $wtDir))
{ New-Item -ItemType Directory -Path $wtDir -Force | Out-Null }

$pwsh7Guid = "{574e775e-4f2a-5b96-ac1e-a2962a402336}"
$nordFont  = [PSCustomObject]@{ face = "MartianMono Nerd Font Mono"; size = 9 }

if (-not (Test-Path $wtSettingsPath))
{
    $barebonesSettings = [PSCustomObject]@{
        defaultProfile = $pwsh7Guid
        profiles       = [PSCustomObject]@{
            defaults = [PSCustomObject]@{ colorScheme = "Nord"; font = $nordFont }
            list     = @()
        }
    }
    $barebonesSettings | ConvertTo-Json -Depth 10 | Set-Content $wtSettingsPath -Encoding UTF8
    _Ok "Created initial settings (Nord + MartianMono 9, PowerShell 7 default)"
} else
{
    $settings = Get-Content $wtSettingsPath -Raw | ConvertFrom-Json
    $settings.profiles | Add-Member -NotePropertyName "defaults" -NotePropertyValue (
        [PSCustomObject]@{ colorScheme = "Nord"; font = $nordFont }
    ) -Force
    $settings | Add-Member -NotePropertyName "defaultProfile" -NotePropertyValue $pwsh7Guid -Force
    $settings | ConvertTo-Json -Depth 20 | Set-Content $wtSettingsPath -Encoding UTF8
    _Ok "Applied Nord, MartianMono 9, and PowerShell 7 to existing settings"
}
_PrintFooter

# ==============================================================================
# 7. FINALIZATION
# ==============================================================================
try
{
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force -ErrorAction Stop
} catch {}
_Ok "Execution policy set"

Write-Host ""
Write-Host "+--------------------------------------------+" -ForegroundColor Green
Write-Host "|           Setup complete                   |" -ForegroundColor Green
Write-Host "+--------------------------------------------+" -ForegroundColor Green
Write-Host ""
Write-Host "[..] Set wallpapers manually from: Pictures\config-wallpapers" -ForegroundColor Cyan
Write-Host ""
Pause