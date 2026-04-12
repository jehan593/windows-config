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
    Write-Host "󰮯 Elevating to Administrator..." -ForegroundColor Cyan
    $full    = "Set-Location '$($PWD.Path)'; $Command"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($full))
    Start-Process wt -Verb RunAs -ArgumentList "pwsh", "-NoExit", "-EncodedCommand", $encoded
}

function _PrintHeader
{
    param([string]$Icon, [string]$Title)
    Write-Host ""
    Write-Host "$Icon  $Title" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkBlue
}

function _PrintFooter
{
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`n" -ForegroundColor DarkBlue
}

function _PrintRow
{
    param([string]$Icon, [string]$Label, [string]$Value, [string]$Color = "White")
    Write-Host ("│  {0} {1,-12} {2}" -f $Icon, $Label, $Value) -ForegroundColor $Color
}

function _Run
{
    param([string]$Label, [scriptblock]$Action)
    try
    {
        & $Action | Out-Null
        _PrintRow "󰄬" $Label "Done" "Green"
    } catch
    {
        _PrintRow "󰅙" $Label "Failed" "Red"
    }
}

function _InfoGroup([string]$Icon, [string]$Title)
{
    Write-Host " $Icon $Title" -ForegroundColor Yellow
}

function _InfoCmd([string]$Cmd, [string]$Desc)
{
    Write-Host "   " -NoNewline
    Write-Host ("{0,-12}" -f $Cmd) -NoNewline -ForegroundColor Cyan
    Write-Host " - $Desc" -ForegroundColor Gray
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
    Write-Host "Reloading..." -ForegroundColor Cyan
    pwsh -NoExit -Command "Set-Location '$($PWD.Path)'"
    exit
}

function conf
{
    Write-Host "󰅨 Opening Configs..." -ForegroundColor Cyan
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
        { "󰅙 Not a directory" 
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
    { Write-Host "󰅙 Already running as Administrator." -ForegroundColor Red; return 
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

    _PrintHeader "󰋊" "Size"
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
        _PrintRow "󰋊" "Size"    (_FormatSize $size) "Cyan"
    }
    _PrintFooter
}

function cleanup
{
    if (!$IsAdmin)
    { Invoke-Elevated -Command $MyInvocation.MyCommand.Name; return 
    }
    _PrintHeader "󰃢" "System Cleanup"
    _Run "Windows Update Store" { dism.exe /online /Cleanup-Image /StartComponentCleanup }
    _Run "Disk Cleanup"         { cleanmgr.exe /d C: /VERYLOWDISK }
    _Run "Temp Folders"         {
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
function in
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
        Write-Host "󰍉 Fetching package list..." -ForegroundColor Cyan
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
            --header "󰏓 Ctrl-P: Preview | Tab: multi-select" `
            --preview "winget show --id {}" `
            --preview-window "right:60%:hidden" `
            --bind "ctrl-p:toggle-preview"
    }

    $ids = @($ids | Where-Object { $_ })
    if (!$ids.Count)
    { return 
    }

    Write-Host "`n󰏓 Selected for installation:" -ForegroundColor Cyan
    $ids | ForEach-Object { Write-Host "   + $_" -ForegroundColor Green }
    $confirm = Read-Host "`nInstall $($ids.Count) package(s)? (Y/n)"
    if ($confirm -match '^[Nn]$')
    { Write-Host "󰅙 Aborted." -ForegroundColor Gray; return 
    }

    foreach ($id in $ids)
    {
        Write-Host "`n󰐕 Installing: $id" -ForegroundColor Cyan
        winget install --id $id --exact --source winget --interactive @extraArgs
        Add-Content -Path (Get-PSReadLineOption).HistorySavePath `
            -Value "winget install --id $id --exact --source winget"
    }
}

function un
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
                    --header "󰏔 Ctrl-P: Preview | Tab: multi-select" `
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
    $names | ForEach-Object { Write-Host "   - $_" -ForegroundColor Red }
    $confirm = Read-Host "`nUninstall $($ids.Count) package(s)? (Y/n)"
    if ($confirm -match '^[Nn]$')
    { Write-Host "󰅙 Aborted." -ForegroundColor Gray; return 
    }

    foreach ($id in $ids)
    {
        Write-Host "`n󰛌 Removing: $id" -ForegroundColor Cyan
        winget uninstall --id $id --exact --interactive
        Add-Content -Path (Get-PSReadLineOption).HistorySavePath `
            -Value "winget uninstall --id $id --exact"
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
                    --header "󰚰 Ctrl-P: Preview | Tab: multi-select" `
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
    $names | ForEach-Object { Write-Host "   + $_" -ForegroundColor Yellow }
    $confirm = Read-Host "`nUpgrade $($ids.Count) package(s)? (Y/n)"
    if ($confirm -match '^[Nn]$')
    { Write-Host "󰅙 Aborted." -ForegroundColor Gray; return 
    }

    foreach ($id in $ids)
    {
        Write-Host "`n󰑢 Upgrading: $id" -ForegroundColor Yellow
        winget upgrade --id $id --exact
        Add-Content -Path (Get-PSReadLineOption).HistorySavePath `
            -Value "winget upgrade --id $id --exact"
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
    _PrintHeader "󰚰" "Checking for Updates"

    Write-Host ""
    Write-Host "󰏓 Winget" -ForegroundColor Magenta
    winget upgrade

    Write-Host ""
    Write-Host " Store Apps" -ForegroundColor Magenta
    if (Get-Command store -ErrorAction SilentlyContinue)
    {
        store updates
    } else
    {
        _PrintRow "󱞣" "Store" "Command not found. Update Microsoft Store." "Gray"
    }

    Write-Host ""
    Write-Host " Windows Update" -ForegroundColor Magenta
    try
    {
        Import-Module PSWindowsUpdate -ErrorAction SilentlyContinue
        $updates = @(Get-WindowsUpdate -ErrorAction SilentlyContinue)
        if ($updates.Count -eq 0)
        {
            _PrintRow "" "Windows" "No updates available" "Green"
        } else
        {
            _PrintRow "󰚰" "Windows" "$($updates.Count) update(s) available" "Yellow"
            $updates | ForEach-Object { Write-Host "   󱞩 $($_.Title)" -ForegroundColor Cyan }
        }
    } catch
    {
        _PrintRow "󰅙" "Windows" "Failed to query" "Red"
    }
    _PrintFooter
}

function upp
{
    _PrintHeader "󰏓" "Winget Upgrade"
    winget upgrade --all
    _PrintFooter
}

function ups
{
    if (!(Get-Command store -ErrorAction SilentlyContinue))
    {
        _PrintRow "󰅙" "Store" "Command not found. Update Microsoft Store." "Gray"; return
    }
    _PrintHeader "" "Store Update"
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
        _PrintHeader "" "Windows Update"
        _PrintRow "󱎟" "Status" "Searching for updates..." "Cyan"
        $updates = @(Get-WindowsUpdate -ErrorAction SilentlyContinue)
        if ($updates.Count -eq 0)
        {
            _PrintRow "" "Status" "No updates available" "Green"
            _PrintFooter; return
        }
        _PrintRow "󰚰" "Found"  "$($updates.Count) update(s)" "Yellow"
        _PrintRow "󰏔" "Status" "Installing..." "Cyan"
        Get-WindowsUpdate -Install -AcceptAll -AutoReboot:$false -ErrorAction SilentlyContinue
        _PrintRow "󰄬" "Status" "Installation complete" "Green"
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

    _PrintHeader "󰈹" "Firefox Tweaks"

    if (!(Test-Path $profilesPath))
    {
        _PrintRow "󰅙" "Error" "Firefox profiles not found" "Red"; _PrintFooter; return
    }
    $profiles = Get-ChildItem $profilesPath -Directory
    if ($profiles.Count -eq 0)
    {
        _PrintRow "󰅙" "Error" "No profiles found" "Red"; _PrintFooter; return
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
        _PrintRow "󰅙" "Error" "Failed to download Betterfox" "Red"; _PrintFooter; return
    }

    foreach ($prof in $profiles)
    {
        try
        {
            Set-Content -Path (Join-Path $prof.FullName "user.js") -Value $baseContent -ErrorAction Stop
            _PrintRow "󰄬" "Applied" $prof.Name "Green"
        } catch
        {
            _PrintRow "󰅙" "Failed" $prof.Name "Red"
        }
    }
    _PrintFooter
}

function upc
{
    _PrintHeader "󰚰" "Config Update"
    git -C $RepoPath pull --rebase --autostash
    if ($LASTEXITCODE -eq 0)
    {
        _PrintRow "󰊢" "Status" "Configs up to date!" "Green"
        _PrintFooter
        reload
    } else
    {
        _PrintRow "󰅙" "Status" "Update Failed" "Red"
        _PrintFooter
    }
}

function upall
{
    if (!$IsAdmin)
    { Invoke-Elevated -Command $MyInvocation.MyCommand.Name; return 
    }
    upp
    _PrintHeader "󱑢" "Choco Upgrade"
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
        fzf --no-multi --layout=reverse --height=40% --header "󱎟 Searching: $search"

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
                --header "󱎟 History (Enter: Use | Tab: Multi-select | Ctrl+D: Delete)" `
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
    _PrintHeader "󰹧" "Wallpapers"

    if (!(Test-Path $dir))
    {
        _PrintRow "󰅙" "Error" "Wallpapers directory not found" "Red"; _PrintFooter; return
    }

    $changes = git -C $dir status --porcelain 2>$null
    if ($changes)
    {
        _PrintRow "󰊢" "Local" "Uncommitted changes found" "Yellow"
        git -C $dir add -A 2>&1 | Out-Null
        $result = git -C $dir commit -m "sync: local wallpaper changes" 2>&1
        if ($LASTEXITCODE -eq 0)
        { _PrintRow "󰄬" "Commit" "Changes committed" "Green" 
        } else
        { _PrintRow "󰅙" "Commit" "Failed: $($result | Select-Object -Last 1)" "Red" 
        }
    }

    $result = git -C $dir pull --rebase --autostash 2>&1
    if ($LASTEXITCODE -eq 0)
    { _PrintRow "󰄬" "Pull" "Up to date" "Green" 
    } else
    { _PrintRow "󰅙" "Pull" "Failed: $($result | Select-Object -Last 1)" "Red" 
    }

    $result = git -C $dir push 2>&1
    if ($LASTEXITCODE -eq 0)
    { _PrintRow "󰄬" "Push" "Synced to GitHub" "Green" 
    } else
    { _PrintRow "󰅙" "Push" "Failed: $($result | Select-Object -Last 1)" "Gray" 
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
    Write-Host " 󱈄 Custom Commands" -ForegroundColor White
    Write-Host " ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkBlue

    _InfoGroup "󰒍" "Profile & Config"
    _InfoCmd "conf"    "Open dotfiles config in Zed"
    _InfoCmd "reload"  "Restart PowerShell session"
    _InfoCmd "sw"      "Open a new admin terminal at current directory"
    Write-Host ""

    _InfoGroup "" "System & Files"
    _InfoCmd "z"       "Jump to directory (zoxide) and list contents"
    _InfoCmd "la"      "List directory contents (including hidden)"
    _InfoCmd "rr"      "Re-run last command as Admin"
    _InfoCmd "exp"     "Open path in file explorer"
    _InfoCmd "sz"      "Calculate file or directory size"
    _InfoCmd "cleanup" "Clean Windows temp and component store"
    _InfoCmd "regtwk"  "Apply Windows Registry Tweaks"
    Write-Host ""

    _InfoGroup "󰚰" "Updates & Maintenance"
    _InfoCmd "upall"   "Run all system updates listed below"
    _InfoCmd "cup"     "Check Winget, Store, and Windows for updates"
    _InfoCmd "upp"     "Winget: Upgrade all packages automatically"
    _InfoCmd "ups"     "MS Store: Install all app updates"
    _InfoCmd "upw"     "Windows Update: Install all available updates"
    _InfoCmd "upf"     "Firefox: Sync Betterfox overrides"
    _InfoCmd "upc"     "Configs: Pull latest from dotfiles repo"
    Write-Host ""

    _InfoGroup "󰍉" "Interactive Utilities (FZF)"
    _InfoCmd "ff"      "Fuzzy find files & copy path to clipboard"
    _InfoCmd "in"      "Winget: Install packages"
    _InfoCmd "un"      "Winget: Uninstall packages"
    _InfoCmd "up"      "Winget: Upgrade packages"
    _InfoCmd "Ctrl+H"  "Fuzzy search and execute command history"
    Write-Host ""

    _InfoGroup "󰎈" "Media & Third-Party"
    _InfoCmd "wp"        "Sync local wallpapers to/from GitHub repo"
    _InfoCmd "ctt"       "Download and run Chris Titus Tech toolbox"
    _InfoCmd "massgrave" "Download and run Windows Activation scripts"
    Write-Host ""

    _InfoGroup "󰒄" "Network"
    _InfoCmd "wgsocks" "Toggle WireGuard SOCKS proxy"
    _InfoCmd "warp"    "Toggle Cloudflare WARP"

    Write-Host " ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`n" -ForegroundColor DarkBlue
}

# ==============================================================================
# 13. STARTUP MESSAGE
# ==============================================================================
Write-Host ""
Write-Host "`e[38;2;235;203;139m󱈄 Run 'info' for custom commands`e[0m"
Write-Host ""
