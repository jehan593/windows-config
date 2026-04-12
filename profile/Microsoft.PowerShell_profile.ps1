# ==============================================================================
# 1. ENVIRONMENT & INITIALIZATION
# ==============================================================================
$RepoPath = "$HOME\windows-config"
$ENV:STARSHIP_CONFIG = "$RepoPath\configs\starship.toml"
$env:BAT_THEME = "Nord"

$user    = [Security.Principal.WindowsIdentity]::GetCurrent()
$IsAdmin = ([Security.Principal.WindowsPrincipal]$user).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$env:FZF_DEFAULT_OPTS = @(
    '--exact'
    '--color=bg+:#3b4252,bg:#2e3440,spinner:#81a1c1'
    '--color=hl:#c2a166,fg:#d8dee9,header:#5e81ac'
    '--color=info:#b48ead,pointer:#88c0d0,marker:#ebcb8b'
    '--color=fg+:#e5e9f0,prompt:#81a1c1,hl+:#ebcb8b'
    '--cycle'
) -join ' '

function Import-CachedCommand
{
    param([string]$Command, [string]$CacheName)
    $src   = (Get-Command $Command -ErrorAction SilentlyContinue)?.Source
    $cache = "$env:TEMP\$CacheName.ps1"
    if (!(Test-Path $cache) -or (Get-Item $src).LastWriteTime -gt (Get-Item $cache).LastWriteTime)
    {
        & $Command init powershell | Set-Content $cache -Encoding utf8
    }
    . $cache
}

Import-CachedCommand -Command "starship" -CacheName "starship_init"
Import-CachedCommand -Command "zoxide"   -CacheName "zoxide_init"

# ==============================================================================
# 2. INTERNAL HELPERS
# ==============================================================================
function Invoke-Elevated
{
    param([string]$Command)
    Write-Host "󰌋 Elevating to Administrator..." -ForegroundColor Cyan
    $full    = "Set-Location '$($PWD.Path)'; $Command"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($full))
    Start-Process wt -Verb RunAs -ArgumentList "pwsh", "-NoExit", "-EncodedCommand", $encoded
}

function _PrintHeader
{
    param([string]$Icon, [string]$Title)
    Write-Host ""
    Write-Host "$Icon  $Title" -ForegroundColor Cyan
    Write-Host "─────────────────────────────────────────────────────" -ForegroundColor DarkBlue
}

function _PrintFooter
{
    Write-Host "─────────────────────────────────────────────────────`n" -ForegroundColor DarkBlue
}

function _PrintRow
{
    param([string]$Icon, [string]$Label, [string]$Value, [string]$Color = "White")
    Write-Host ("│  {0} {1,-12} {2}" -f $Icon, $Label, $Value) -ForegroundColor $Color
}

function _PassThru
{
    process
    { Write-Host "`e[38;2;118;138;161m│  $_`e[0m"
    }
}

function _Run
{
    param([string]$Label, [scriptblock]$Action)
    try
    {
        & $Action 2>&1 | _PassThru
        _PrintRow "󰄬" $Label "Done" "Green"
    } catch
    {
        _PrintRow "󰅙" $Label "$_" "Red"
    }
}

function _InfoGroup([string]$Icon, [string]$Title)
{
    Write-Host " $Icon $Title" -ForegroundColor Yellow
}

function _InfoCmd([string]$Cmd, [string]$Desc)
{
    Write-Host "    " -NoNewline
    Write-Host ("{0,-12}" -f $Cmd) -NoNewline -ForegroundColor Cyan
    Write-Host " 󰁔 $Desc" -ForegroundColor Gray
}

function _FormatSize($bytes)
{
    if     ($bytes -ge 1TB)
    { "{0:N2} TB" -f ($bytes / 1TB)
    } elseif ($bytes -ge 1GB)
    { "{0:N2} GB" -f ($bytes / 1GB)
    } elseif ($bytes -ge 1MB)
    { "{0:N2} MB" -f ($bytes / 1MB)
    } elseif ($bytes -ge 1KB)
    { "{0:N2} KB" -f ($bytes / 1KB)
    } else
    { "$bytes B"
    }
}

