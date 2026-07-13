# ==============================================================================
# 1. SELF-ELEVATION BLOCK
# ==============================================================================
$ConfigPath = $PSScriptRoot

if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
{
    Write-Host "Requesting admin privileges..." -ForegroundColor Yellow
    $currentRuntime = (Get-Process -Id $PID).Path
    $psArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""

    if (Get-Command wt -ErrorAction SilentlyContinue)
    {
        Start-Process -FilePath wt -ArgumentList "new-tab --title `"Setup`" `"$currentRuntime`" $psArgs" -Verb RunAs
    }
    else
    {
        Start-Process -FilePath $currentRuntime -ArgumentList $psArgs -Verb RunAs
    }
    exit
}

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
. "$ConfigPath\helpers\winget-apps.ps1"

Write-Host "`n>Winget Packages" -ForegroundColor Blue

foreach ($app in (Get-WingetApps))
{
    Write-Host "`n--- $app ---" -ForegroundColor DarkGray
    winget install --id $app --source winget --silent --accept-package-agreements --accept-source-agreements
}

Write-Host "`n>PowerShell Modules" -ForegroundColor Blue

foreach ($module in @("Microsoft.WinGet.Client", "Terminal-Icons"))
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
        Write-Error "Failed to set symlink at '$Path'. Error: $($_.Exception.Message)"
    }
}

$HomeSourceRoot = Join-Path $ConfigPath "home"

foreach ($item in (Get-ChildItem -Path $HomeSourceRoot -Recurse -File)) {
    $relativePath = $item.FullName.Substring($HomeSourceRoot.Length + 1)
    $destPath = Join-Path $HOME $relativePath
    Write-Host "`n>Linking: $relativePath" -ForegroundColor Blue
    Set-Symlink -Path $destPath -Target $item.FullName
}

function Set-RegistryValues {
    param([string]$SourcePath, [string]$RegPath)

    try {
        # New-Item -Force on a path that already exists wipes ALL of that key's
        # existing values and subkeys - only call it when the key is genuinely new.
        if (-not (Test-Path $RegPath)) {
            New-Item -Path $RegPath -Force | Out-Null
        }

        $json = Get-Content $SourcePath -Raw | ConvertFrom-Json
        foreach ($prop in $json.values.PSObject.Properties) {
            $name  = $prop.Name
            $value = $prop.Value
            # "Name:Type" or "Name:Type:Default" - the optional 3rd part is only
            # used by reset (to restore an important value instead of deleting it).
            $parts      = $name -split ':', 3
            $keyName    = $parts[0]
            $typeSuffix = if ($parts.Count -gt 1) { $parts[1] } else { 'String' }

            switch ($typeSuffix) {
                { $_ -in 'DWord', 'Bool' } {
                    New-ItemProperty -Path $RegPath -Name $keyName -Value ([int]$value) -PropertyType DWord -Force | Out-Null
                }
                'Json' {
                    $jsonStr = $value | ConvertTo-Json -Compress -Depth 10
                    New-ItemProperty -Path $RegPath -Name $keyName -Value $jsonStr -PropertyType String -Force | Out-Null
                }
                Default {
                    New-ItemProperty -Path $RegPath -Name $keyName -Value ([string]$value) -PropertyType String -Force | Out-Null
                }
            }
        }
        Write-Host "Registry values applied successfully to: $RegPath" -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to apply registry values to ${RegPath}: $($_.Exception.Message)"
    }
}

$RegistrySourceRoot = Join-Path $ConfigPath "registry"
$RegistryHives = @('HKLM', 'HKCU')

foreach ($hive in $RegistryHives) {
    $HiveSourceRoot = Join-Path $RegistrySourceRoot $hive
    if (-not (Test-Path $HiveSourceRoot)) { continue }

    foreach ($file in (Get-ChildItem -Path $HiveSourceRoot -Recurse -Filter "values.json")) {
        $regPath = $file.DirectoryName.Substring($RegistrySourceRoot.Length + 1) -replace '^([^\\]+)\\', '$1:\'
        Write-Host "`n> $regPath" -ForegroundColor Blue
        Set-RegistryValues -SourcePath $file.FullName -RegPath $regPath
    }
}

# ==============================================================================
# 5. ASSETS & THEMING
# ==============================================================================
Write-Host "`n> Installing Martian Mono Nerd Font" -ForegroundColor Blue

try {
    $fontZipUrl  = "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/MartianMono.zip"
    $fontTempDir = Join-Path $env:TEMP "MartianMonoNerdFont"
    $fontZipPath = Join-Path $env:TEMP "MartianMono.zip"

    Invoke-WebRequest -Uri $fontZipUrl -OutFile $fontZipPath -UseBasicParsing
    Expand-Archive -Path $fontZipPath -DestinationPath $fontTempDir -Force

    $fontsRegPath   = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts"
    $windowsFontDir = "$env:WINDIR\Fonts"
    $fontFiles      = Get-ChildItem -Path $fontTempDir -Include "*.ttf", "*.otf" -Recurse

    foreach ($font in $fontFiles) {
        $destPath = Join-Path $windowsFontDir $font.Name
        
        if (-not (Test-Path $destPath)) {
            Copy-Item -Path $font.FullName -Destination $destPath -Force
        }

        $fontName = [System.IO.Path]::GetFileNameWithoutExtension($font.Name)
        $fontType = if ($font.Extension -eq ".otf") { "OpenType" } else { "TrueType" }
        $regName  = "$fontName ($fontType)"

        if (-not (Get-ItemProperty -Path $fontsRegPath -Name $regName -ErrorAction SilentlyContinue)) {
            New-ItemProperty -Path $fontsRegPath -Name $regName -Value $font.Name -PropertyType String -Force | Out-Null
            Write-Host "Registered: $($font.Name)" -ForegroundColor Gray
        }
    }

    Remove-Item $fontZipPath, $fontTempDir -Recurse -Force
    Write-Host "Martian Mono Nerd Font setup complete." -ForegroundColor Green
}
catch {
    Write-Error "Font installation failed: $($_.Exception.Message)"
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
    Write-Error "Failed to deploy Nord theme fragment: $($_.Exception.Message)"
}

Write-Host "`n> Syncing Wallpapers" -ForegroundColor Blue

$wallpaperDst = Join-Path ([Environment]::GetFolderPath("MyPictures")) "windows-config-wallpapers"
$repoUrl      = "https://github.com/jehan593/my-wallpapers.git"

if (-not (Test-Path $wallpaperDst)) {
    Write-Host "Cloning repository..." -ForegroundColor Gray
    git clone --depth 1 $repoUrl $wallpaperDst
} else {
    Write-Host "Updating repository..." -ForegroundColor Gray
    git -C $wallpaperDst pull --rebase --autostash
}

# ==============================================================================
# 6. TOOLS & SCRIPTS
# ==============================================================================
Write-Host "`n> Wireproxy Manager" -ForegroundColor Blue

Write-Host "Installing/Updating wireproxy via Go..." -ForegroundColor Gray
go install github.com/windtf/wireproxy/cmd/wireproxy@latest

if ($LASTEXITCODE -eq 0) {
    Write-Host "wireproxy installed successfully" -ForegroundColor Green
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
Write-Host " • Wallpapers cloned to: Pictures\windows-config-wallpapers" -ForegroundColor Gray
Write-Host " • Please restart your terminal application to apply active PATH environment changes." -ForegroundColor Gray
Write-Host ""

Pause