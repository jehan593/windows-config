# ==============================================================================
# 1. ENVIRONMENT & INITIALIZATION
# ==============================================================================
$ENV:STARSHIP_CONFIG = "$HOME\windows-config\starship.toml"
$env:FZF_DEFAULT_OPTS = @(
    '--exact'
    '--color=bg+:#3b4252,bg:#2e3440,spinner:#81a1c1'
    '--color=hl:#c2a166,fg:#d8dee9,header:#5e81ac'
    '--color=info:#b48ead,pointer:#88c0d0,marker:#ebcb8b'
    '--color=fg+:#e5e9f0,prompt:#81a1c1,hl+:#ebcb8b'
) -join ' '

# Initialize Starship Prompt
$starshipCache = "$env:TEMP\starship_init.ps1"
if (-not (Test-Path $starshipCache)) {
    &starship init powershell | Set-Content $starshipCache
}
. $starshipCache

if (Get-Command zoxide -ErrorAction SilentlyContinue) {
    (&zoxide init powershell | Out-String) | Invoke-Expression
}

# ==============================================================================
# 2. PROFILE MANAGEMENT
# ==============================================================================
function reload {
    Write-Host "Restarting PowerShell session..." -ForegroundColor Cyan
    $exe = if ($PSEdition -eq "Core") { "pwsh" } else { "powershell" }
    & $exe
    exit
}

function conf {
    $myFolder = "$HOME\windows-config"
    if (-not (Test-Path $myFolder)) {
        Write-Host "Config folder not found: $myFolder" -ForegroundColor Red
        return
    }
    if (Get-Command codium -ErrorAction SilentlyContinue) {
        codium $myFolder
    } else {
        Write-Host "VSCodium (codium) not found in PATH." -ForegroundColor Red
    }
}

# ==============================================================================
# 3. CORE UTILITIES (INTERNAL)
# ==============================================================================
function Test-Admin {
    $user = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$user).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Elevated {
    param([string]$Command)
    $exe = if ($PSEdition -eq "Core") { "pwsh" } else { "powershell" }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command))
    Write-Host "Elevating to Administrator for: $Command..." -ForegroundColor Cyan
    Start-Process wt -Verb RunAs -ArgumentList "-p `"PowerShell`" $exe -NoExit -EncodedCommand $encoded"
}

# ==============================================================================
# 4. QUICK UTILITIES
# ==============================================================================
function rr {
    $lastCommand = Get-History -Count 1
    if ($lastCommand) {
        $cmdString = $lastCommand.CommandLine
        Write-Host "Elevating: $cmdString" -ForegroundColor Cyan
        Invoke-Elevated -Command $cmdString
    } else {
        Write-Host "No history found." -ForegroundColor Red
    }
}

function cleanup {
    if (-not (Test-Admin)) { Invoke-Elevated -Command "cleanup"; return }
    Write-Host "--- Starting System Cleanup ---" -ForegroundColor Cyan

    Write-Host "[1/3] Cleaning Windows Update Store (Dism)..." -ForegroundColor Yellow
    dism.exe /online /Cleanup-Image /StartComponentCleanup

    Write-Host "[2/3] Running Disk Cleanup (C:)..." -ForegroundColor Yellow
    cleanmgr.exe /d C: /VERYLOWDISK

    Write-Host "[3/3] Emptying Temp Folders..." -ForegroundColor Yellow
    $tempPaths = @($env:TEMP, "$env:SystemRoot\Temp")
    foreach ($path in $tempPaths) {
        $before = (Get-ChildItem -Path $path -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        Get-ChildItem -Path $path -Recurse -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        $after = (Get-ChildItem -Path $path -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        $freed = [math]::Round(($before - $after) / 1MB, 2)
        Write-Host "  Freed ~${freed}MB from $path" -ForegroundColor DarkGray
    }

    Write-Host "Cleanup Complete!" -ForegroundColor Green
}

function termux {
    param (
        [Parameter(Mandatory=$true)][string]$EndIP,
        [string]$User = "u0_a310",
        [string]$Port = "8022",
        [string]$BaseIP = "192.168.8."
    )
    if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
        Write-Host "ssh not found in PATH." -ForegroundColor Red
        return
    }
    $targetIP = if ($EndIP -match "\.") { $EndIP } else { $BaseIP + $EndIP }
    Write-Host "Connecting to Termux at $targetIP..." -ForegroundColor Cyan
    ssh -p $Port "$User@$targetIP"
}

# ==============================================================================
# 5. MAINTENANCE & UPDATES
# ==============================================================================
function upall {
    if (-not (Test-Admin)) { Invoke-Elevated -Command "upall"; return }
    Write-Host "--- Starting Full System Upgrade ---" -ForegroundColor Cyan
    Write-Host "`n[1/4] Winget Apps" -ForegroundColor Magenta; upa
    Write-Host "`n[2/4] Firefox (Betterfox)" -ForegroundColor Magenta; upf
    Write-Host "`n[3/4] Microsoft Store" -ForegroundColor Magenta; ups
    Write-Host "`n[4/4] Windows Update" -ForegroundColor Magenta; upw
    Write-Host "`n--- Full System Upgrade Complete ---" -ForegroundColor Cyan
}

