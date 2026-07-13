# ==============================================================================
# 1. SELF-ELEVATION BLOCK
# ==============================================================================
$ConfigPath = $env:WINDOWS_CONFIG_PATH
if (-not $ConfigPath) { $ConfigPath = $PSScriptRoot }

if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
{
    Write-Host "Requesting admin privileges..." -ForegroundColor Yellow
    $currentRuntime = (Get-Process -Id $PID).Path
    $psArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""

    if (Get-Command wt -ErrorAction SilentlyContinue)
    {
        Start-Process -FilePath wt -ArgumentList "new-tab --title `"Reset`" `"$currentRuntime`" $psArgs" -Verb RunAs
    }
    else
    {
        Start-Process -FilePath $currentRuntime -ArgumentList $psArgs -Verb RunAs
    }
    exit
}

. "$ConfigPath\helpers\backup-wg-configs.ps1"
. "$ConfigPath\helpers\winget-apps.ps1"
. "$ConfigPath\helpers\wgm-helper.ps1"
. "$ConfigPath\helpers\wpm-helper.ps1"

# ==============================================================================
# 2. PRE-FLIGHT (CONFIRMATION BANNERS)
# ==============================================================================
Clear-Host
Write-Host ""
Write-Host " ┌──────────────────────────────────────────┐" -ForegroundColor Red
Write-Host " │           WINDOWS CONFIG RESET           │" -ForegroundColor Red
Write-Host " ├──────────────────────────────────────────┤" -ForegroundColor Red
Write-Host " │   This will UNDO everything setup did!   │" -ForegroundColor Yellow
Write-Host " └──────────────────────────────────────────┘" -ForegroundColor Red
Write-Host ""

$response = Read-Host "Are you sure you want to completely reset? (y/N)"
if ($response.Trim().ToLower() -notin @("y", "yes"))
{
    Write-Host "Aborted by user." -ForegroundColor Yellow
    exit
}

Write-Host "`nStarting Reset..." -ForegroundColor Gray

# ==============================================================================
# 3. DOTFILES & CONFIG LINKING UNLINK
# ==============================================================================
function Remove-Symlink {
    param([string]$Path)

    $item = Get-Item $Path -Force -ErrorAction SilentlyContinue
    if ($item.LinkType -ne "SymbolicLink") { Write-Host "Skipped (Not a symbolic link): $Path" -ForegroundColor Yellow; return }
    $isOurLink = $item.Target -like "*$ConfigPath*"
    $backupPath = "$Path.bak"
    try {
        Remove-Item $item.FullName -Force -ErrorAction Stop
        Write-Host "Successfully unlinked: $Path" -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to remove link: $Path. Error: $_"
        return
    }
    if ($isOurLink -and (Test-Path $backupPath)) {
        try {
            Rename-Item -Path $backupPath -NewName $item.Name -Force -ErrorAction Stop
            Write-Host "Restored original: $($item.Name)" -ForegroundColor Green
        }
        catch {
            Write-Error "Failed to restore backup from $backupPath. Error: $_"
        }
    }
}

$HomeSourceRoot = Join-Path $ConfigPath "home"

foreach ($item in (Get-ChildItem -Path $HomeSourceRoot -Recurse -File)) {
    $relativePath = $item.FullName.Substring($HomeSourceRoot.Length + 1)
    $destPath = Join-Path $HOME $relativePath
    Write-Host "`n> Removing $relativePath" -ForegroundColor Blue
    Remove-Symlink $destPath
}

function Remove-RegistryValues {
    param([string]$SourcePath, [string]$RegPath, [string]$StopAt)

    if (-not (Test-Path $RegPath)) {
        Write-Host "Registry key not found: $(Split-Path $RegPath -Leaf) (Skipped)" -ForegroundColor Gray
        return
    }

    try {
        $json = Get-Content $SourcePath -Raw | ConvertFrom-Json
        foreach ($prop in $json.values.PSObject.Properties) {
            # "Name:Type" -> just delete it. "Name:Type:Default" -> an important
            # value; restore it to its declared default instead of deleting it.
            $parts   = $prop.Name -split ':', 3
            $keyName = $parts[0]

            if ($parts.Count -eq 3) {
                $typeSuffix = $parts[1]
                $defaultRaw = $parts[2]
                switch ($typeSuffix) {
                    { $_ -in 'DWord', 'Bool' } {
                        New-ItemProperty -Path $RegPath -Name $keyName -Value ([int]$defaultRaw) -PropertyType DWord -Force | Out-Null
                    }
                    Default {
                        New-ItemProperty -Path $RegPath -Name $keyName -Value $defaultRaw -PropertyType String -Force | Out-Null
                    }
                }
                Write-Host "Restored default value: $keyName" -ForegroundColor Gray
            }
            else {
                Remove-ItemProperty -Path $RegPath -Name $keyName -Force -ErrorAction SilentlyContinue
            }
        }
        Write-Host "Reverted managed values at: $RegPath" -ForegroundColor Green

        # Only remove the key itself (and climb up) if nothing other than what
        # we just cleared/restored ever lived here - never touch pre-existing/foreign content.
        $current = $RegPath
        while ($current -and $current -ne $StopAt -and (Test-Path $current)) {
            $item = Get-Item -Path $current
            if ($item.ValueCount -gt 0 -or $item.SubKeyCount -gt 0) { break }

            Remove-Item -Path $current -Force
            Write-Host "Removed now-empty key: $(Split-Path $current -Leaf)" -ForegroundColor Gray
            $current = Split-Path $current -Parent
        }
    }
    catch {
        Write-Host "Error clearing registry values for $(Split-Path $RegPath -Leaf): $_" -ForegroundColor Red
    }
}

