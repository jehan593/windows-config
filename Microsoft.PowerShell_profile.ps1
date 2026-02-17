# ==============================================================================
# 1. ENVIRONMENT & INITIALIZATION
# ==============================================================================
$ENV:STARSHIP_CONFIG = "$HOME\windows-config\starship.toml"
# Added --exact to default opts to ensure all fzf instances use exact matching
$env:FZF_DEFAULT_OPTS = '--exact --color="bg+:#3b4252,bg:#2e3440,spinner:#81a1c1,hl:#c2a166,fg:#d8dee9,header:#5e81ac,info:#b48ead,pointer:#88c0d0,marker:#ebcb8b,fg+:#e5e9f0,prompt:#81a1c1,hl+:#ebcb8b"'

# Load Modules
Import-Module PSWindowsUpdate -ErrorAction SilentlyContinue

# Initialize Starship Prompt
if (Get-Command starship -ErrorAction SilentlyContinue) {
    Invoke-Expression (&starship init powershell)
}
(&zoxide init powershell | Out-String) | Invoke-Expression

# ==============================================================================
# 2. PROFILE MANAGEMENT
# ==============================================================================
function conf {
    Write-Host "Opening PowerShell Profile..." -ForegroundColor Cyan
    notepad $PROFILE
}

function reload {
    Write-Host "Restarting PowerShell session..." -ForegroundColor Cyan
    if ($PSEdition -eq "Core") {
        pwsh
        exit
    } else {
        powershell
        exit
    }
}