function cup {
    if (-not (Test-Admin)) { Invoke-Elevated -Command "cup"; return }
    Write-Host "--- Checking for Updates ---" -ForegroundColor Cyan
    Write-Host "`n[1/3] Winget" -ForegroundColor Magenta; winget upgrade
    Write-Host "`n[2/3] Store Apps" -ForegroundColor Magenta
    if (Get-Command store -ErrorAction SilentlyContinue) { "n" | store updates }
    else { Write-Host "Command 'store' not found." -ForegroundColor Gray }
    Write-Host "`n[3/3] Windows" -ForegroundColor Magenta
    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $updates = $session.CreateUpdateSearcher().Search("IsInstalled=0").Updates
        if ($updates.Count -eq 0) {
            Write-Host "No Windows updates available." -ForegroundColor Green
        } else {
            Write-Host "$($updates.Count) update(s) available:" -ForegroundColor Yellow
            $updates | ForEach-Object { Write-Host "  -> $($_.Title)" }
        }
    } catch {
        Write-Host "Failed to query Windows Update: $_" -ForegroundColor Red
    }
}

function upa {
    if (-not (Test-Admin)) { Invoke-Elevated -Command "upa"; return }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host "winget not found in PATH." -ForegroundColor Red
        return
    }
    Write-Host "Upgrading all packages..." -ForegroundColor Cyan
    winget upgrade --all
}

function upw {
    if (-not (Test-Admin)) { Invoke-Elevated -Command "upw"; return }

    $pausePath = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"
    if (Get-ItemProperty -Path $pausePath -Name "PauseUpdatesExpiryTime" -ErrorAction SilentlyContinue) {
        Write-Host "Updates paused. Resuming temporarily..." -ForegroundColor Yellow
        Remove-ItemProperty -Path $pausePath -Name "PauseUpdatesExpiryTime" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $pausePath -Name "PauseFeatureUpdatesStartTime" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $pausePath -Name "PauseQualityUpdatesStartTime" -ErrorAction SilentlyContinue
    }

    try {
        $session  = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()

        Write-Host "Searching for updates..." -ForegroundColor Cyan
        $updates = $searcher.Search("IsInstalled=0").Updates

        if ($updates.Count -eq 0) {
            Write-Host "No updates available." -ForegroundColor Green
            return
        }

        Write-Host "$($updates.Count) update(s) found. Downloading..." -ForegroundColor Yellow
        $downloader = $session.CreateUpdateDownloader()
        for ($i = 0; $i -lt $updates.Count; $i++) {
            $single = New-Object -ComObject Microsoft.Update.UpdateColl
            $single.Add($updates.Item($i)) | Out-Null
            $downloader.Updates = $single
            Write-Host "  Downloading ($($i+1)/$($updates.Count)): $($updates.Item($i).Title)" -ForegroundColor Gray
            $downloader.Download()
            Write-Host "  Done" -ForegroundColor Green
        }

        Write-Host "Installing..." -ForegroundColor Cyan
        $installer = $session.CreateUpdateInstaller()
        $installer.Updates = $updates
        $result = $installer.Install()

        Write-Host "`n=== Results ===" -ForegroundColor Cyan
        for ($i = 0; $i -lt $updates.Count; $i++) {
            $code = $result.GetUpdateResult($i).ResultCode
            $status = switch($code) {
                2 { "Installed" }
                3 { "Installed with errors" }
                4 { "Failed" }
                5 { "Aborted" }
                default { "Unknown" }
            }
            $color = switch($code) {
                2 { "Green" }
                3 { "Yellow" }
                4 { "Red" }
                5 { "Red" }
                default { "Gray" }
            }
            Write-Host "$status -- $($updates.Item($i).Title)" -ForegroundColor $color
        }

        if ($result.RebootRequired) {
            Write-Host "`nReboot required to complete installation." -ForegroundColor Red
        }
    } catch {
        Write-Host "Failed to access Windows Update: $_" -ForegroundColor Red
    }
}