$RegistrySourceRoot = Join-Path $ConfigPath "registry"
$RegistryHives = @('HKLM', 'HKCU')

foreach ($hive in $RegistryHives) {
    $HiveSourceRoot = Join-Path $RegistrySourceRoot $hive
    if (-not (Test-Path $HiveSourceRoot)) { continue }

    $hiveStopAt = "${hive}:\"
    $files = Get-ChildItem -Path $HiveSourceRoot -Recurse -Filter "values.json" |
        Sort-Object { ($_.DirectoryName -split '\\').Count } -Descending

    foreach ($file in $files) {
        $regPath = $file.DirectoryName.Substring($RegistrySourceRoot.Length + 1) -replace '^([^\\]+)\\', '$1:\'
        Write-Host "`n> $regPath" -ForegroundColor Blue
        Remove-RegistryValues -SourcePath $file.FullName -RegPath $regPath -StopAt $hiveStopAt
    }
}

# ==============================================================================
# 4. ASSETS & THEMING ROLLBACK
# ==============================================================================
Write-Host "`n> Martian Mono Font " -ForegroundColor Blue

$windowsFontDir = "$env:WINDIR\Fonts"
$fontsRegPath   = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts"

foreach ($font in Get-ChildItem -Path $windowsFontDir -Filter "MartianMono*" -ErrorAction SilentlyContinue) {
    try {
        $regName = "$([System.IO.Path]::GetFileNameWithoutExtension($font.Name)) ($($font.Extension -replace '\.','' | ForEach-Object { if($_ -eq 'otf') { 'OpenType' } else { 'TrueType' } }))"
        
        Remove-ItemProperty -Path $fontsRegPath -Name $regName -ErrorAction SilentlyContinue
        Remove-Item $font.FullName -Force -ErrorAction Stop
        Write-Host "Removed: $($font.Name)" -ForegroundColor Gray
    }
    catch {
        Write-Host "Failed to remove: $($font.Name)" -ForegroundColor Yellow
    }
}

Write-Host "`n>Windows Terminal Nord Theme" -ForegroundColor Blue
$wtFragmentPath = "$env:LOCALAPPDATA\Microsoft\Windows Terminal\Fragments\nord"

if (Test-Path $wtFragmentPath)
{
    Remove-Item $wtFragmentPath -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Successfully removed Nord theme fragment folder" -ForegroundColor Green
}
else
{
    Write-Host "Nord theme fragment not found (Skipped)" -ForegroundColor Gray
}

Write-Host "`n> Removing Wallpapers" -ForegroundColor Blue
$wallpaperDst = Join-Path ([Environment]::GetFolderPath("MyPictures")) "windows-config-wallpapers"

if (-not (Test-Path $wallpaperDst)) {
    Write-Host "Wallpapers directory not found (Skipped)" -ForegroundColor Gray
} else {
    $confirm = Read-Host "Remove local cloned wallpapers folder? (y/N)"
    if ($confirm -eq 'y') {
        Remove-Item $wallpaperDst -Recurse -Force
        Write-Host "Successfully deleted local wallpapers repository" -ForegroundColor Green
    } else {
        Write-Host "Wallpaper removal skipped" -ForegroundColor Yellow
    }
}

# ==============================================================================
# 5. WIREGUARD MANAGER ROLLBACK
# ==============================================================================
Write-Host "`n> WireGuard Manager Rollback" -ForegroundColor Blue

