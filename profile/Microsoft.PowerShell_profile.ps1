# ==============================================================================
# 1. ENVIRONMENT & INITIALIZATION
# ==============================================================================
$RepoPath = "$HOME\windows-config"
$ENV:STARSHIP_CONFIG = "$RepoPath\configs\starship.toml"

# Nord Theme for FZF
$env:FZF_DEFAULT_OPTS = @(
    '--exact'
    '--color=bg+:#3b4252,bg:#2e3440,spinner:#81a1c1'
    '--color=hl:#c2a166,fg:#d8dee9,header:#5e81ac'
    '--color=info:#b48ead,pointer:#88c0d0,marker:#ebcb8b'
    '--color=fg+:#e5e9f0,prompt:#81a1c1,hl+:#ebcb8b'
) -join ' '

# Generic Cache Function to speed up Shell Start
function Import-CachedCommand {
    param([string]$Command, [string]$CacheName)
    $CacheFile = "$env:TEMP\$CacheName.ps1"
    if (!(Get-Command $Command -ErrorAction SilentlyContinue)) { return }
    $commandPath = (Get-Command $Command).Source
    if (-not (Test-Path $CacheFile) -or (Get-Item $commandPath).LastWriteTime -gt (Get-Item $CacheFile).LastWriteTime) {
        & $Command init powershell | Set-Content $CacheFile -Encoding utf8
    }
    . $CacheFile
}

# Initialize Starship & Zoxide via Cache
Import-CachedCommand -Command "starship" -CacheName "starship_init"
Import-CachedCommand -Command "zoxide"   -CacheName "zoxide_init"

# ==============================================================================
# 2. PROFILE MANAGEMENT
# ==============================================================================
function reload {
    Write-Host "  Restarting PowerShell session..." -ForegroundColor Cyan
    $exe = if ($PSEdition -eq "Core") { "pwsh" } else { "powershell" }
    Start-Process $exe -ArgumentList "-NoExit", "-Command", "Set-Location '$PWD'"
    exit
}

