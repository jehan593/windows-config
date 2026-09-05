# ==============================================================================
# 1. SELF-ELEVATION BLOCK
# ==============================================================================
$ConfigPath = $PSScriptRoot

. "$ConfigPath\helpers\elevate.ps1"
Assert-Elevated -ScriptPath $PSCommandPath -Title "Setup"

# ==============================================================================
# 2. PRE-FLIGHT
# ==============================================================================
Clear-Host
Write-Host ""
Write-Host " ┌──────────────────────────────────────────┐" -ForegroundColor Cyan
Write-Host " │           WINDOWS CONFIG SETUP           │" -ForegroundColor Cyan
Write-Host " └──────────────────────────────────────────┘" -ForegroundColor Cyan
Write-Host ""

# ==============================================================================
# 3. PACKAGE MANAGERS & CORE TOOLS
# ==============================================================================
. "$ConfigPath\helpers\packages.ps1"
. "$ConfigPath\helpers\registry-value.ps1"
. "$ConfigPath\helpers\wireproxy-install.ps1"
. "$ConfigPath\helpers\font-install.ps1"
. "$ConfigPath\helpers\repo-list.ps1"

Write-Host "`n>Winget Packages" -ForegroundColor Blue

foreach ($app in (Get-WingetApps))
{
    Write-Host "`n--- $app ---" -ForegroundColor DarkGray
    $installed = winget list --id $app --source winget --exact 2>$null | Select-String -Pattern $app
    if ($installed) {
        Write-Host "Already installed: $app" -ForegroundColor Green
    } else {
        winget install --id $app --source winget --silent --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Installed: $app" -ForegroundColor Green
        } else {
            Write-Host "Failed to install $app (winget exit code $LASTEXITCODE)" -ForegroundColor Red
        }
    }
}

Write-Host "`n>PowerShell Modules" -ForegroundColor Blue

foreach ($module in (Get-PsModules))
{
    try
    {
        Write-Host "`n--- $module ---" -ForegroundColor DarkGray
        Install-Module -Name $module -Force -Scope CurrentUser -AllowClobber -AcceptLicense -SkipPublisherCheck -ErrorAction Stop
        Write-Host "Module installed successfully" -ForegroundColor Green
    }
    catch
    {
        Write-Host "$($_.Exception.Message)" -ForegroundColor Red
    }
}

try
{
    Import-Module Terminal-Icons -ErrorAction Stop
    $nordThemePath = "$ConfigPath\data\ps-modules\Terminal-Icons\nord.psd1"
    Add-TerminalIconsColorTheme -Path $nordThemePath -Force
    Set-TerminalIconsTheme -ColorTheme 'Nord'
    Write-Host "Terminal-Icons configured with Nord theme" -ForegroundColor Green
}
catch
{
    Write-Host "$($_.Exception.Message)" -ForegroundColor Red
}

# ==============================================================================
# 4. DOTFILES & CONFIG LINKING
# ==============================================================================