# ==============================================================================
# 3. PROFILE MANAGEMENT
# ==============================================================================
function reload
{
    Write-Host "󰑓 Reloading PowerShell..." -ForegroundColor Cyan
    pwsh -NoExit -Command "Set-Location '$($PWD.Path)'"
    exit
}

function conf
{
    Write-Host "󱰦 Opening Configs in Zed..." -ForegroundColor Cyan
    zed $RepoPath
}

# ==============================================================================
# 4. SHELL OVERRIDES
# ==============================================================================
Remove-Item Alias:cat -Force -ErrorAction SilentlyContinue
Remove-Item Alias:cd  -Force -ErrorAction SilentlyContinue
Remove-Item Alias:z   -Force -ErrorAction SilentlyContinue

if (Get-Command bat -ErrorAction SilentlyContinue)
{
    Set-Alias cat bat
}

function cd
{
    if ($args.Count -eq 0)
    { Set-Location ~; Get-ChildItem -Force; return
    }

    if (!(Test-Path $args[0] -PathType Container))
    {
        $msg = if (Test-Path $args[0])
        { "󱤈 Not a directory"
        } else
        { "󱞣 Path not found"
        }
        Write-Host "$msg`: $($args[0])" -ForegroundColor Red; return
    }
    Set-Location $args[0]
    Get-ChildItem -Force
}

function z
{
    $before = $PWD.Path
    __zoxide_z @args
    if ($PWD.Path -ne $before)
    { Get-ChildItem -Force
    }
}

function la
{
    Get-ChildItem -Force @args
}

# ==============================================================================
# 5. CORE UTILITIES
# ==============================================================================
function sw
{
    if ($IsAdmin)
    { Write-Host "󰌋 Already running as Administrator." -ForegroundColor Red; return
    }
    Invoke-Elevated ""
}

function rr
{
    $cmd = (Get-History -Count 1).CommandLine
    if (!$cmd)
    { Write-Host "󱞣 No history found." -ForegroundColor Red; return
    }
    Write-Host "󰁯 Elevating: $cmd" -ForegroundColor Cyan
    Invoke-Elevated -Command $cmd
}

function exp
{
    param([string]$Path = ".")
    Invoke-Item (Split-Path (Resolve-Path $Path).Path)
}

function sz
{
    param([Parameter(Mandatory)][string]$Path)
    $target = (Resolve-Path $Path -ErrorAction SilentlyContinue).Path
    if (!$target)
    { Write-Host "󱞣 Path not found: $Path" -ForegroundColor Red; return
    }

    _PrintHeader "󰗮" "Storage Analysis"
    if (Test-Path $target -PathType Leaf)
    {
        $file = Get-Item $target
        _PrintRow "󰈔" "File" $file.Name "White"
        _PrintRow "󰋊" "Size" (_FormatSize $file.Length) "Cyan"
    } else
    {
        $items   = Get-ChildItem $target -Recurse -Force -ErrorAction SilentlyContinue
        $files   = $items | Where-Object { !$_.PSIsContainer }
        $folders = $items | Where-Object { $_.PSIsContainer }
        $size    = ($files | Measure-Object -Property Length -Sum).Sum
        _PrintRow "󰈔" "Files"   $files.Count "White"
        _PrintRow "󰉋" "Folders" $folders.Count "White"
        _PrintRow "󰋊" "Total Size" (_FormatSize $size) "Cyan"
    }
    _PrintFooter
}