function conf {
    Write-Host "󰨞 Opening Configs..." -ForegroundColor Cyan
    codium $RepoPath
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
    Write-Host "󰮯 Elevating to Administrator..." -ForegroundColor Cyan
    if (Get-Command wt -ErrorAction SilentlyContinue) {
        Start-Process wt -Verb RunAs -ArgumentList "-p `"PowerShell`" $exe -NoExit -EncodedCommand $encoded"
    } else {
        Start-Process $exe -Verb RunAs -ArgumentList "-NoExit", "-EncodedCommand", $encoded
    }
}

function _PrintHeader {
    param([string]$Icon, [string]$Title)
    Write-Host ""
    Write-Host "$Icon  $Title" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkBlue
}

function _PrintFooter {
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`n" -ForegroundColor DarkBlue
}

function _PrintRow {
    param([string]$Icon, [string]$Label, [string]$Value, [string]$Color = "White")
    Write-Host ("│  {0} {1,-12} {2}" -f $Icon, $Label, $Value) -ForegroundColor $Color
}

function _Run {
    param([string]$Label, [scriptblock]$Action)
    try {
        & $Action | Out-Null
        _PrintRow "󰄬" $Label "Done" "Green"
    } catch {
        _PrintRow "󰅙" $Label "Failed" "Red"
    }
}

# ==============================================================================
# 4. QUICK UTILITIES
# ==============================================================================
function rr {
    $lastCommand = Get-History -Count 1
    if ($lastCommand) {
        $cmdString = $lastCommand.CommandLine
        Write-Host "󰁯 Elevating: $cmdString" -ForegroundColor Cyan
        Invoke-Elevated -Command $cmdString
    } else {
        Write-Host " 󱞣 No history found." -ForegroundColor Red
    }
}

function cleanup {
    if (-not (Test-Admin)) { Invoke-Elevated -Command "cleanup"; return }
    _PrintHeader "󰃢" "System Cleanup"
    _Run "Windows Update Store" { dism.exe /online /Cleanup-Image /StartComponentCleanup }
    _Run "Disk Cleanup" { cleanmgr.exe /d C: /VERYLOWDISK }
    _Run "Temp Folders" {
        $tempPaths = @($env:TEMP, "$env:SystemRoot\Temp")
        foreach ($path in $tempPaths) {
            Get-ChildItem -Path $path -Recurse -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    _PrintFooter
}

function termux {
    param (
        [Parameter(Mandatory=$true)][string]$EndIP,
        [string]$User = "u0_a310",
        [string]$Port = "8022",
        [string]$BaseIP = "192.168.8."
    )
    $targetIP = if ($EndIP -match "\.") { $EndIP } else { $BaseIP + $EndIP }
    _PrintHeader "󰄜" "Termux SSH Connection"
    _PrintRow "󰩟" "Target" "$targetIP`:$Port"
    _PrintRow "󰀄" "User" $User
    _PrintFooter
    ssh -p $Port "$User@$targetIP"
}

function open {
    param([string]$Path = ".")
    $resolvedPath = Resolve-Path $Path -ErrorAction SilentlyContinue
    if (-not $resolvedPath) {
        Write-Host " 󱞣 Path not found: $Path" -ForegroundColor Red; return
    }
    Write-Host " 󰝰 Opening Explorer..." -ForegroundColor Cyan
    explorer.exe $resolvedPath
}

# ==============================================================================
# 5. MAINTENANCE & UPDATES
# ==============================================================================
function upall {
    if (-not (Test-Admin)) { Invoke-Elevated -Command "upall"; return }
    upa
    _PrintHeader "󱑢" "Choco Upgrade"
    choco upgrade all -y
    _PrintFooter
    upf
    ups
    upw
}

function cup {
    if (-not (Test-Admin)) { Invoke-Elevated -Command "cup"; return }
    _PrintHeader "󰚰" "Checking for Updates"
    Write-Host ""
    Write-Host "󰏓  Winget" -ForegroundColor Magenta
    winget upgrade
    Write-Host ""
    Write-Host "󰮯  Store Apps" -ForegroundColor Magenta
    if (Get-Command store -ErrorAction SilentlyContinue) { "n" | store updates }
    else { _PrintRow "󰋼" "Store" "Command not found" "Gray" }
    Write-Host ""
    Write-Host " Windows Update" -ForegroundColor Magenta
    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $updates = $session.CreateUpdateSearcher().Search("IsInstalled=0").Updates
        if ($updates.Count -eq 0) {
            _PrintRow "" "Windows" "No updates available" "Green"
        } else {
            _PrintRow "󰚰" "Windows" "$($updates.Count) update(s) available" "Yellow"
            $updates | ForEach-Object { Write-Host "      󱞩 $($_.Title)" }
        }
    } catch {
        _PrintRow "󰅙" "Windows" "Failed to query" "Red"
    }
    _PrintFooter
}

function upa {
    if (-not (Test-Admin)) { Invoke-Elevated -Command "upa"; return }
    _PrintHeader "󰏓" "Winget Upgrade"
    winget upgrade --all
    _PrintFooter
}

function upw {
    if (-not (Test-Admin)) { Invoke-Elevated -Command "upw"; return }

    $pausePath = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"
    if (Get-ItemProperty -Path $pausePath -Name "PauseUpdatesExpiryTime" -ErrorAction SilentlyContinue) {
        Write-Host " 󱠇 Updates paused. Resuming temporarily..." -ForegroundColor Yellow
        Remove-ItemProperty -Path $pausePath -Name "PauseUpdatesExpiryTime" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $pausePath -Name "PauseFeatureUpdatesStartTime" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $pausePath -Name "PauseQualityUpdatesStartTime" -ErrorAction SilentlyContinue
    }

    try {
        $session  = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        _PrintHeader "" "Windows Update"
        _PrintRow "󱎟" "Status" "Searching..." "Cyan"
        $updates = $searcher.Search("IsInstalled=0").Updates

        if ($updates.Count -eq 0) {
            _PrintRow "" "Status" "No updates available" "Green"
            _PrintFooter; return
        }

        _PrintRow "󰚰" "Found" "$($updates.Count) update(s)" "Yellow"
        $downloader = $session.CreateUpdateDownloader()
        for ($i = 0; $i -lt $updates.Count; $i++) {
            $single = New-Object -ComObject Microsoft.Update.UpdateColl
            $single.Add($updates.Item($i)) | Out-Null
            $downloader.Updates = $single
            _PrintRow "󱑢" "Downloading" "($($i+1)/$($updates.Count)) $($updates.Item($i).Title)" "Gray"
            $downloader.Download()
        }

        _PrintRow "󰏔" "Status" "Installing..." "Cyan"
        $installer = $session.CreateUpdateInstaller()
        $installer.Updates = $updates
        $result = $installer.Install()

        for ($i = 0; $i -lt $updates.Count; $i++) {
            $code = $result.GetUpdateResult($i).ResultCode
            $status = switch($code) { 2 {"Installed"} 3 {"Installed with errors"} 4 {"Failed"} 5 {"Aborted"} default {"Unknown"} }
            $color  = switch($code) { 2 {"Green"}     3 {"Yellow"}                4 {"Red"}    5 {"Red"}     default {"Gray"} }
            _PrintRow "󰄬" $status $updates.Item($i).Title $color
        }

        if ($result.RebootRequired) {
            _PrintRow "" "Notice" "Reboot required" "Red"
        }
        _PrintFooter
    } catch {
        _PrintRow "󰅙" "Error" "$_" "Red"
        _PrintFooter
    }
}

function ups {
    if (Get-Command store -ErrorAction SilentlyContinue) {
        _PrintHeader "󰮯" "Store Update"
        store updates --apply
        _PrintFooter
    } else {
        Write-Host " 󰅙 Command 'store' not found." -ForegroundColor Gray
    }
}

function upf {
    $url = "https://raw.githubusercontent.com/yokoffing/Betterfox/main/user.js"
    $overridesPath = "$RepoPath\configs\firefox\user-overrides.js"
    $profilesPath = "$env:APPDATA\Mozilla\Firefox\Profiles"
    _PrintHeader "󰈹" "Firefox Tweaks"

    if (-not (Test-Path $profilesPath)) {
        _PrintRow "󰅙" "Error" "Firefox profiles not found" "Red"; _PrintFooter; return
    }

    $profiles = Get-ChildItem -Path $profilesPath -Directory
    if ($profiles.Count -eq 0) {
        _PrintRow "󰅙" "Error" "No profiles found" "Red"; _PrintFooter; return
    }

    foreach ($prof in $profiles) {
        $userFilePath = Join-Path $prof.FullName "user.js"
        try {
            Invoke-WebRequest -Uri $url -OutFile $userFilePath -UseBasicParsing -ErrorAction Stop
            if (Test-Path $overridesPath) {
                Add-Content -Path $userFilePath -Value "`n// --- Custom Overrides ---"
                Get-Content $overridesPath | Add-Content -Path $userFilePath
            }
            _PrintRow "󰄬" "Applied" $prof.Name "Green"
        } catch {
            _PrintRow "󰅙" "Failed" $prof.Name "Red"
        }
    }
    _PrintFooter
}

function upc {
    _PrintHeader "󰚰" "Config Update"
    git -C $RepoPath pull --rebase --autostash
    if ($LASTEXITCODE -eq 0) {
        _PrintRow "󰊢" "Status" "Configs up to date!" "Green"
        _PrintFooter
        reload
    } else {
        _PrintRow "󰅙" "Status" "Update Failed" "Red"
        _PrintFooter
    }
}

# ==============================================================================
# 6. INTERACTIVE TOOLS (FZF) & KEYBINDINGS
# ==============================================================================
function inst {
    param([string[]]$Id)
    if ($Id) {
        foreach ($i in $Id) {
            Write-Host " 󰐕 Installing: $i" -ForegroundColor Green
            winget install $i
        }
    } else {
        $selected = winget search -q "." | Out-String -Stream |
            Where-Object { $_ -match '^\S+' -and $_ -notmatch 'Name|---' } |
            fzf --exact --multi --reverse --header "󰏓 Select apps to INSTALL (Tab to multi-select)"

        foreach ($item in $selected) {
            $id = ($item -split '\s{2,}')[1]
            if ($id) {
                Write-Host " 󰐕 Installing: $id" -ForegroundColor Green
                winget install --id $id.Trim() --exact
            }
        }
    }
}

function uninst {
    param([string[]]$Id)
    if ($Id) {
        foreach ($i in $Id) {
            Write-Host " 󰛌 Removing: $i" -ForegroundColor Cyan
            winget uninstall $i
        }
    } else {
        $selected = winget list | Out-String -Stream |
            Where-Object { $_ -match '^\S+' -and $_ -notmatch 'Name|---' } |
            fzf --exact --multi --reverse --header "󰏔 Select apps to UNINSTALL (Tab to multi-select)"

        foreach ($item in $selected) {
            $name = ($item -split '\s{2,}', 2)[0]
            if ($name) {
                Write-Host " 󰛌 Removing: $name" -ForegroundColor Cyan
                winget uninstall --name "$($name.Trim())" --exact
            }
        }
    }
}

function up {
    $raw = winget upgrade --accept-source-agreements | Out-String -Stream
    $headerLine = $raw | Where-Object { $_ -like "*Name*Id*Version*" } | Select-Object -First 1

    if (-not $headerLine) {
        if ($raw -match "No installed package") { Write-Host "  Everything is up to date!" -ForegroundColor Green }
        else { Write-Host " 󰅙 Error: Could not parse winget output." -ForegroundColor Red }
        return
    }

    $idStart      = $headerLine.IndexOf("Id")
    $versionStart = $headerLine.IndexOf("Version")
    $list = $raw | Where-Object {
        $line = $_.Trim()
        $line -ne "" -and $line -notmatch '^-+$' -and $line -notmatch 'Name\s+Id' -and $line.Length -gt $idStart
    }

    if (-not $list) { Write-Host "  No updates found in the list." -ForegroundColor Green; return }

    $selected = $list | fzf --exact --multi --reverse --header "󰚰 Select apps to UPDATE"

    foreach ($line in $selected) {
        if ($line.Length -ge $versionStart) {
            $id = $line.Substring($idStart, ($versionStart - $idStart)).Trim()
            if ($id) {
                Write-Host "`n󰑢 Updating: $id" -ForegroundColor Yellow
                winget upgrade --id "$id" --exact
            }
        }
    }
}

function la {
    $selected = winget list | Out-String -Stream |
        Where-Object { $_ -match '^\S+' -and $_ -notmatch 'Name|---' } |
        fzf --exact --reverse --header " Search installed apps"

    $id = ($selected -split '\s{2,}')[1]
    if ($id) {
        Write-Host "`n󰘥 Fetching info for: $id" -ForegroundColor Yellow
        winget show --id $id.Trim() --exact
    }
}

Set-PSReadLineKeyHandler -Key "Ctrl+h" -ScriptBlock {
    $historyFile = (Get-PSReadLineOption).HistorySavePath
    if (-not (Test-Path $historyFile)) {
        Write-Host " 󱞣 No history file found." -ForegroundColor Red; return
    }

    $content = Get-Content $historyFile
    [Array]::Reverse($content)

    $selected = $content |
        Select-Object -Unique |
        fzf --exact --reverse --height 40% --header " History Search"

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

    $SearchPath = Resolve-Path $Path -ErrorAction SilentlyContinue
    if (-not $SearchPath) {
        Write-Host " 󱞣 Path not found: $Path" -ForegroundColor Red; return
    }

    $selection = fd . $SearchPath --hidden --color never --exclude "Windows" |
        fzf --exact --layout=reverse --height=40% --header " Searching: $SearchPath"

    if (Test-Path $selection -PathType Container) {
        Set-Location $selection
    } else {
        Start-Process $selection
    }
}

# ==============================================================================
# 7. THIRD PARTY TOOLS
# ==============================================================================
function ctt {
    if (-not (Test-Admin)) { Invoke-Elevated -Command "ctt"; return }
    _PrintHeader "󱓞" "Chris Titus Tech Toolbox"
    Invoke-RestMethod https://christitus.com/win | Invoke-Expression
}

function massgrave {
    if (-not (Test-Admin)) { Invoke-Elevated -Command "massgrave"; return }
    _PrintHeader "󰄲" "Massgrave Activation"
    Invoke-RestMethod https://get.activated.win | Invoke-Expression
}

# ==============================================================================
# 8. MEDIA
# ==============================================================================
function pirith {
    $dir = "$HOME\Music\pirith"
    if (-not (Test-Path $dir)) {
        Write-Host " 󱞣 Pirith folder not found: $dir" -ForegroundColor Red; return
    }

    _PrintHeader "󰎆" "Pirith Player"
    $selected = Get-ChildItem -Path $dir -File |
        Where-Object { $_.Extension -in @('.mp3', '.wav', '.aac', '.flac', '.ogg') } |
        ForEach-Object { $_.Name } |
        fzf --exact --reverse --height 40% --header "󰪐  Select to Play"

    if ($selected) {
        _PrintRow "󰝚" "Playing" $selected "Cyan"
        _PrintFooter
        mpv "$dir\$selected"
    }
}

# ==============================================================================
# 9. NETWORK
# ==============================================================================
function wgsocks { & "$RepoPath\scripts\wgsocks.ps1" @args }
function warp { & "$RepoPath\scripts\warp.ps1" @args }

# ==============================================================================
# 10. INFO & DOCUMENTATION
# ==============================================================================
function info {
    _PrintHeader "󱈄" "Custom Shell Commands"
    _PrintRow "󰒍" "Profile"   "conf, reload"
    _PrintRow "" "System"    "rr, open, cleanup, termux"
    _PrintRow "󰚰" "Updates"   "upall, cup, upa, ups, upw, upf, upc"
    _PrintRow "󰍉" "FZF"       "ff, inst, uninst, up, la, Ctrl+H"
    _PrintRow "󰎈" "Media"     "pirith"
    _PrintRow "󱓞" "Tools"     "ctt, massgrave"
    _PrintRow "󰒄" "Network"   "wgsocks, warp"
    _PrintFooter
}

# ==============================================================================
# 11. OVERRIDES
# ==============================================================================
Remove-Item Alias:cd -Force -ErrorAction SilentlyContinue
Remove-Item Alias:z  -Force -ErrorAction SilentlyContinue

function cd {
    if ($args.Count -eq 0) { return }
    if (-not (Test-Path $args[0])) {
        Write-Host " 󱞣 Path not found: $($args[0])" -ForegroundColor Red; return
    }
    if (-not (Test-Path $args[0] -PathType Container)) {
        Write-Host " 󰅙 Not a directory: $($args[0])" -ForegroundColor Red; return
    }
    Set-Location $args[0]
    Get-ChildItem
}

function z {
    if ($args.Count -eq 0) { return }
    $before = $PWD.Path
    __zoxide_z $args
    if ($PWD.Path -eq $before) {return}
    Get-ChildItem
}