function Set-Symlink {
    param([string]$Path, [string]$Target)

    try {
        $parent = Split-Path $Path
        if ($parent) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }

        if (Test-Path $Path -PathType Any) {
            $existing = Get-Item $Path -Force
            if ($existing.LinkType -eq "SymbolicLink" -and $existing.Target -eq $Target) { 
                Write-Host "Already linked: $Path" -ForegroundColor Green
                return 
            }
            
            Remove-Item -Path "$Path.bak" -Recurse -Force -ErrorAction SilentlyContinue
            Rename-Item -Path $Path -NewName "$Path.bak" -Force -ErrorAction Stop
        }
        New-Item -ItemType SymbolicLink -Path $Path -Value $Target -Force -ErrorAction Stop | Out-Null
        Write-Host "Linked: $Path -> $Target" -ForegroundColor Green
    }
    catch {
        Write-Host "Failed to set symlink at '$Path'. Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

$HomeSourceRoot = Join-Path $ConfigPath "home"

Write-Host "`n>Linking Files to Home Directory..." -ForegroundColor Blue
foreach ($item in (Get-ChildItem -Path $HomeSourceRoot -Recurse -File)) {
    $relativePath = $item.FullName.Substring($HomeSourceRoot.Length + 1)
    $destPath = Join-Path $HOME $relativePath
    Set-Symlink -Path $destPath -Target $item.FullName
}

function Set-RegistryValues {
    param([string]$RegPath, [array]$Values)

    try {
        # New-Item -Force on a path that already exists wipes ALL of that key's
        # existing values and subkeys - only call it when the key is genuinely new.
        if (-not (Test-Path $RegPath)) {
            New-Item -Path $RegPath -Force | Out-Null
        }

        foreach ($entry in $Values) {
            $propType, $propValue = ConvertTo-RegistryTypedValue -Type $entry.type -RawValue $entry.value -EntryName $entry.name

            # The registry provider has no -Name for a key's (Default) value -
            # New-ItemProperty rejects an empty name, so it must go through Set-Item.
            if ($entry.name -eq '(Default)') {
                Set-Item -Path $RegPath -Value $propValue | Out-Null
            } else {
                New-ItemProperty -Path $RegPath -Name $entry.name -Value $propValue -PropertyType $propType -Force | Out-Null
            }
        }
        Write-Host "Registry values applied successfully to: $RegPath" -ForegroundColor Green
    }
    catch {
        Write-Host "Failed to apply registry values to ${RegPath}: $($_.Exception.Message)" -ForegroundColor Red
    }
}

$RegistryFile = Join-Path $ConfigPath "registry\registry.json"
$RegistryData = Get-Content $RegistryFile -Raw | ConvertFrom-Json
$RegistryHives = @('HKLM', 'HKCU')

Write-Host "`n> Applying Registry Values" -ForegroundColor Blue

foreach ($hive in $RegistryHives) {
    $entries = $RegistryData.$hive
    if (-not $entries) { continue }

    foreach ($entry in $entries) {
        $regPath = "${hive}:\$($entry.path)"
        Set-RegistryValues -RegPath $regPath -Values $entry.values
    }
}

# ==============================================================================
# 5. ASSETS & THEMING
# ==============================================================================
Write-Host "`n> Installing Martian Mono Nerd Font" -ForegroundColor Blue

$fontResult = Install-MartianMonoFont
if (-not $fontResult.Success) {
    Write-Host "Martian Mono Nerd Font installation failed: $($fontResult.Error)" -ForegroundColor Red
}
elseif ($fontResult.UpToDate) {
    Write-Host "Martian Mono Nerd Font already up to date." -ForegroundColor Green
}
else {
    foreach ($name in $fontResult.Installed)     { Write-Host "Installed: $name" -ForegroundColor Gray }
    foreach ($name in $fontResult.Updated)       { Write-Host "Updated: $name" -ForegroundColor Gray }
    foreach ($name in $fontResult.SkippedInUse)  { Write-Host "In use, skipped: $name" -ForegroundColor Yellow }
    if ($fontResult.RebootCleanup.Count -gt 0)   { Write-Host "Old copies pending deletion at next reboot." -ForegroundColor Yellow }
    Write-Host "Martian Mono Nerd Font setup complete." -ForegroundColor Green
}

Write-Host "`n> Windows Terminal Nord Theme" -ForegroundColor Blue

$nordJson = Join-Path $PSScriptRoot "data\Windows-Terminal\nord.json"
$wtFragmentPath = "$env:LOCALAPPDATA\Microsoft\Windows Terminal\Fragments\nord"

try {
    New-Item -ItemType Directory -Path $wtFragmentPath -Force | Out-Null
    Copy-Item -Path $nordJson -Destination (Join-Path $wtFragmentPath "nord.json") -Force -ErrorAction Stop
    Write-Host "Nord theme fragment deployed successfully" -ForegroundColor Green
}
catch {
    Write-Host "Failed to deploy Nord theme fragment: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host "`n> Cloning Repos" -ForegroundColor Blue

foreach ($entry in (Get-RepoList)) {
    $repo = Get-RepoEntry $entry
    $repoPath = $repo.Path
    $displayPath = $repo.DisplayPath

    if (Test-Path (Join-Path $repoPath ".git")) {
        Write-Host "$($repo.Name) already cloned at $displayPath" -ForegroundColor Green
    }
    elseif (Test-Path $repoPath) {
        Write-Host "Destination $displayPath already exists, skipping $($repo.Name)" -ForegroundColor Yellow
    }
    else {
        Write-Host "Cloning $($repo.Name)..." -ForegroundColor Yellow
        git clone --depth 1 $repo.Url $repoPath
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Cloned $($repo.Name) to $displayPath" -ForegroundColor Green
        }
        else {
            Write-Host "Failed to clone $($repo.Url)" -ForegroundColor Red
        }
    }
}

# ==============================================================================
# 6. TOOLS & SCRIPTS
# ==============================================================================
Write-Host "`n> Wireproxy Manager" -ForegroundColor Blue

try {
    $wireproxyResult = Install-Wireproxy
    if (-not $wireproxyResult.Success) {
        Write-Host "Failed to install wireproxy: $($wireproxyResult.Error)" -ForegroundColor Red
    }
    elseif ($wireproxyResult.UpToDate) {
        Write-Host "wireproxy already up to date: $($wireproxyResult.Path)" -ForegroundColor Green
    }
    else {
        Write-Host "wireproxy installed successfully: $($wireproxyResult.Path)" -ForegroundColor Green
    }
}
catch {
    Write-Host "Failed to install wireproxy: $($_.Exception.Message)" -ForegroundColor Red
}


Write-Host "`n>Windows Terminal Configuration" -ForegroundColor Blue

try
{
    $wtSettingsPath = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
    $wtDir          = Split-Path $wtSettingsPath
    New-Item -ItemType Directory -Path $wtDir -Force | Out-Null

    $pwsh7Guid      = "{574e775e-4f2a-5b96-ac1e-a2962a402336}"
    $targetDefaults = [PSCustomObject]@{ colorScheme = "Nord"; font = [PSCustomObject]@{ face = "MartianMono Nerd Font Mono"; size = 9 } }

    if (-not (Test-Path $wtSettingsPath))
    {
        $settings = [PSCustomObject]@{
            defaultProfile = $pwsh7Guid
            profiles       = [PSCustomObject]@{ defaults = $targetDefaults; list = @() }
        }
    }
    else
    {
        Copy-Item $wtSettingsPath "$wtSettingsPath.bak" -Force -ErrorAction Stop
        $settings = Get-Content $wtSettingsPath -Raw | ConvertFrom-Json
        $settings.profiles | Add-Member -NotePropertyName "defaults" -NotePropertyValue $targetDefaults -Force
        $settings | Add-Member -NotePropertyName "defaultProfile" -NotePropertyValue $pwsh7Guid -Force
    }

    $settings | ConvertTo-Json -Depth 20 | Set-Content $wtSettingsPath -Encoding UTF8 -ErrorAction Stop
    Write-Host "Windows Terminal settings updated" -ForegroundColor Green
}
catch
{
    Write-Host "Failed to update Windows Terminal settings: $_" -ForegroundColor Red
}

# ==============================================================================
# 6.5. ENV VARIABLES
# ==============================================================================
Write-Host "`n>Environment Variables" -ForegroundColor Blue

try
{
    $env:WINDOWS_CONFIG_PATH = $ConfigPath
    [System.Environment]::SetEnvironmentVariable("WINDOWS_CONFIG_PATH", $ConfigPath, [System.EnvironmentVariableTarget]::Machine)
    Write-Host "WINDOWS_CONFIG_PATH successfully set to: $ConfigPath" -ForegroundColor Green
}
catch
{
    Write-Host "Failed to commit global Machine environment variable: $_" -ForegroundColor Red
}

# ==============================================================================
# 7. FINALIZATION
# ==============================================================================
Write-Host "`n>Execution Policy Validation" -ForegroundColor Blue

$effectivePolicy = Get-ExecutionPolicy -Scope CurrentUser

if ($effectivePolicy -in @('Bypass', 'Unrestricted', 'RemoteSigned'))
{
    Write-Host "Execution policy is already sufficient for CurrentUser ($effectivePolicy)" -ForegroundColor Green
}
else
{
    try
    {
        Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force -ErrorAction Stop
        Write-Host "Execution policy successfully set to RemoteSigned (CurrentUser)" -ForegroundColor Green
    }
    catch
    {
        Write-Host "Could not set execution policy at CurrentUser scope: $_" -ForegroundColor Yellow
    }
}

# ==============================================================================
# COMPLETION REPORT
# ==============================================================================
Write-Host ""
Write-Host " ┌──────────────────────────────────────────┐" -ForegroundColor Cyan
Write-Host " │              SETUP COMPLETE              │" -ForegroundColor Cyan
Write-Host " └──────────────────────────────────────────┘" -ForegroundColor Cyan
Write-Host ""
Write-Host " • Repos cloned to: ~\Pictures, ~\browser-extensions" -ForegroundColor Gray
Write-Host " • Please restart your terminal application to apply active PATH environment changes." -ForegroundColor Gray
Write-Host " • Restart Explorer or sign out and sign back in to apply some registry tweaks." -ForegroundColor Gray
Write-Host ""

Pause