function ups {
    if (Get-Command store -ErrorAction SilentlyContinue) {
        Write-Host "Updating Store apps..." -ForegroundColor Cyan
        store updates --apply
    } else {
        Write-Host "Command 'store' not found." -ForegroundColor Gray
    }
}

function upf {
    $url = "https://raw.githubusercontent.com/yokoffing/Betterfox/main/user.js"
    $profilesPath = "$env:APPDATA\Mozilla\Firefox\Profiles"
    $prefs = @(
        '',
        '// --- Custom Overrides ---',
        'user_pref("browser.search.suggest.enabled", true);',
        'user_pref("browser.contentblocking.category", "");',
        'user_pref("privacy.globalprivacycontrol.enabled", false);',
        'user_pref("gfx.webrender.software", true);'
    )

    if (-not (Test-Path $profilesPath)) {
        Write-Host "Firefox profiles not found." -ForegroundColor Red
        return
    }

    $profiles = Get-ChildItem -Path $profilesPath -Directory
    if ($profiles.Count -eq 0) {
        Write-Host "No Firefox profiles found." -ForegroundColor Red
        return
    }

    foreach ($prof in $profiles) {
        $userFilePath = Join-Path $prof.FullName "user.js"
        Write-Host "Updating profile: $($prof.Name)..." -ForegroundColor Cyan
        try {
            Invoke-WebRequest -Uri $url -OutFile $userFilePath -UseBasicParsing -ErrorAction Stop
            Add-Content -Path $userFilePath -Value ($prefs -join "`n")
            Write-Host "Successfully updated: $userFilePath" -ForegroundColor Green
        } catch {
            Write-Host "Failed to update $($prof.Name): $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

function upc {
    $configPath = "$HOME\windows-config"
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Host "git not found in PATH." -ForegroundColor Red
        return
    }
    if (-not (Test-Path $configPath)) {
        Write-Host "Config folder not found: $configPath" -ForegroundColor Red
        return
    }
    Write-Host "Checking for config updates..." -ForegroundColor Cyan
    git -C $configPath pull --rebase --autostash
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Configs are up to date!" -ForegroundColor Green
        reload
    } else {
        Write-Host "Update failed. Check for merge conflicts." -ForegroundColor Red
    }
}

# ==============================================================================
# 6. INTERACTIVE TOOLS (FZF) & KEYBINDINGS
# ==============================================================================
function inst {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host "winget not found in PATH." -ForegroundColor Red; return
    }
    if (-not (Get-Command fzf -ErrorAction SilentlyContinue)) {
        Write-Host "fzf not found in PATH." -ForegroundColor Red; return
    }

    $selected = winget search -q "." | Out-String -Stream |
        Where-Object { $_ -match '^\S+' -and $_ -notmatch 'Name|---' } |
        fzf --exact --multi --reverse --header "Select apps to INSTALL"

    if (-not $selected) { Write-Host "No apps selected." -ForegroundColor Gray; return }

    foreach ($item in $selected) {
        $id = ($item -split '\s{2,}')[1]
        if ($id) {
            Write-Host "Installing: $id" -ForegroundColor Green
            winget install --id $id.Trim() --exact
        }
    }
}

function uninst {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host "winget not found in PATH." -ForegroundColor Red; return
    }
    if (-not (Get-Command fzf -ErrorAction SilentlyContinue)) {
        Write-Host "fzf not found in PATH." -ForegroundColor Red; return
    }

    $selected = winget list | Out-String -Stream |
        Where-Object { $_ -match '^\S+' -and $_ -notmatch 'Name|---' } |
        fzf --exact --multi --reverse --header "Select apps to UNINSTALL"

    if (-not $selected) { Write-Host "No apps selected." -ForegroundColor Gray; return }

    foreach ($item in $selected) {
        $name = ($item -split '\s{2,}', 2)[0]
        if ($name) {
            Write-Host "Removing: $name" -ForegroundColor Cyan
            winget uninstall --name "$($name.Trim())" --exact
        }
    }
}