$wgmConfDir = "$env:LOCALAPPDATA\windows-config-files\wgm\configs"
$wgmDir     = "$env:LOCALAPPDATA\windows-config-files\wgm"
$wgmBackup  = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "wgm-backup"

if (Get-Command wg -ErrorAction SilentlyContinue) {
    $activeTunnel = Get-WgmActiveTunnel
    if ($activeTunnel) {
        Write-Host "Active tunnel detected: $activeTunnel. Terminating..." -ForegroundColor Gray
        if (-not (Disconnect-WgmTunnel -TunnelName $activeTunnel)) {
            Write-Host "Warning: Failed to cleanly disconnect tunnel. Proceeding with caution." -ForegroundColor Yellow
        } else {
            Write-Host "Successfully disconnected tunnel: $activeTunnel" -ForegroundColor Green
        }
    } else {
        Write-Host "No active WireGuard tunnels detected (Skipped)" -ForegroundColor Gray
    }
} else {
    Write-Host "WireGuard CLI (wg) not detected (Skipped)" -ForegroundColor Gray
}

$wgmConfFiles = if (Test-Path $wgmConfDir) { Get-ChildItem -Path $wgmConfDir -Filter "*.conf" -File -ErrorAction SilentlyContinue } else { $null }
if ($wgmConfFiles) {
    Write-Host "Found configuration files. Creating backup..." -ForegroundColor Gray
    if (Backup-Configs -SourcePath $wgmConfDir -BackupDir $wgmBackup) {
        Write-Host "Configurations backed up safely to: Documents\wgm-backup" -ForegroundColor Green
    } else {
        Write-Host "Warning: Failed to backup configs." -ForegroundColor Red
    }
} else {
    Write-Host "No WireGuard profile configs to back up (Skipped)" -ForegroundColor Gray
}

if (Test-Path $wgmDir) {
    Remove-Item $wgmDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Successfully purged local WGM data" -ForegroundColor Green
} else {
    Write-Host "WGM directory not found (Skipped)" -ForegroundColor Gray
}

# ==============================================================================
# 6. WIREPROXY MANAGER ROLLBACK
# ==============================================================================
Write-Host "`n>Wireproxy Manager Rollback" -ForegroundColor Blue

$configScriptsDir = "$env:LOCALAPPDATA\windows-config-files"
$wpmDir           = "$configScriptsDir\wpm"
$wpmConf          = "$wpmDir\configs"
$backupDir        = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "wpm-backup"

$services = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*-wpm" }
$skipWpmCleanup = $false

if ($services) {
    $ans = Read-Host "Existing WPM tunnels found. Remove tunnels and backup configs? (y/N)"
    if ($ans -ne 'y') {
        Write-Host "Wireproxy service removal skipped by user" -ForegroundColor Yellow
        $skipWpmCleanup = $true
    }
    else {
        $wpmConfFiles = if (Test-Path $wpmConf) { Get-ChildItem -Path $wpmConf -Filter "*.conf" -File -ErrorAction SilentlyContinue } else { $null }
        if ($wpmConfFiles) {
            Write-Host "Backing up Wireproxy configuration files..." -ForegroundColor Gray
            if (Backup-Configs -SourcePath $wpmConf -BackupDir $backupDir) {
                Write-Host "WPM configurations backed up safely to: Documents\wpm-backup" -ForegroundColor Green
            }
            else {
                Write-Host "Failed to back up WPM configs" -ForegroundColor Red
            }
        } else {
            Write-Host "No Wireproxy configs to back up (Skipped)" -ForegroundColor Gray
        }

        foreach ($svc in $services) {
            if (Remove-WpmService -ServiceName $svc.Name) { Write-Host "Successfully removed service: $($svc.Name)" -ForegroundColor Green }
            else { Write-Host "Failed to remove service: $($svc.Name)" -ForegroundColor Red }
        }
    }
}

if ($skipWpmCleanup) {
    Write-Host "Leaving WPM directory and binary in place (active service was not removed)" -ForegroundColor Yellow
}
else {
    if (Test-Path $wpmDir) {
        Remove-Item $wpmDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Successfully removed WPM application directory data" -ForegroundColor Green
    }

    $goBinPath = Join-Path $HOME "go\bin"
    $resolvedCmd = Get-Command wireproxy -ErrorAction SilentlyContinue
    if ($resolvedCmd) { $goBinPath = Split-Path $resolvedCmd.Source }

    $goWireproxyExe = Join-Path $goBinPath "wireproxy.exe"
    if (Test-Path $goWireproxyExe) {
        try {
            Remove-Item $goWireproxyExe -Force -ErrorAction Stop
            Write-Host "Successfully deleted compiled wireproxy binary from: $goWireproxyExe" -ForegroundColor Green
        }
        catch {
            Write-Host "Failed to delete wireproxy binary. File might be locked." -ForegroundColor Red
        }
    }
    
    if ((Test-Path $configScriptsDir) -and -not (Get-ChildItem $configScriptsDir -Force)) {
        Remove-Item $configScriptsDir -Force -ErrorAction SilentlyContinue
        Write-Host "Cleaned empty root config directory" -ForegroundColor Gray
    }
}