function cleanup
{
    if (!$IsAdmin)
    { Invoke-Elevated -Command $MyInvocation.MyCommand.Name; return
    }
    _PrintHeader "󰃢" "System Cleanup"
    _Run "Win Update Store" { dism.exe /online /Cleanup-Image /StartComponentCleanup }
    _Run "Disk Cleanup"     { cleanmgr.exe /d C: /VERYLOWDISK }
    _Run "Temp Folders"     {
        foreach ($path in @($env:TEMP, "$env:SystemRoot\Temp"))
        {
            Get-ChildItem $path -Recurse -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    _PrintFooter
}

function regtwk
{
    & "$RepoPath\scripts\regtwk.ps1"
}

# ==============================================================================
# 6. PACKAGE MANAGEMENT (WINGET + FZF)
# ==============================================================================
function inst
{
    param(
        [Parameter(ValueFromRemainingArguments)]
        [string[]]$Id,
        [switch]$Refresh,
        [switch]$IgnoreHash
    )

    $cacheFile = "$env:TEMP\winget_search_cache.txt"

    if ($Refresh)
    {
        Remove-Item $cacheFile -ErrorAction SilentlyContinue
        Write-Host "󰚰 Cache cleared." -ForegroundColor Cyan
    }

    if (!(Test-Path $cacheFile) -or (Get-Item $cacheFile).LastWriteTime -lt (Get-Date).AddDays(-7))
    {
        Write-Host "󱑤 Fetching package list..." -ForegroundColor Cyan
        Find-WinGetPackage -Source winget | ForEach-Object { $_.Id } | Set-Content $cacheFile
    }

    $cacheIds  = Get-Content $cacheFile
    $extraArgs = if ($IgnoreHash)
    { @('--ignore-security-hash')
    } else
    { @()
    }

    $ids = if ($Id)
    {
        Write-Host "`n󰍉 Resolving package names..." -ForegroundColor Cyan
        $notFound = @()
        $resolved = foreach ($i in $Id)
        {
            $m = @($cacheIds | Where-Object { $_ -like "*$i*" })
            if (!$m)
            { $notFound += $i; continue
            }
            if ($m.Count -eq 1)
            { $m[0].Trim()
            } else
            { $m | fzf --prompt "󰍉 '$i' > " --reverse --height 40%
            }
        }
        if ($notFound)
        {
            Write-Host "`n󱞣 Could not find packages for:" -ForegroundColor Red
            $notFound | ForEach-Object { Write-Host "   - $_" -ForegroundColor Gray }
        }
        $resolved | Where-Object { $_ }
    } else
    {
        $cacheIds | fzf --multi --reverse `
            --header "󰏓 Ctrl-P: Preview | Tab: Multi-select" `
            --preview "winget show --id {}" `
            --preview-window "right:60%:hidden" `
            --bind "ctrl-p:toggle-preview"
    }

    $ids = @($ids | Where-Object { $_ })
    if (!$ids.Count)
    { return
    }

    Write-Host "`n󰏓 Selected for installation:" -ForegroundColor Cyan
    $ids | ForEach-Object { Write-Host "   󰐕 $_" -ForegroundColor Green }
    $confirm = Read-Host "`nInstall $($ids.Count) package(s)? (Y/n)"
    if ($confirm -match '^[Nn]$')
    { Write-Host "󰅙 Aborted." -ForegroundColor Gray; return
    }

    foreach ($id in $ids)
    {
        Write-Host "`n󰐕 Installing: $id" -ForegroundColor Cyan
        winget install --id $id --exact --source winget --interactive @extraArgs
        $histEntry = "winget install --id $id --exact --source winget"
        Add-Content -Path (Get-PSReadLineOption).HistorySavePath -Value $histEntry
        [Microsoft.PowerShell.PSConsoleReadLine]::AddToHistory($histEntry)
    }
}

function uinst
{
    param(
        [Parameter(ValueFromRemainingArguments)]
        [string[]]$Id
    )

    $ids   = @()
    $names = @()

    if ($Id)
    {
        Write-Host "`n󰍉 Resolving package names..." -ForegroundColor Cyan
        $notFound  = @()
        $installed = Get-WinGetPackage -ErrorAction SilentlyContinue

        foreach ($i in $Id)
        {
            $pkg = $installed | Where-Object { $_.Id -match $i -or $_.Name -match $i } | Select-Object -First 1
            if ($pkg)
            { $ids += $pkg.Id; $names += "$($pkg.Name) [$($pkg.Id)]"
            } else
            { $notFound += $i
            }
        }

        if ($notFound.Count)
        {
            Write-Host "`n󱞣 Could not find installed packages for:" -ForegroundColor Red
            $notFound | ForEach-Object { Write-Host "   - $_" -ForegroundColor Gray }
        }
        if (!$ids.Count)
        { Write-Host "`n󰅙 No valid packages to uninstall. Aborted." -ForegroundColor Gray; return
        }
    } else
    {
        $ids = @(Get-WinGetPackage |
                Select-Object -ExpandProperty Id |
                fzf --multi --reverse `
                    --header "󰏔 Ctrl-P: Preview | Tab: Multi-select" `
                    --preview "winget show --id {}" `
                    --preview-window "right:60%:hidden" `
                    --bind "ctrl-p:toggle-preview" |
                ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $names = $ids
        if (!$ids.Count)
        { return
        }
    }

    Write-Host "`n󰏔 Selected for removal:" -ForegroundColor Cyan
    $names | ForEach-Object { Write-Host "   󱙃 $_" -ForegroundColor Gray }
    $confirm = Read-Host "`nUninstall $($ids.Count) package(s)? (Y/n)"
    if ($confirm -match '^[Nn]$')
    { Write-Host "󰅙 Aborted." -ForegroundColor Gray; return
    }

    foreach ($id in $ids)
    {
        Write-Host "`n󰛌 Removing: $id" -ForegroundColor Cyan
        winget uninstall --id $id --exact --interactive
        $histEntry = "winget uninstall --id $id --exact"
        Add-Content -Path (Get-PSReadLineOption).HistorySavePath -Value $histEntry
        [Microsoft.PowerShell.PSConsoleReadLine]::AddToHistory($histEntry)
    }
}

function up
{
    param(
        [Parameter(ValueFromRemainingArguments)]
        [string[]]$Id
    )

    $ids   = @()
    $names = @()

    if ($Id)
    {
        Write-Host "`n󰍉 Resolving installed packages..." -ForegroundColor Cyan
        $notFound  = @()
        $installed = Get-WinGetPackage -ErrorAction SilentlyContinue

        foreach ($i in $Id)
        {
            $pkg = $installed | Where-Object { $_.Id -match $i -or $_.Name -match $i } | Select-Object -First 1
            if ($pkg)
            { $ids += $pkg.Id; $names += "$($pkg.Name) [$($pkg.Id)]"
            } else
            { $notFound += $i
            }
        }

        if ($notFound.Count)
        {
            Write-Host "`n󱞣 Could not find installed packages for:" -ForegroundColor Red
            $notFound | ForEach-Object { Write-Host "   - $_" -ForegroundColor Gray }
        }
        if (!$ids.Count)
        { Write-Host "`n󰅙 No valid packages found. Aborted." -ForegroundColor Gray; return
        }
    } else
    {
        $updates = @(Get-WinGetPackage | Where-Object { $_.IsUpdateAvailable })
        if (!$updates.Count)
        { Write-Host "󰄬 Everything is up to date!" -ForegroundColor Green; return
        }

        $ids = @($updates |
                Select-Object -ExpandProperty Id |
                fzf --multi --reverse `
                    --header "󰚰 Ctrl-P: Preview | Tab: Multi-select" `
                    --preview "winget show --id {}" `
                    --preview-window "right:60%:hidden" `
                    --bind "ctrl-p:toggle-preview" |
                ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $names = $ids
        if (!$ids.Count)
        { return
        }
    }

    Write-Host "`n󰚰 Selected for upgrade:" -ForegroundColor Cyan
    $names | ForEach-Object { Write-Host "   󰑢 $_" -ForegroundColor Yellow }
    $confirm = Read-Host "`nUpgrade $($ids.Count) package(s)? (Y/n)"
    if ($confirm -match '^[Nn]$')
    { Write-Host "󰅙 Aborted." -ForegroundColor Gray; return
    }

    foreach ($id in $ids)
    {
        Write-Host "`n󰑢 Upgrading: $id" -ForegroundColor Yellow
        winget upgrade --id $id --exact
        $histEntry = "winget upgrade --id $id --exact"
        Add-Content -Path (Get-PSReadLineOption).HistorySavePath -Value $histEntry
        [Microsoft.PowerShell.PSConsoleReadLine]::AddToHistory($histEntry)
    }
}

# ==============================================================================
# 7. UPDATES & MAINTENANCE
# ==============================================================================
function cup
{
    if (!$IsAdmin)
    { Invoke-Elevated -Command $MyInvocation.MyCommand.Name; return
    }
    _PrintHeader "󰑢" "Update Checker"

    Write-Host ""
    Write-Host "󰏓 Winget Repositories" -ForegroundColor Magenta
    winget upgrade

    Write-Host ""
    Write-Host "󰶬 Microsoft Store" -ForegroundColor Magenta
    if (Get-Command store -ErrorAction SilentlyContinue)
    {
        store updates
    } else
    {
        _PrintRow "󱞣" "Store" "CLI tool not found." "Gray"
    }

    Write-Host ""
    Write-Host "󰖳 Windows Update" -ForegroundColor Magenta
    try
    {
        Import-Module PSWindowsUpdate -ErrorAction SilentlyContinue
        $updates = @(Get-WindowsUpdate -ErrorAction SilentlyContinue)
        if ($updates.Count -eq 0)
        {
            _PrintRow "󰄬" "Windows" "Up to date" "Green"
        } else
        {
            _PrintRow "󱎟" "Windows" "$($updates.Count) available" "Yellow"
            $updates | ForEach-Object { Write-Host "    󱞩 $($_.Title)" -ForegroundColor Cyan }
        }
    } catch
    {
        _PrintRow "󰅙" "Windows" "Query failed" "Red"
    }
    _PrintFooter
}

function upp
{
    _PrintHeader "󰏓" "Winget: Global Update"
    winget upgrade --all
    _PrintFooter
}

function ups
{
    if (!(Get-Command store -ErrorAction SilentlyContinue))
    {
        _PrintRow "󰅙" "Store" "CLI tool not found." "Gray"; return
    }
    _PrintHeader "󰶬" "Store: App Updates"
    store updates --apply
    _PrintFooter
}

function upw
{
    if (!$IsAdmin)
    { Invoke-Elevated -Command $MyInvocation.MyCommand.Name; return
    }
    try
    {
        Import-Module PSWindowsUpdate -ErrorAction SilentlyContinue
        _PrintHeader "󰖳" "Windows Update Service"
        _PrintRow "󱎟" "Status" "Searching..." "Cyan"
        $updates = @(Get-WindowsUpdate -ErrorAction SilentlyContinue)
        if ($updates.Count -eq 0)
        {
            _PrintRow "󰄬" "Status" "No updates found" "Green"
            _PrintFooter; return
        }
        _PrintRow "󱎟" "Found"   "$($updates.Count) updates" "Yellow"
        _PrintRow "󰏔" "Status" "Installing..." "Cyan"
        Get-WindowsUpdate -Install -AcceptAll -AutoReboot:$false -ErrorAction SilentlyContinue
        _PrintRow "󰄬" "Status" "System is current" "Green"
    } catch
    {
        _PrintRow "󰅙" "Error" "$_" "Red"
    }
    _PrintFooter
}

function upf
{
    $url           = "https://raw.githubusercontent.com/yokoffing/Betterfox/main/user.js"
    $overridesPath = "$RepoPath\configs\firefox\user-overrides.js"
    $profilesPath  = "$env:APPDATA\Mozilla\Firefox\Profiles"

    _PrintHeader "󰈹" "Firefox: Betterfox Sync"

    if (!(Test-Path $profilesPath))
    {
        _PrintRow "󰅙" "Error" "Mozilla path missing" "Red"; _PrintFooter; return
    }
    $profiles = Get-ChildItem $profilesPath -Directory
    if ($profiles.Count -eq 0)
    {
        _PrintRow "󰅙" "Error" "No profiles detected" "Red"; _PrintFooter; return
    }

    try
    {
        $baseContent = (Invoke-WebRequest -Uri $url -UseBasicParsing -ErrorAction Stop).Content
        if (Test-Path $overridesPath)
        {
            $baseContent += "`n// --- Custom Overrides ---`n" + (Get-Content $overridesPath -Raw)
        }
    } catch
    {
        _PrintRow "󰅙" "Error" "Download failed" "Red"; _PrintFooter; return
    }

    foreach ($prof in $profiles)
    {
        try
        {
            Set-Content -Path (Join-Path $prof.FullName "user.js") -Value $baseContent -ErrorAction Stop
            _PrintRow "󰄬" "Synced" $prof.Name "Green"
        } catch
        {
            _PrintRow "󰅙" "Failed" $prof.Name "Red"
        }
    }
    _PrintFooter
}

function upc
{
    _PrintHeader "󰊢" "Dotfiles Repo Sync"
    git -C $RepoPath pull --rebase --autostash 2>&1 | _PassThru
    if ($LASTEXITCODE -eq 0)
    {
        _PrintRow "󰄬" "Status" "Synchronized" "Green"
        _PrintFooter
        reload
    } else
    {
        _PrintRow "󰅙" "Status" "Merge Conflict / Error" "Red"
        _PrintFooter
    }
}

function upall
{
    if (!$IsAdmin)
    { Invoke-Elevated -Command $MyInvocation.MyCommand.Name; return
    }
    upp
    _PrintHeader "󰏓" "Chocolatey Upgrade"
    choco upgrade all -y
    _PrintFooter
    upf
    wp
    ups
    upw
    upc
}

# ==============================================================================
# 8. INTERACTIVE TOOLS (FZF)
# ==============================================================================
function ff
{
    param(
        [Parameter(Position = 0)]
        [string]$Path = "C:\"
    )
    $search = (Resolve-Path $Path -ErrorAction SilentlyContinue).Path
    if (!$search)
    { Write-Host "󱞣 Path not found: $Path" -ForegroundColor Red; return
    }

    $selection = fd . $search --hidden --color never --exclude "Windows" |
        fzf --no-multi --layout=reverse --height=40% --header "󰈞 Searching: $search"

    if (!$selection)
    { return
    }

    $quoted  = "`"$($selection.Trim())`""
    $escaped = " $quoted" -replace '([+^%~()\[\]{}])', '{$1}'
    $wshell  = New-Object -ComObject WScript.Shell
    $wshell.SendKeys($escaped)
    $wshell.SendKeys('{HOME}')
}

Set-PSReadLineKeyHandler -Key "Ctrl+h" -ScriptBlock {
    $historyFile = (Get-PSReadLineOption).HistorySavePath
    if (!(Test-Path $historyFile))
    { Write-Host "󱞣 No history file found." -ForegroundColor Red; return
    }

    $content = Get-Content $historyFile
    [Array]::Reverse($content)

    $result = @($content |
            Select-Object -Unique |
            fzf --multi --reverse --height 40% `
                --header "󱋚 History (Enter: Use | Tab: Select | Ctrl+D: Delete)" `
                --expect=ctrl-d)

    if (!$result.Count)
    { return
    }

    $key      = $result[0]
    $selected = @($result | Select-Object -Skip 1)

    [Microsoft.PowerShell.PSConsoleReadLine]::DeleteLine()

    if ($key -eq "ctrl-d")
    {
        if ($selected.Count)
        {
            $newContent = $content | Where-Object { $_ -notin $selected }
            Set-Content $historyFile $newContent
        }
        return
    }

    if ($selected.Count -eq 1)
    {
        [Microsoft.PowerShell.PSConsoleReadLine]::Insert($selected[0].Trim())
    } else
    {
        [Microsoft.PowerShell.PSConsoleReadLine]::Insert(($selected | ForEach-Object { $_.Trim() }) -join " & ")
    }
}

# ==============================================================================
# 9. NETWORK
# ==============================================================================
function wgsocks
{
    & "$RepoPath\scripts\wgsocks.ps1" @args
}

function warp
{
    & "$RepoPath\scripts\warp.ps1" @args
}

# ==============================================================================
# 10. MEDIA
# ==============================================================================
function wp
{
    $dir = Join-Path ([Environment]::GetFolderPath("MyPictures")) "config-wallpapers"
    _PrintHeader "󰹧" "Wallpaper Git Sync"

    if (!(Test-Path $dir))
    {
        _PrintRow "󰅙" "Error" "Directory missing" "Red"; _PrintFooter; return
    }

    $changes = git -C $dir status --porcelain 2>$null
    if ($changes)
    {
        _PrintRow "󱓟" "Local" "Changes detected" "Yellow"
        git -C $dir add -A 2>&1 | _PassThru
        git -C $dir commit -m "sync: local wallpaper changes" 2>&1 | _PassThru
        if ($LASTEXITCODE -eq 0)
        { _PrintRow "󰄬" "Commit" "Success" "Green"
        } else
        { _PrintRow "󰅙" "Commit" "Failed" "Red"
        }
    }

    git -C $dir pull --rebase --autostash 2>&1 | _PassThru
    if ($LASTEXITCODE -eq 0)
    { _PrintRow "󰄬" "Pull" "Up to date" "Green"
    } else
    { _PrintRow "󰅙" "Pull" "Failed" "Red"
    }

    git -C $dir push 2>&1 | _PassThru
    if ($LASTEXITCODE -eq 0)
    { _PrintRow "󰄬" "Push" "Remote updated" "Green"
    } else
    { _PrintRow "󰅙" "Push" "Check remote" "Gray"
    }

    _PrintFooter
}

# ==============================================================================
# 11. THIRD PARTY TOOLS
# ==============================================================================
function ctt
{
    if (-not ($IsAdmin))
    { Invoke-Elevated -Command "ctt"; return
    }
    _PrintHeader "󱓞" "Chris Titus Tech Toolbox"
    Invoke-RestMethod https://christitus.com/win | Invoke-Expression
}

function massgrave
{
    if (-not ($IsAdmin))
    { Invoke-Elevated -Command "massgrave"; return
    }
    _PrintHeader "󰄲" "Massgrave Activation"
    Invoke-RestMethod https://get.activated.win | Invoke-Expression
}

# ==============================================================================
# 12. INFO & DOCUMENTATION
# ==============================================================================
function info
{
    Write-Host ""
    Write-Host " 󱈄 Shell Environment Toolkit" -ForegroundColor White
    Write-Host " ─────────────────────────────────────────────────────────────" -ForegroundColor DarkBlue

    _InfoGroup "󱰦" "Configuration"
    _InfoCmd "conf"    "Open workspace in Zed"
    _InfoCmd "reload"  "Restart shell session"
    _InfoCmd "sw"      "Launch Admin terminal"
    Write-Host ""

    _InfoGroup "󰉋" "System & Files"
    _InfoCmd "z"       "Zoxide jump + ls"
    _InfoCmd "la"      "List all files"
    _InfoCmd "rr"      "Elevate last command"
    _InfoCmd "exp"     "Open in Explorer"
    _InfoCmd "sz"      "Deep size calculation"
    _InfoCmd "cleanup" "Purge temp/system bloat"
    _InfoCmd "regtwk"  "Registry optimization"
    Write-Host ""

    _InfoGroup "󰑢" "Maintenance"
    _InfoCmd "upall"   "Complete system update"
    _InfoCmd "cup"     "Update availability check"
    _InfoCmd "upp"     "Winget upgrade all"
    _InfoCmd "ups"     "App Store updates"
    _InfoCmd "upw"     "Windows Update install"
    _InfoCmd "upf"     "Sync Betterfox configs"
    _InfoCmd "upc"     "Pull repo dotfiles"
    Write-Host ""

    _InfoGroup "󰈞" "Fuzzy (FZF)"
    _InfoCmd "ff"      "Find file and paste path"
    _InfoCmd "inst"      "Winget install menu"
    _InfoCmd "uinst"      "Winget uninstall menu"
    _InfoCmd "up"      "Winget upgrade menu"
    _InfoCmd "Ctrl+H"  "Fuzzy history search"
    Write-Host ""

    _InfoGroup "󰎈" "Media & External"
    _InfoCmd "wp"        "Sync wallpaper repo"
    _InfoCmd "ctt"       "CTT WinUtil"
    _InfoCmd "massgrave" "Activation scripts"
    Write-Host ""

    _InfoGroup "󰒄" "Networking"
    _InfoCmd "wgsocks" "WireGuard Proxy"
    _InfoCmd "warp"    "Cloudflare WARP"

    Write-Host " ─────────────────────────────────────────────────────────────`n" -ForegroundColor DarkBlue
}

# ==============================================================================
# 13. STARTUP MESSAGE
# ==============================================================================
Write-Host ""
Write-Host "`e[38;2;235;203;139m󱈄 Type 'info' to see custom utilities`e[0m"
Write-Host ""