function up {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host "winget not found in PATH." -ForegroundColor Red; return
    }
    if (-not (Get-Command fzf -ErrorAction SilentlyContinue)) {
        Write-Host "fzf not found in PATH." -ForegroundColor Red; return
    }

    $raw = winget upgrade --accept-source-agreements | Out-String -Stream
    $headerLine = $raw | Where-Object { $_ -like "*Name*Id*Version*" } | Select-Object -First 1

    if (-not $headerLine) {
        if ($raw -match "No installed package") { Write-Host "Everything is up to date!" -ForegroundColor Green }
        else { Write-Host "Error: Could not parse winget output." -ForegroundColor Red }
        return
    }

    $idStart      = $headerLine.IndexOf("Id")
    $versionStart = $headerLine.IndexOf("Version")
    $list = $raw | Where-Object {
        $line = $_.Trim()
        $line -ne "" -and $line -notmatch '^-+$' -and $line -notmatch 'Name\s+Id' -and $line.Length -gt $idStart
    }

    if (-not $list) { Write-Host "No updates found in the list." -ForegroundColor Green; return }

    $selected = $list | fzf --exact --multi --reverse --header "Select apps to UPDATE"
    if (-not $selected) { Write-Host "No apps selected." -ForegroundColor Gray; return }

    foreach ($line in $selected) {
        if ($line.Length -ge $versionStart) {
            $id = $line.Substring($idStart, ($versionStart - $idStart)).Trim()
            if ($id) {
                Write-Host "`nUpdating: $id" -ForegroundColor Yellow
                winget upgrade --id "$id" --exact
            }
        }
    }
}

function la {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host "winget not found in PATH." -ForegroundColor Red; return
    }
    if (-not (Get-Command fzf -ErrorAction SilentlyContinue)) {
        Write-Host "fzf not found in PATH." -ForegroundColor Red; return
    }

    $selected = winget list | Out-String -Stream |
        Where-Object { $_ -match '^\S+' -and $_ -notmatch 'Name|---' } |
        fzf --exact --reverse --header "Search installed apps"

    if (-not $selected) { Write-Host "No app selected." -ForegroundColor Gray; return }

    $id = ($selected -split '\s{2,}')[1]
    if ($id) {
        Write-Host "`nFetching info for: $id" -ForegroundColor Yellow
        winget show --id $id.Trim() --exact
    }
}

Set-PSReadLineKeyHandler -Key "Ctrl+h" -ScriptBlock {
    if (-not (Get-Command fzf -ErrorAction SilentlyContinue)) {
        Write-Host "fzf not found in PATH." -ForegroundColor Red; return
    }

    $historyFile = (Get-PSReadLineOption).HistorySavePath
    if (-not (Test-Path $historyFile)) {
        Write-Host "No history file found." -ForegroundColor Red; return
    }

    $content = Get-Content $historyFile
    [Array]::Reverse($content)

    $selected = $content |
        Select-Object -Unique |
        fzf --exact --reverse --height 40% --header "History Search"

    if ($selected) {
        [Microsoft.PowerShell.PSConsoleReadLine]::DeleteLine()
        [Microsoft.PowerShell.PSConsoleReadLine]::Insert($selected.Trim())
    }
}