function confc {
    # Replace the path below with your specific folder
    $myFolder = "$HOME\windows-config"

    if (Get-Command codium -ErrorAction SilentlyContinue) {
        codium $myFolder
    } else {
        Write-Host "VCodium (codium) not found in PATH." -ForegroundColor Red
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
    Write-Host "Elevating to Administrator for: $Command..." -ForegroundColor Cyan
    $wtArgs = "-p `"PowerShell`" powershell -NoExit -Command `"$Command`""
    Start-Process wt -Verb RunAs -ArgumentList $wtArgs
}

# ==============================================================================
# 4. QUICK UTILITIES
# ==============================================================================
function rr {
    $lastCommand = Get-History -Count 1
  
    if ($lastCommand) {
        $cmdString = $lastCommand.CommandLine
    
        Write-Host "Elevating: $cmdString" -ForegroundColor Cyan
    
        $bytes = [System.Text.Encoding]::Unicode.GetBytes($cmdString)
        $encoded = [Convert]::ToBase64String($bytes)
  
        Invoke-Elevated -Command "powershell -NoProfile -EncodedCommand $encoded" *> $null
    } else {
        Write-Host "No history found." -ForegroundColor Red
    }
}

function cleanup {
    if (-not (Test-Admin)) { Invoke-Elevated -Command "cleanup"; return }
    Write-Host "--- Starting System Cleanup ---" -ForegroundColor Cyan
    
    Write-Host "[1/3] Cleaning Windows Update Store (Dism)..." -ForegroundColor Yellow
    dism.exe /online /Cleanup-Image /StartComponentCleanup /Quiet

    Write-Host "[2/3] Running Disk Cleanup (C:)..." -ForegroundColor Yellow
    cleanmgr.exe /d C: /VERYLOWDISK

    Write-Host "[3/3] Emptying Temp Folders..." -ForegroundColor Yellow
    $tempPaths = @($env:TEMP, "$env:SystemRoot\Temp")
    foreach ($path in $tempPaths) {
        Get-ChildItem -Path $path -Recurse -ErrorAction SilentlyContinue | 
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host "Cleanup Complete!" -ForegroundColor Green
}

function termux {
    param ([Parameter(Mandatory=$true)][string]$EndIP)
    $user = "u0_a310"
    $port = "8022"
    $baseIP = "192.168.8." 

    $targetIP = if ($EndIP -match "\.") { $EndIP } else { $baseIP + $EndIP }
    Write-Host "Connecting to Termux at $targetIP..." -ForegroundColor Cyan
    ssh -p $port "$user@$targetIP"
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
}

function cup {
    if (-not (Test-Admin)) { Invoke-Elevated -Command "cup"; return }
    Write-Host "--- Checking for Updates ---" -ForegroundColor Cyan
    Write-Host "`n[1/3] Winget" -ForegroundColor Magenta; winget upgrade
    Write-Host "`n[2/3] Store Apps" -ForegroundColor Magenta
    if (Get-Command store -ErrorAction SilentlyContinue) { "n" | store updates } 
    else { Write-Host "Command 'store' not found." -ForegroundColor Gray }
    Write-Host "`n[3/3] Windows" -ForegroundColor Magenta; Get-WindowsUpdate
}

function upa { winget upgrade --all }

function upw {
    if (-not (Test-Admin)) { Invoke-Elevated -Command "upw"; return }
    Install-WindowsUpdate -AcceptAll -Install -AutoReboot:$false
}

function ups {
    if (Get-Command store -ErrorAction SilentlyContinue) { store updates --apply } 
    else { Write-Host "Command 'store' not found." -ForegroundColor Gray }
}

function upf {
    $url = "https://raw.githubusercontent.com/yokoffing/Betterfox/main/user.js"
    $profilesPath = "$env:APPDATA\Mozilla\Firefox\Profiles"
    $prefs = @('', '// --- Custom Overrides ---', 'user_pref("browser.search.suggest.enabled", true);', 'user_pref("browser.contentblocking.category", "");', 'user_pref("privacy.globalprivacycontrol.enabled", false);', 'user_pref("gfx.webrender.software", true);')

    if (-not (Test-Path $profilesPath)) { Write-Host "Firefox profiles not found." -ForegroundColor Red; return }

    $profiles = Get-ChildItem -Path $profilesPath -Directory
    foreach ($prof in $profiles) {
        $userFilePath = Join-Path $prof.FullName "user.js"
        Write-Host "Updating profile: $($prof.Name)..." -ForegroundColor Cyan
        try {
            Invoke-WebRequest -Uri $url -OutFile $userFilePath -ErrorAction Stop
            Add-Content -Path $userFilePath -Value $prefs
            Write-Host "Successfully updated: $userFilePath" -ForegroundColor Green
        } catch {
            Write-Host "Failed to update $($prof.Name): $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

function confup {
    Write-Host "Checking for config updates..." -ForegroundColor Cyan
    git -C "$HOME\windows-config" pull --rebase --autostash
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "🚀 configs are up to date!" -ForegroundColor Green
        reload
    } else {
        Write-Host "❌ Update failed. Check for merge conflicts." -ForegroundColor Red
    }
}

# ==============================================================================
# 6. INTERACTIVE TOOLS (FZF) & KEYBINDINGS
# ==============================================================================
function inst {
    $selected = winget search -q "." | Out-String -Stream | 
        Where-Object { $_ -match '^\S+' -and $_ -notmatch 'Name|---' } |
        fzf --exact --multi --reverse --header "Select apps to INSTALL"

    foreach ($item in $selected) {
        $id = ($item -split '\s{2,}')[1]
        if ($id) { 
            Write-Host "Installing: $id" -ForegroundColor Green
            winget install --id $id.Trim() --exact 
        }
    }
}

function uninst {
    $selected = winget list | Out-String -Stream | 
        Where-Object { $_ -match '^\S+' -and $_ -notmatch 'Name|---' } |
        fzf --exact --multi --reverse --header "Select apps to UNINSTALL"

    foreach ($item in $selected) {
        $name = ($item -split '\s{2,}', 2)[0]
        if ($name) { 
            Write-Host "Removing: $name" -ForegroundColor Cyan
            winget uninstall --name "$($name.Trim())" --exact
        }
    }
}

function up {
    $raw = winget upgrade --accept-source-agreements | Out-String -Stream
    $headerLine = $raw | Where-Object { $_ -like "*Name*Id*Version*" } | Select-Object -First 1

    if (-not $headerLine) {
        if ($raw -match "No installed package") { Write-Host "Everything is up to date!" -ForegroundColor Green } 
        else { Write-Host "Error: Could not parse winget output." -ForegroundColor Red }
        return
    }

    $idStart = $headerLine.IndexOf("Id")
    $versionStart = $headerLine.IndexOf("Version")
    $list = $raw | Where-Object { 
        $line = $_.Trim()
        $line -ne "" -and $line -notmatch '^-+$' -and $line -notmatch 'Name\s+Id' -and $line.Length -gt $idStart
    }

    if (-not $list) { Write-Host "No updates found in the list." -ForegroundColor Green; return }

    $selected = $list | fzf --exact --multi --reverse --header "Select apps to UPDATE"
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
    $selected = winget list | Out-String -Stream | 
        Where-Object { $_ -match '^\S+' -and $_ -notmatch 'Name|---' } |
        fzf --exact --reverse --header "Search installed apps"

    if ($selected) {
        $id = ($selected -split '\s{2,}')[1]
        if ($id) { 
            Write-Host "`nFetching info for: $id" -ForegroundColor Yellow
            winget show --id $id.Trim() --exact
        }
    }
}

Set-PSReadLineKeyHandler -Key "Ctrl+h" -ScriptBlock {
    $historyFile = (Get-PSReadLineOption).HistorySavePath
    if (Test-Path $historyFile) {
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
}

function ff {
    param(
        [Parameter(Mandatory=$false)]
        [string]$Path = "C:\"
    )
    
    $selection = fd --hidden . $Path `
        | fzf --exact --layout=reverse `
              --height=40% `
              --header "Search: $Path (Enter to Open)"

    if ($selection) {
        if (Test-Path $selection -PathType Container) {
            explorer.exe $selection
        } else {
            Invoke-Item $selection
        }
    }
}

# ==============================================================================
# 7. TIME & PROGRESS TOOLS (NERD FONT DOTS)
# ==============================================================================
$dotFull  = [char]0xf111
$dotEmpty = [char]0xf10c

function day {
    $now = Get-Date
    $currentHour = $now.Hour
    Write-Host "Day Progress: Hour $currentHour / 24"
    for ($i = 0; $i -lt 24; $i++) {
        if ($i -lt $currentHour) { Write-Host "$dotFull " -NoNewline }
        elseif ($i -eq $currentHour) { Write-Host "$dotFull " -ForegroundColor Green -NoNewline }
        else { Write-Host "$dotEmpty " -NoNewline }
        if (($i + 1) % 12 -eq 0) { Write-Host "" }
    }
}

function week {
    $now = Get-Date
    $currentDay = [int]$now.DayOfWeek
    if ($currentDay -eq 0) { $currentDay = 7 } 
    Write-Host "Week Progress: Day $currentDay of 7"
    for ($i = 1; $i -le 7; $i++) {
        if ($i -lt $currentDay) { Write-Host "$dotFull " -NoNewline }
        elseif ($i -eq $currentDay) { Write-Host "$dotFull " -ForegroundColor Green -NoNewline }
        else { Write-Host "$dotEmpty " -NoNewline }
    }
    Write-Host ""
}

function month {
    $now = Get-Date
    $currentDay = $now.Day
    $totalDays = [DateTime]::DaysInMonth($now.Year, $now.Month)
    Write-Host "Month Progress: $currentDay / $totalDays days"
    for ($i = 1; $i -le $totalDays; $i++) {
        if ($i -lt $currentDay) { Write-Host "$dotFull " -NoNewline }
        elseif ($i -eq $currentDay) { Write-Host "$dotFull " -ForegroundColor Green -NoNewline }
        else { Write-Host "$dotEmpty " -NoNewline }
    }
    Write-Host ""
}

function year {
    $now = Get-Date
    $currentDay = $now.DayOfYear
    $totalDays = if ([DateTime]::IsLeapYear($now.Year)) { 366 } else { 365 }
    Write-Host "Year $($now.Year) Progress: $currentDay / $totalDays days"
    Write-Host "------------------------------------------------------"
    for ($i = 1; $i -le $totalDays; $i++) {
        if ($i -lt $currentDay) { Write-Host "$dotFull " -NoNewline }
        elseif ($i -eq $currentDay) { Write-Host "$dotFull " -ForegroundColor Green -NoNewline }
        else { Write-Host "$dotEmpty " -NoNewline }
        if ($i % 31 -eq 0) { Write-Host "" }
    }
    Write-Host "`n------------------------------------------------------"
}

function progress { day; Write-Host ""; week; Write-Host ""; month; Write-Host ""; year }

# ==============================================================================
# 8. INFO & DOCUMENTATION
# ==============================================================================
function info {
    Write-Host "`n--- Profile Commands ---" -ForegroundColor Cyan
  
    Write-Host " [Profile Management]" -ForegroundColor Yellow
    Write-Host " conf     - Edit this profile (Notepad)"
    Write-Host " confc     - Edit dotfiles folder (VS Code)"
    Write-Host " reload   - Reload profile changes"

    Write-Host "`n [System & Elevation]" -ForegroundColor Yellow
    Write-Host " rr       - Re-run last command as Admin"
    Write-Host " cleanup  - Run Windows Disk Cleanup"
    Write-Host " termux   - Connect to Termux (requires IP/ID)"
  
    Write-Host "`n [Updates & Apps]" -ForegroundColor Yellow
    Write-Host " upall    - Full upgrade (Winget, Store, Windows, Firefox)"
    Write-Host " cup      - Check for updates (Winget, Store, Windows)"
    Write-Host " upa      - Winget: Upgrade all"
    Write-Host " ups      - Store: Update all"
    Write-Host " upw      - Windows: Install all updates"
    Write-Host " upf      - Firefox: Apply Betterfox user.js"
  
    Write-Host "`n [Interactive (FZF)]" -ForegroundColor Yellow
    Write-Host " ff       - Fast file/folder search (fd + fzf)"
    Write-Host " inst     - Interactive search & install"
    Write-Host " uninst   - Interactive search & uninstall"
    Write-Host " up       - Interactive search & upgrade"
    Write-Host " la       - Search installed apps & show details"
    Write-Host " Ctrl+h   - Filtered command history search"
  
    Write-Host "`n [Time Progress]" -ForegroundColor Yellow
    Write-Host " day/week/month/year - Visual progress trackers"
    Write-Host " progress            - Run all trackers at once"
    Write-Host "------------------------"
}



