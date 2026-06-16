# ==============================================================================
# 1. SELF-ELEVATION BLOCK
# ==============================================================================
$RepoPath = $PSScriptRoot

if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
{
    Write-Host "[..] Requesting administrative privileges..." -ForegroundColor Yellow
    $psArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if (Get-Command wt -ErrorAction SilentlyContinue)
    { Start-Process wt -ArgumentList "new-tab --title `"Setup`" pwsh $psArgs" -Verb RunAs }
    else
    { Start-Process pwsh -ArgumentList $psArgs -Verb RunAs }
    exit
}
. "$RepoPath\scripts\setup-helpers.ps1"
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
    "sharkdp.fd", "aelassas.Servy",
    "WireGuard.WireGuard", "ViRb3.wgcf", "GoLang.Go", "gerardog.gsudo",
    "jurplel.qView", "mpv.net", "Neovim.Neovim"
)
foreach ($app in $apps)
{
    $installed = winget list --id $app --exact 2>&1 | Out-String
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

if (-not (Get-Module -ListAvailable -Name Terminal-Icons))
{
    _Info "Installing Terminal-Icons..."
    Install-Module -Name Terminal-Icons -Force -Scope CurrentUser
    Import-Module Terminal-Icons
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
Set-Symlink "$HOME\Documents\PowerShell\Microsoft.PowerShell_profile.ps1" $RepoProfile
_PrintFooter

_PrintHeader "Neovim Configuration"
$repoInitLua = Join-Path $PSScriptRoot "configs\nvim\init.lua"
Set-Symlink "$env:LOCALAPPDATA\nvim\init.lua" $repoInitLua
_PrintFooter

_PrintHeader "mpv Configuration"
$mpvConfigDir = "$env:APPDATA\mpv.net"
$repoMpvDir   = Join-Path $PSScriptRoot "configs\mpv"
New-Item -ItemType Directory -Path $mpvConfigDir -Force | Out-Null
foreach ($file in @("mpv.conf", "input.conf"))
{
    Set-Symlink (Join-Path $mpvConfigDir $file) (Join-Path $repoMpvDir $file)
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
        $type = if ($key.Value -is [int]) { 'DWORD' } else { 'String' }
        New-ItemProperty -Path $regPath -Name $key.Name -Value $key.Value -PropertyType $type -Force | Out-Null
    }
    _Ok "Brave policies applied via registry"
} else
{
    _Info "Brave policies file not found in repo, skipping"
}
_PrintFooter

_PrintHeader "Firefox Policies"
$regPath = "HKLM:\SOFTWARE\Policies\Mozilla\Firefox\ExtensionSettings"
if (!(Test-Path $regPath))
{ New-Item -Path $regPath -Force | Out-Null }
$extId     = "uBlock0@raymondhill.net"
$extPolicy = '{"installation_mode":"normal_installed","install_url":"https://addons.mozilla.org/firefox/downloads/latest/ublock-origin/latest.xpi"}'
New-ItemProperty -Path $regPath -Name $extId -Value $extPolicy -PropertyType MultiString -Force | Out-Null
_Ok "Firefox policies applied via registry"
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
try
{
    Install-NerdFont -Name 'MartianMono'
    _Ok "Martian Mono Nerd Font installed"
} catch
{ _Err "Font install failed: $_" }
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
$configScriptsDir = "$env:LOCALAPPDATA\windows-config"
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
    {
        _Ok "wireproxy installed"
        $env:PATH += ";$env:USERPROFILE\go\bin"
    } else
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
    Copy-Item $wtSettingsPath "$wtSettingsPath.bak" -Force
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
$effectivePolicy = Get-ExecutionPolicy
if ($effectivePolicy -in @('Bypass', 'Unrestricted', 'RemoteSigned'))
{
    _Ok "Execution policy already sufficient ($effectivePolicy)"
} else
{
    try
    {
        Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force -ErrorAction Stop
        _Ok "Execution policy set (LocalMachine)"
    } catch
    {
        try
        {
            Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force -ErrorAction Stop
            _Ok "Execution policy set (CurrentUser)"
        } catch
        { _Warn "Execution policy not updated — effective policy is '$effectivePolicy', continuing anyway." }
    }
}

Write-Host ""
Write-Host "+--------------------------------------------+" -ForegroundColor Green
Write-Host "|           Setup complete                   |" -ForegroundColor Green
Write-Host "+--------------------------------------------+" -ForegroundColor Green
Write-Host ""
Write-Host "[..] Set wallpapers manually from: Pictures\config-wallpapers" -ForegroundColor Cyan
Write-Host "[..] Restart your terminal to ensure all PATH changes (wireproxy, go) take effect" -ForegroundColor Cyan
Write-Host ""
Pause