function ff {
    param(
        [Parameter(Position=0)]
        [string]$Path = "C:\"
    )

    if (-not (Get-Command fd -ErrorAction SilentlyContinue)) {
        Write-Host "fd not found in PATH." -ForegroundColor Red; return
    }
    if (-not (Get-Command fzf -ErrorAction SilentlyContinue)) {
        Write-Host "fzf not found in PATH." -ForegroundColor Red; return
    }

    $SearchPath = Resolve-Path $Path -ErrorAction SilentlyContinue
    if (-not $SearchPath) {
        Write-Host "Path not found: $Path" -ForegroundColor Red; return
    }

    $selection = fd . $SearchPath --hidden --color never `
        --exclude "Windows" |
        fzf --exact --layout=reverse `
            --height=40% `
            --header "Searching: $SearchPath"

    if (-not $selection) { return }

    if (Test-Path $selection -PathType Container) {
        Start-Process explorer $selection
    } else {
        Start-Process $selection
    }
}

# ==============================================================================
# 7. THIRD PARTY TOOLS
# ==============================================================================

function ctt {
    if (-not (Test-Admin)) { Invoke-Elevated -Command "ctt"; return }
    Write-Host "Launching Chris Titus Tech Toolbox..." -ForegroundColor Cyan
    irm https://christitus.com/win | iex
}

function massgrave {
    if (-not (Test-Admin)) { Invoke-Elevated -Command "massgrave"; return }
    Write-Host "Launching Massgrave Activation Tool..." -ForegroundColor Cyan
    irm https://get.activated.win | iex
}

# ==============================================================================
# 6. MEDIA
# ==============================================================================

function pirith {
    $dir = "$HOME\Music\pirith"
    if (-not (Get-Command mpv -ErrorAction SilentlyContinue)) {
        Write-Host "mpv not found in PATH." -ForegroundColor Red; return
    }
    if (-not (Test-Path $dir)) {
        Write-Host "Pirith folder not found: $dir" -ForegroundColor Red; return
    }

    Write-Host "󰎆 Select to Play" -ForegroundColor Cyan
    Write-Host "1) pirith_udasana.mp3"
    Write-Host "2) pirith_sawasa.mp3"
    $choice = Read-Host "Selection"

    switch ($choice) {
        "1" { mpv "$dir\pirith_udasana.mp3" }
        "2" { mpv "$dir\pirith_sawasa.mp3" }
        default { Write-Host "Invalid Choice!" -ForegroundColor Red }
    }
}

# ==============================================================================
# 9. INFO & DOCUMENTATION
# ==============================================================================
function info {
    Write-Host "`n--- Profile Commands ---" -ForegroundColor Cyan

    Write-Host "`n [Profile Management]" -ForegroundColor Yellow
    Write-Host "  conf    - Edit dotfiles folder (VSCodium)"
    Write-Host "  reload  - Reload profile changes"

    Write-Host "`n [System & Elevation]" -ForegroundColor Yellow
    Write-Host "  rr      - Re-run last command as Admin"
    Write-Host "  cleanup - Run Windows Disk Cleanup"
    Write-Host "  termux  - Connect to Termux (requires IP/ID)"
    Write-Host "  ctt      - Launch Chris Titus Tech Toolbox"
    Write-Host "  massgrave - Launch Massgrave Activation Tool"

    Write-Host "`n [Updates & Apps]" -ForegroundColor Yellow
    Write-Host "  upall   - Full upgrade (Winget, Store, Windows, Firefox)"
    Write-Host "  cup     - Check for updates (Winget, Store, Windows)"
    Write-Host "  upa     - Winget: Upgrade all"
    Write-Host "  ups     - Store: Update all"
    Write-Host "  upw     - Windows: Install all updates"
    Write-Host "  upf     - Firefox: Apply Betterfox user.js"
    Write-Host "  upc     - Pull config updates from GitHub"

    Write-Host "`n [Interactive (FZF)]" -ForegroundColor Yellow
    Write-Host "  ff      - Fast file/folder search (fd + fzf)"
    Write-Host "  inst    - Interactive search & install"
    Write-Host "  uninst  - Interactive search & uninstall"
    Write-Host "  up      - Interactive search & upgrade"
    Write-Host "  la      - Search installed apps & show details"
    Write-Host "  Ctrl+h  - Filtered command history search"

    Write-Host "`n [Media]" -ForegroundColor Yellow
    Write-Host "  pirith  - Play pirith audio"
    Write-Host "------------------------`n"
}
# Import the Chocolatey Profile that contains the necessary code to enable
# tab-completions to function for `choco`.
# Be aware that if you are missing these lines from your profile, tab completion
# for `choco` will not function.
# See https://ch0.co/tab-completion for details.
$ChocolateyProfile = "$env:ChocolateyInstall\helpers\chocolateyProfile.psm1"
if (Test-Path($ChocolateyProfile)) {
  Import-Module "$ChocolateyProfile"
}
