# ==============================================================================
# 1. SELF-ELEVATION BLOCK
# ==============================================================================
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
{
    Write-Host "[..] Requesting admin privileges..." -ForegroundColor Cyan
    $psArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if (Get-Command wt -ErrorAction SilentlyContinue)
    { Start-Process wt -ArgumentList "new-tab --title `"Reset`" pwsh $psArgs" -Verb RunAs }
    else
    { Start-Process pwsh -ArgumentList $psArgs -Verb RunAs }
    exit
}

. (Join-Path $PSScriptRoot "scripts\helpers\setup-helpers.ps1")

# ==============================================================================
# 2. PRE-FLIGHT
# ==============================================================================
Clear-Host
Write-Host ""
Write-Host "+--------------------------------------------+" -ForegroundColor Red
Write-Host "|         Windows Config Reset               |" -ForegroundColor Red
Write-Host "|    This will UNDO everything setup did!    |" -ForegroundColor Yellow
Write-Host "+--------------------------------------------+" -ForegroundColor Red

_PrintHeader "Pre-flight"
$confirm = Read-Host "[WARN] Are you sure you want to reset? (y/N)"
if ($confirm -notmatch '^[Yy]$')
{ _Info "Aborted"; _PrintFooter; exit }
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
        { Remove-Item $Path -Force; _Ok "Removed PowerShell profile link" }
        else
        { _Info "Not a symlink: $Path" }
    } else
    { _Info "Not found: $Path" }
}
_PrintFooter

_PrintHeader "Removing Neovim Configuration"
$initTarget = "$env:LOCALAPPDATA\nvim\init.lua"
$nvimData   = "$env:LOCALAPPDATA\nvim-data"
if (Test-Path $initTarget) {
    $item = Get-Item $initTarget -Force
    if ($item.LinkType -eq "SymbolicLink") {
        Remove-Item $initTarget -Force
        _Ok "Removed Neovim config link"
    } else {
        _Info "Not a symlink: $initTarget"
    }
} else {
    _Info "Not found: $initTarget"
}
if (Test-Path $nvimData) {
    Remove-Item $nvimData -Recurse -Force
    _Ok "Removed Neovim data"
}
_PrintFooter

_PrintHeader "Removing mpv Configuration"
$mpvConfigDir = "$env:APPDATA\mpv.net"
foreach ($file in @("mpv.conf", "input.conf"))
{
    $target = Join-Path $mpvConfigDir $file
    if (Test-Path $target)
    {
        $item = Get-Item $target -Force
        if ($item.LinkType -eq "SymbolicLink")
        { Remove-Item $target -Force; _Ok "Removed mpv config link" }
        else
        { _Info "Not a symlink: $target" }
    } else
    { _Info "Not found: $target" }
}
_PrintFooter

_PrintHeader "Removing Topgrade Configuration"
$topgradeConfigDst = "$env:APPDATA\topgrade.toml"
if (Test-Path $topgradeConfigDst)
{
    $item = Get-Item $topgradeConfigDst -Force
    if ($item.LinkType -eq "SymbolicLink")
    { Remove-Item $topgradeConfigDst -Force; _Ok "Removed topgrade config link" }
    else
    { _Info "Not a symlink: $topgradeConfigDst" }
} else
{ _Info "Not found: $topgradeConfigDst" }
_PrintFooter

_PrintHeader "Removing Brave Policies"
$regBase = "HKLM:\SOFTWARE\Policies\BraveSoftware"
$regPath = "$regBase\Brave"
if (Test-Path $regPath)
{
    Remove-Item $regPath -Recurse -Force
    if (Test-Path $regBase)
    {
        $remaining = Get-ChildItem $regBase
        if (-not $remaining) { Remove-Item $regBase -Recurse -Force }
    }
    _Ok "Removed Brave policies"
} else
{ _Info "Brave policies not found" }
_PrintFooter

_PrintHeader "Removing Firefox Policies"
$regPath = "HKLM:\SOFTWARE\Policies\Mozilla"
if (Test-Path $regPath)
{ Remove-Item $regPath -Recurse -Force; _Ok "Removed Firefox policies" }
else
{ _Info "Firefox policies not found" }
_PrintFooter

_PrintHeader "Removing VS Code Policies"
$regPath = "HKLM:\SOFTWARE\Policies\Microsoft\VSCode"
if (Test-Path $regPath)
{ Remove-Item $regPath -Recurse -Force; _Ok "Removed VS Code policies" }
else
{ _Info "VS Code policies not found" }
_PrintFooter

# ==============================================================================
# 4. ASSETS & THEMING
# ==============================================================================
_PrintHeader "Removing Windows Terminal Nord Theme"
$wtFragmentPath = "$Env:LocalAppData\Microsoft\Windows Terminal\Fragments\nord"
if (Test-Path $wtFragmentPath)
{ Remove-Item $wtFragmentPath -Recurse -Force; _Ok "Removed Nord theme" }
else
{ _Info "Nord theme not found" }
_PrintFooter

_PrintHeader "Removing Wallpapers"
$wallpaperDst = Join-Path ([Environment]::GetFolderPath("MyPictures")) "config-wallpapers"
if (Test-Path $wallpaperDst)
{
    $removeWallpapers = Read-Host "Remove wallpapers folder? (y/N)"
    if ($removeWallpapers -match '^[Yy]$')
    { Remove-Item $wallpaperDst -Recurse -Force; _Ok "Removed wallpapers" }
    else
    { _Info "Skipped wallpaper removal" }
} else
{ _Info "Wallpapers not found" }
_PrintFooter

# ==============================================================================
# 5. TOOLS & SCRIPTS
# ==============================================================================
_PrintHeader "Removing WARP Tunnel"
$vpnConfDir = "$env:LOCALAPPDATA\windows-config\vpn\configs"
$statusFile = "$env:LOCALAPPDATA\windows-config\vpn\.active-tunnel"
$vpnDir     = "$env:LOCALAPPDATA\windows-config\vpn"
$vpnBackup  = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "vpn-configs-backup"

# Disconnect active tunnel if any
$active = $null
if (Test-Path $statusFile)
{ $active = (Get-Content $statusFile -Raw).Trim() -replace '^[^\s]+\s+', '' }
if (-not $active)
{
    $active = Get-Service -Name "WireGuardTunnel*" -ErrorAction SilentlyContinue |
              Where-Object { $_.Status -eq "Running" } |
              Select-Object -First 1 |
              ForEach-Object { $_.Name -replace "WireGuardTunnel$", "" }
}
if ($active)
{
    wireguard /uninstalltunnelservice $active
    if ($LASTEXITCODE -eq 0) { _Ok "Disconnected $active" }
    else                     { _Err "Failed to disconnect $active" }
} else
{ _Info "No active tunnel" }

# Backup configs before removing
if (Test-Path $vpnConfDir)
{
    if (!(Test-Path $vpnBackup)) { New-Item -ItemType Directory -Path $vpnBackup -Force | Out-Null }
    Copy-Item -Path "$vpnConfDir\*.conf" -Destination $vpnBackup -Force
    _Ok "VPN configs backed up"
}

# Remove VPN directory
if (Test-Path $vpnDir)
{ Remove-Item $vpnDir -Recurse -Force; _Ok "Removed VPN configs" }
else
{ _Info "VPN configs not found" }
_PrintFooter

_PrintHeader "Removing wg-socks"
$configScriptsDir = "$env:LOCALAPPDATA\windows-config"
$wgsocksDir       = "$configScriptsDir\wg-socks"
$services         = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*-wgsocks" }
$removedTunnels   = $false

if ($services)
{
    $stopTunnels = Read-Host "Remove existing tunnels and backup configs? (y/N)"
    if ($stopTunnels -match '^[Yy]$')
    {
        $removedTunnels = $true
        $wgsocksConf = "$wgsocksDir\configs"
        if (Test-Path $wgsocksConf)
        {
            $backupDir = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "wg-socks-backup"
            if (!(Test-Path $backupDir))
            { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
            Copy-Item -Path "$wgsocksConf\*.conf" -Destination $backupDir -Force
            _Ok "wg-socks configs backed up"
        }
        foreach ($svc in $services)
        {
            servy-cli stop      --name="$($svc.Name)" --quiet
            servy-cli uninstall --name="$($svc.Name)" --quiet
            if ($LASTEXITCODE -eq 0) { _Ok "Removed service $($svc.Name)" }
            else                     { _Err "Failed to remove service $($svc.Name)" }
        }
        if (Test-Path $wgsocksDir)
        { Remove-Item $wgsocksDir -Recurse -Force; _Ok "Removed wg-socks directory" }
    } else
    { _Info "Skipped tunnel removal" }
} else
{
    $removedTunnels = $true
    if (Test-Path $wgsocksDir)
    { Remove-Item $wgsocksDir -Recurse -Force; _Ok "Removed wg-socks directory" }
    else
    { _Info "wg-socks directory not found" }
}

if ((Test-Path $configScriptsDir) -and !(Get-ChildItem $configScriptsDir -Force))
{ Remove-Item $configScriptsDir -Force; _Ok "Removed config directory" }
_PrintFooter

_PrintHeader "Removing Init Caches"
@(
    "$env:TEMP\starship_init.ps1"
    "$env:TEMP\zoxide_init.ps1"
    "$env:LOCALAPPDATA\windows-config\winget_search_cache.txt"
) | ForEach-Object {
    if (Test-Path $_)
    { Remove-Item $_ -Force; _Ok "Removed cache: $_" }
    else
    { _Info "Cache not found: $_" }
}
_PrintFooter

# ==============================================================================
# 6. OPTIONAL - Uninstall Apps
# ==============================================================================
_PrintHeader "Optional: Package Removal"
_Info "Targets: Starship, fzf, zoxide, fd, wgcf, gup, topgrade$(if ($removedTunnels) { ', Servy' })"
$response = Read-Host "Remove these packages? (y/N)"

if ($response -match '^[Yy]$')
{
    $apps = @(
        "Starship.Starship", "junegunn.fzf", "ajeetdsouza.zoxide",
        "sharkdp.fd", "ViRb3.wgcf", "topgrade-rs.topgrade", "nao1215.gup"
    )
    if ($removedTunnels)
    { $apps += "aelassas.Servy" }
    else
    { _Info "Skipped Servy uninstall" }

    foreach ($app in $apps)
    {
        winget uninstall --id $app --exact --silent
        if ($LASTEXITCODE -eq 0)
        { _Ok "Uninstalled $app" }
        else
        { _Err "Uninstall failed: $app" }
    }
} else
{ _Info "Skipped package removal" }
_PrintFooter

# ==============================================================================
# 7. WINDOWS TERMINAL RESTORE
# ==============================================================================
_PrintHeader "Restoring Windows Terminal Configuration"
$wtSettingsPath = "$env:LocalAppData\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
$ps5Guid        = "{61c54bbd-c2c6-5271-96e7-009a87ff44bf}"

if (Test-Path $wtSettingsPath)
{
    $settings = Get-Content $wtSettingsPath -Raw | ConvertFrom-Json
    $settings.profiles | Add-Member -NotePropertyName "defaults" -NotePropertyValue ([PSCustomObject]@{}) -Force
    _Ok "Cleared terminal profile defaults"

    $ps5Profile = ([System.Collections.Generic.List[object]]($settings.profiles.list ?? @())) |
        Where-Object { $_.name -like "*Windows PowerShell*" } | Select-Object -First 1
    $restoreGuid = if ($ps5Profile) { $ps5Profile.guid } else { $ps5Guid }
    $settings | Add-Member -NotePropertyName "defaultProfile" -NotePropertyValue $restoreGuid -Force
    _Ok "Restored default profile"

    $settings | ConvertTo-Json -Depth 20 | Set-Content $wtSettingsPath -Encoding UTF8
    _Ok "Saved terminal settings"
} else
{ _Info "Terminal settings not found" }
_PrintFooter

# ==============================================================================
# 8. FINALIZATION
# ==============================================================================
Write-Host ""
Write-Host "+--------------------------------------------+" -ForegroundColor Green
Write-Host "|           Reset complete                   |" -ForegroundColor Green
Write-Host "+--------------------------------------------+" -ForegroundColor Green
Write-Host ""
Write-Host "[..] Set wallpaper manually if needed" -ForegroundColor Cyan
Write-Host ""
Pause