# ==============================================================================
# 7. INIT CACHES CLEANUP
# ==============================================================================
Write-Host "`n> Clearing Init Caches" -ForegroundColor Blue

$cacheFiles = @(
    "$env:LOCALAPPDATA\windows-config-files\ps-cache\starship_init.ps1",
    "$env:LOCALAPPDATA\windows-config-files\ps-cache\zoxide_init.ps1",
    "$env:LOCALAPPDATA\windows-config-files\winget_search_cache.txt"
)

foreach ($cache in $cacheFiles) {
    if (Test-Path $cache) {
        Remove-Item $cache -Force -ErrorAction SilentlyContinue
        Write-Host "Cleared: $(Split-Path $cache -Leaf)" -ForegroundColor Green
    }else{
        Write-Host "Not found: $(Split-Path $cache -Leaf)" -ForegroundColor Gray
    }
}

# ==============================================================================
# 8. GLOBAL ENVIRONMENT VARIABLES CLEANUP
# ==============================================================================
Write-Host "`n>Global Environment Variables" -ForegroundColor Blue

try
{
    $machineVar = [System.Environment]::GetEnvironmentVariable("WINDOWS_CONFIG_PATH", [System.EnvironmentVariableTarget]::Machine)
    
    if ($machineVar)
    {
        [System.Environment]::SetEnvironmentVariable("WINDOWS_CONFIG_PATH", $null, [System.EnvironmentVariableTarget]::Machine)
        Write-Host "Successfully removed WINDOWS_CONFIG_PATH from global Machine registry scope" -ForegroundColor Green
    }
    else
    {
        Write-Host "WINDOWS_CONFIG_PATH not found in Machine registry scope (Skipped)" -ForegroundColor Gray
    }
}
catch
{
    Write-Host "Failed to successfully uncommit environment variables from registry: $_" -ForegroundColor Red
}

# ==============================================================================
# 9. WINDOWS TERMINAL CONFIGURATION RESET
# ==============================================================================
Write-Host "`n>Windows Terminal Configuration" -ForegroundColor Blue

$wtSettingsPath = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
$fallbackPs5Guid = "{61c54bbd-c2c6-5271-96e7-009a87ff44bf}"

if (-not (Test-Path $wtSettingsPath))
{
    Write-Host "Windows Terminal settings footprint not found (Skipped)" -ForegroundColor Gray
}
else
{
    try
    {
        $settings = Get-Content $wtSettingsPath -Raw | ConvertFrom-Json
        
        $settings.profiles | Add-Member -NotePropertyName "defaults" -NotePropertyValue ([PSCustomObject]@{}) -Force
        Write-Host "Cleared customized terminal profile theme/font defaults" -ForegroundColor Green

        $profileList = if ($settings.profiles.list) { @($settings.profiles.list) } else { @() }
        $nativePs5Profile = $profileList | Where-Object { $_.name -like "*Windows PowerShell*" } | Select-Object -First 1
        
        $restoreGuid = if ($nativePs5Profile.guid) { $nativePs5Profile.guid } else { $fallbackPs5Guid }
        
        $settings | Add-Member -NotePropertyName "defaultProfile" -NotePropertyValue $restoreGuid -Force
        Write-Host "Restored terminal default profile launcher target" -ForegroundColor Green

        $settings | ConvertTo-Json -Depth 20 | Set-Content $wtSettingsPath -Encoding UTF8
        Write-Host "Successfully saved reverted terminal JSON settings" -ForegroundColor Green
    }
    catch
    {
        Write-Host "Failed to modify Windows Terminal configuration file: $_" -ForegroundColor Red
    }
}

# ==============================================================================
# 10. RESET COMPLETE
# ==============================================================================
Write-Host "`n>>> RESET COMPLETE <<<`n" -ForegroundColor Green
Write-Host "Note: Uninstall these manually if you no longer use them:" -ForegroundColor Yellow
foreach ($app in (Get-WingetApps)) { Write-Host "  • $app" -ForegroundColor Yellow }
Write-Host "  • PowerShell 7" -ForegroundColor Yellow
Write-Host ""
Pause