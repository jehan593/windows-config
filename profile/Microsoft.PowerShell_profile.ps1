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
    '--cycle'
) -join ' '

# Generic Cache Function to speed up Shell Start
function Import-CachedCommand
{
    param([string]$Command, [string]$CacheName)
    $CacheFile = "$env:TEMP\$CacheName.ps1"
    if (!(Get-Command $Command -ErrorAction SilentlyContinue))
    { return
    }
    $commandPath = (Get-Command $Command).Source
    if (-not (Test-Path $CacheFile) -or (Get-Item $commandPath).LastWriteTime -gt (Get-Item $CacheFile).LastWriteTime)
    {
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
function reload
{
    Write-Host "󰚀 Restarting PowerShell session..." -ForegroundColor Cyan
    Start-Process "wt" -ArgumentList "pwsh", "-NoExit", "-Command", "Set-Location '$PWD'"
    exit
}

function conf
{
    Write-Host "󰅨 Opening Configs..." -ForegroundColor Cyan
    zed $RepoPath
}

# ==============================================================================
# 3. CORE UTILITIES (INTERNAL)
# ==============================================================================
function Test-Admin
{
    $user = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$user).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Elevated
{
    param([string]$Command)
    Write-Host "󰮯 Elevating to Administrator..." -ForegroundColor Cyan
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command))
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

# ==============================================================================
# 4. QUICK UTILITIES
# ==============================================================================
function rr
{
    $lastCommand = Get-History -Count 1
    if ($lastCommand)
    {
        $cmdString = $lastCommand.CommandLine
        $currentPath = $PWD.Path
        Write-Host "󰁯 Elevating: $cmdString" -ForegroundColor Cyan
        Invoke-Elevated -Command "Set-Location '$currentPath'; $cmdString"
    } else
    {
        Write-Host "󱞣 No history found." -ForegroundColor Red; return
    }
}

function cleanup
{
    if (-not (Test-Admin))
    { Invoke-Elevated -Command "cleanup"; return
    }
    _PrintHeader "󰃢" "System Cleanup"
    _Run "Windows Update Store" { dism.exe /online /Cleanup-Image /StartComponentCleanup }
    _Run "Disk Cleanup" { cleanmgr.exe /d C: /VERYLOWDISK }
    _Run "Temp Folders" {
        $tempPaths = @($env:TEMP, "$env:SystemRoot\Temp")
        foreach ($path in $tempPaths)
        {
            Get-ChildItem -Path $path -Recurse -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    _PrintFooter
}

function exp
{
    param([string]$Path = ".")
    $resolvedPath = Resolve-Path $Path -ErrorAction SilentlyContinue
    if (-not $resolvedPath)
    {
        Write-Host " 󱞣 Path not found: $Path" -ForegroundColor Red; return
    }
    $target = $resolvedPath.Path.TrimEnd('\')
    if (Test-Path $target -PathType Leaf)
    {
        $target = Split-Path $target -Parent
    }
    Write-Host "󰝰 Opening Explorer..." -ForegroundColor Cyan
    explorer.exe $target
}

function open
{
    param([string]$Path = ".")
    $resolvedPath = Resolve-Path $Path -ErrorAction SilentlyContinue
    if (-not $resolvedPath)
    {
        Write-Host "󱞣 Path not found: $Path" -ForegroundColor Red; return
    }
    $target = $resolvedPath.Path.TrimEnd('\')
    Write-Host "󰏌 Opening..." -ForegroundColor Cyan
    Start-Process $target
}

function touch
{
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path $Path)
    {
        (Get-Item $Path).LastWriteTime = Get-Date
        Write-Host "󰃰 Updated timestamp: $Path" -ForegroundColor Cyan
    } else
    {
        New-Item -ItemType File -Path $Path -Force | Out-Null
        Write-Host "󰝒 Created: $Path" -ForegroundColor Green
    }
}

function sz
{
    param([Parameter(Mandatory)][string]$Path)
    $resolved = Resolve-Path $Path -ErrorAction SilentlyContinue
    if (-not $resolved)
    {
        Write-Host " 󱞣 Path not found: $Path" -ForegroundColor Red; return
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

    _PrintHeader "󰋊" "Size"

    if (Test-Path $resolved.Path -PathType Leaf)
    {
        $file = Get-Item $resolved.Path
        _PrintRow "󰈔" "File"    $file.Name "White"
        _PrintRow "󰋊" "Size"    (_FormatSize $file.Length) "Cyan"
    } else
    {
        $items      = Get-ChildItem $resolved.Path -Recurse -Force -ErrorAction SilentlyContinue
        $size       = ($items | Measure-Object -Property Length -Sum).Sum
        $fileCount  = ($items | Where-Object { -not $_.PSIsContainer }).Count
        $folderCount= ($items | Where-Object { $_.PSIsContainer }).Count

        _PrintRow "󰈔" "Files"   "$fileCount" "White"
        _PrintRow "󰉋" "Folders" "$folderCount" "White"
        _PrintRow "󰋊" "Size"    (_FormatSize $size) "Cyan"
    }

    _PrintFooter
}

# ==============================================================================
# 5. MAINTENANCE & UPDATES
# ==============================================================================
function upall
{
    if (-not (Test-Admin))
    { Invoke-Elevated -Command "upall"; return
    }
    upa
    _PrintHeader "󱑢" "Choco Upgrade"
    choco upgrade all -y
    _PrintFooter
    upf
    wp
    ups
    upw
    upc
}

function cup
{
    if (-not (Test-Admin))
    { Invoke-Elevated -Command "cup"; return
    }
    _PrintHeader "󰚰" "Checking for Updates"
    Write-Host ""
    Write-Host "󰏓 Winget" -ForegroundColor Magenta
    winget upgrade
    Write-Host ""
    Write-Host "󰮯 Store Apps" -ForegroundColor Magenta
    if (Get-Command store -ErrorAction SilentlyContinue)
    { "n" | store updates
    } else
    { _PrintRow "󰋼" "Store" "Command not found" "Gray"
    }
    Write-Host ""
    Write-Host "󰚀 Windows Update" -ForegroundColor Magenta
    try
    {
        Import-Module PSWindowsUpdate -ErrorAction SilentlyContinue
        $updates = Get-WindowsUpdate -ErrorAction SilentlyContinue
        if ($null -eq $updates -or $updates.Count -eq 0)
        {
            _PrintRow "" "Windows" "No updates available" "Green"
        } else
        {
            $count = if ($updates -is [array])
            { $updates.Count
            } else
            { 1
            }
            _PrintRow "󰚰" "Windows" "$count update(s) available" "Yellow"
            if ($updates -is [array])
            {
                $updates | ForEach-Object { Write-Host "   󱞩 $($_.Title)" -ForegroundColor Cyan }
            } else
            {
                Write-Host "   󱞩 $($updates.Title)" -ForegroundColor Cyan
            }
        }
    } catch
    {
        _PrintRow "󰅙" "Windows" "Failed to query" "Red"
    }
    _PrintFooter
}

function upa
{
    if (-not (Test-Admin))
    { Invoke-Elevated -Command "upa"; return
    }
    _PrintHeader "󰏓" "Winget Upgrade"
    winget upgrade --all --interactive
    _PrintFooter
}

function upw
{
    if (-not (Test-Admin))
    {
        Invoke-Elevated -Command "upw"; return
    }

    try
    {
        Import-Module PSWindowsUpdate -ErrorAction SilentlyContinue

        _PrintHeader "󰚀" "Windows Update"
        _PrintRow "󱎟" "Status" "Searching for updates..." "Cyan"

        $updates = Get-WindowsUpdate -ErrorAction SilentlyContinue

        if ($null -eq $updates -or $updates.Count -eq 0)
        {
            _PrintRow "" "Status" "No updates available" "Green"
            _PrintFooter
            return
        }

        $count = if ($updates -is [array])
        { $updates.Count
        } else
        { 1
        }
        _PrintRow "󰚰" "Found" "$count update(s)" "Yellow"

        _PrintRow "󰏔" "Status" "Installing..." "Cyan"
        Get-WindowsUpdate -Install -AcceptAll -AutoReboot:$false -ErrorAction SilentlyContinue

        _PrintRow "󰄬" "Status" "Installation complete" "Green"
        _PrintFooter
    } catch
    {
        _PrintRow "󰅙" "Error" "$_" "Red"
        _PrintFooter
    }
}

function ups
{
    if (Get-Command store -ErrorAction SilentlyContinue)
    {
        _PrintHeader "󰮯" "Store Update"
        store updates --apply
        _PrintFooter
    } else
    {
        Write-Host " 󰅙 Command 'store' not found." -ForegroundColor Gray
    }
}

function upf
{
    $url = "https://raw.githubusercontent.com/yokoffing/Betterfox/main/user.js"
    $overridesPath = "$RepoPath\configs\firefox\user-overrides.js"
    $profilesPath = "$env:APPDATA\Mozilla\Firefox\Profiles"
    _PrintHeader "󰈹" "Firefox Tweaks"

    if (-not (Test-Path $profilesPath))
    {
        _PrintRow "󰅙" "Error" "Firefox profiles not found" "Red"; _PrintFooter; return
    }

    $profiles = Get-ChildItem -Path $profilesPath -Directory
    if ($profiles.Count -eq 0)
    {
        _PrintRow "󰅙" "Error" "No profiles found" "Red"; _PrintFooter; return
    }

    foreach ($prof in $profiles)
    {
        $userFilePath = Join-Path $prof.FullName "user.js"
        try
        {
            Invoke-WebRequest -Uri $url -OutFile $userFilePath -UseBasicParsing -ErrorAction Stop
            if (Test-Path $overridesPath)
            {
                Add-Content -Path $userFilePath -Value "`n// --- Custom Overrides ---"
                Get-Content $overridesPath | Add-Content -Path $userFilePath
            }
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
        Pause
        reload
    } else
    {
        _PrintRow "󰅙" "Status" "Update Failed" "Red"
        _PrintFooter
    }
}

# ==============================================================================
# 6. INTERACTIVE TOOLS (FZF) & KEYBINDINGS
# ==============================================================================

function inst
{
    param([string[]]$Id, [switch]$Refresh)
    if ($Refresh)
    {
        Remove-Item "$env:TEMP\winget_search_cache.txt" -ErrorAction SilentlyContinue
        Write-Host "󰚰 Cache cleared." -ForegroundColor Cyan
    }
    if ($Id)
    {
        foreach ($i in $Id)
        {
            Write-Host "󰐕 Installing: $i" -ForegroundColor Green
            winget install $i --interactive
            Add-Content -Path (Get-PSReadLineOption).HistorySavePath -Value "winget install $i"
        }
    } else
    {
        $cacheFile = "$env:TEMP\winget_search_cache.txt"
        $useCache = (Test-Path $cacheFile) -and ((Get-Item $cacheFile).LastWriteTime -gt (Get-Date).AddDays(-7))

        if (-not $useCache)
        {
            Write-Host "󰍉 Fetching package list..." -ForegroundColor Cyan
            Find-WinGetPackage -Source winget |
                ForEach-Object { $_.Id } |
                Set-Content $cacheFile
        }

        $selected = Get-Content $cacheFile |
            fzf --multi --reverse `
                --header "󰏓 Ctrl-P: Preview | Tab: multi-select" `
                --preview "winget show --id {}" `
                --preview-window "right:60%:hidden" `
                --bind "ctrl-p:toggle-preview"

        if (-not $selected)
        { return
        }

        $ids = @($selected | ForEach-Object { $_.Trim() } | Where-Object { $_ })

        if ($ids.Count -gt 1)
        {
            Write-Host ""
            Write-Host "󰏓 Selected for installation:" -ForegroundColor Cyan
            $ids | ForEach-Object { Write-Host "   + $_" -ForegroundColor Green }
            Write-Host ""
            $confirm = Read-Host "Install $($ids.Count) package(s)? (Y/n)"
            if ($confirm -match '^[Nn]$')
            { Write-Host "󰅙 Aborted." -ForegroundColor Gray; return
            }
        }

        foreach ($id in $ids)
        {
            Write-Host "`n󰐕 Installing: $id" -ForegroundColor Cyan
            winget install --id $id --exact --interactive
            Add-Content -Path (Get-PSReadLineOption).HistorySavePath -Value "winget install --id $id --exact"
        }
    }
}

function instd
{
    $result = Get-WinGetPackage |
        Select-Object -ExpandProperty Id |
        fzf --multi --reverse `
            --header "󰘥 Ctrl-P: Preview | Ctrl-U: Uninstall | Enter: Show info" `
            --preview "winget show --id {}" `
            --preview-window "right:60%:hidden" `
            --bind "ctrl-p:toggle-preview" `
            --expect=ctrl-u,enter

    if (-not $result)
    { return
    }

    $key = $result[0]
    $selected = @($result | Select-Object -Skip 1 | Where-Object { $_ })

    if (-not $selected -or $selected[0] -eq "")
    { return
    }

    if ($key -eq "ctrl-u")
    {
        if ($selected.Count -gt 1)
        {
            Write-Host ""
            Write-Host "󰏔 Selected for removal:" -ForegroundColor Cyan
            $selected | ForEach-Object { Write-Host "   - $_" -ForegroundColor Red }
            Write-Host ""
            $confirm = Read-Host "Uninstall $($selected.Count) package(s)? (Y/n)"
            if ($confirm -match '^[Nn]$')
            { Write-Host "󰅙 Aborted." -ForegroundColor Gray; return
            }
        }

        foreach ($id in $selected)
        {
            Write-Host "`n󰛌 Removing: $id" -ForegroundColor Cyan
            winget uninstall --id $id --exact
            Add-Content -Path (Get-PSReadLineOption).HistorySavePath -Value "winget uninstall --id $id --exact"
        }
    } else
    {
        foreach ($pkg in $selected)
        {
            $pkg = $pkg.Trim()
            Write-Host "`n󰘥 Fetching info for: $pkg" -ForegroundColor Yellow
            winget show --id $pkg --exact
        }
    }
}

function upas
{
    $updates = Get-WinGetPackage | Where-Object { $_.IsUpdateAvailable }
    if (-not $updates)
    { Write-Host "󰄬 Everything is up to date!" -ForegroundColor Green; return
    }

    $selected = $updates |
        Select-Object -ExpandProperty Id |
        fzf --multi --reverse `
            --header "󰚰 Ctrl-P: Preview | Tab: multi-select" `
            --preview "winget show --id {}" `
            --preview-window "right:60%:hidden" `
            --bind "ctrl-p:toggle-preview"

    if (-not $selected)
    { return
    }

    $ids = @($selected | ForEach-Object { $_.Trim() } | Where-Object { $_ })

    if ($ids.Count -gt 1)
    {
        Write-Host ""
        Write-Host "󰚰 Selected for upgrade:" -ForegroundColor Cyan
        $ids | ForEach-Object { Write-Host "   + $_" -ForegroundColor Yellow }
        Write-Host ""
        $confirm = Read-Host "Upgrade $($ids.Count) package(s)? (Y/n)"
        if ($confirm -match '^[Nn]$')
        { Write-Host "󰅙 Aborted." -ForegroundColor Gray; return
        }
    }

    foreach ($id in $ids)
    {
        Write-Host "`n󰑢 Upgrading: $id" -ForegroundColor Yellow
        winget upgrade --id $id --exact --interactive
    }
}

Set-PSReadLineKeyHandler -Key "Ctrl+h" -ScriptBlock {
    $historyFile = (Get-PSReadLineOption).HistorySavePath
    if (-not (Test-Path $historyFile))
    {
        Write-Host "󱞣 No history file found." -ForegroundColor Red; return
    }

    $content = Get-Content $historyFile
    [Array]::Reverse($content)

    $result = $content |
        Select-Object -Unique |
        fzf --multi --reverse --height 40% --header "󱎟 History (Enter: Use | Tab: Multi-select | Ctrl+D: Delete)" --expect=ctrl-d

    if (-not $result)
    { return
    }

    # FZF returns key pressed in first line, selection in remaining lines
    $lines = @($result)
    $key = $lines[0]
    $selected = @($lines | Select-Object -Skip 1)

    if ($key -eq "ctrl-d")
    {
        # Delete mode - handle multiple selections
        if ($selected -and $selected.Count -gt 0)
        {
            [Microsoft.PowerShell.PSConsoleReadLine]::DeleteLine()
            $historyContent = Get-Content $historyFile
            $newContent = $historyContent | Where-Object { $_ -notin $selected }
            Set-Content $historyFile $newContent
        }
        return
    } elseif ($selected -and $selected.Count -gt 0)
    {
        # Normal selection mode - insert selected command(s)
        [Microsoft.PowerShell.PSConsoleReadLine]::DeleteLine()
        if ($selected.Count -eq 1)
        {
            [Microsoft.PowerShell.PSConsoleReadLine]::Insert($selected[0].Trim())
        } else
        {
            $combined = ($selected | ForEach-Object { $_.Trim() }) -join " & "
            [Microsoft.PowerShell.PSConsoleReadLine]::Insert($combined)
        }
    }
}

function ff
{
    param(
        [Parameter(Position=0)]
        [string]$Path = "C:\"
    )

    $SearchPath = Resolve-Path $Path -ErrorAction SilentlyContinue
    if (-not $SearchPath)
    {
        Write-Host "󱞣 Path not found: $Path" -ForegroundColor Red; return
    }

    $selection = fd . $SearchPath --hidden --color never --exclude "Windows" |
        fzf --layout=reverse --height=40% --header "󱎟 Searching: $SearchPath"

    if (-not $selection)
    { return
    }

    $quoted = "`"$($selection.Trim())`""
    Set-Clipboard $quoted
    Write-Host "󰅍 Copied: $quoted" -ForegroundColor Cyan
}

function regtwk
{ & "$RepoPath\scripts\regtwk.ps1"
}

# ==============================================================================
# 7. THIRD PARTY TOOLS
# ==============================================================================
function ctt
{
    if (-not (Test-Admin))
    { Invoke-Elevated -Command "ctt"; return
    }
    _PrintHeader "󱓞" "Chris Titus Tech Toolbox"
    Invoke-RestMethod https://christitus.com/win | Invoke-Expression
}

function massgrave
{
    if (-not (Test-Admin))
    { Invoke-Elevated -Command "massgrave"; return
    }
    _PrintHeader "󰄲" "Massgrave Activation"
    Invoke-RestMethod https://get.activated.win | Invoke-Expression
}

# ==============================================================================
# 8. MEDIA
# ==============================================================================
function pirith
{
    $dir = "$HOME\Music\pirith"
    if (-not (Test-Path $dir))
    {
        Write-Host "󱞣 Pirith folder not found: $dir" -ForegroundColor Red; return
    }

    _PrintHeader "󰎆" "Pirith Player"
    $selected = Get-ChildItem -Path $dir -File |
        Where-Object { $_.Extension -in @('.mp3', '.wav', '.aac', '.flac', '.ogg') } |
        ForEach-Object { $_.Name } |
        fzf --reverse --height 40% --header "󰪐 Select to Play"

    if ($selected)
    {
        _PrintRow "󰝚" "Playing" $selected "Cyan"
        _PrintFooter
        mpv "$dir\$selected"
    }
}

function wp
{
    $wallpapersDir = Join-Path ([Environment]::GetFolderPath("MyPictures")) "config-wallpapers"

    if (-not (Test-Path $wallpapersDir))
    {
        _PrintHeader "󰋊" "Wallpapers"
        _PrintRow "󰅙" "Error" "Wallpapers directory not found" "Red"
        _PrintFooter; return
    }

    _PrintHeader "󰋊" "Wallpapers"

    $changes = git -C $wallpapersDir status --porcelain 2>$null
    if ($changes)
    {
        _PrintRow "󰊢" "Local" "Uncommitted changes found" "Yellow"
        git -C $wallpapersDir add -A 2>$null | Out-Null
        $commitResult = git -C $wallpapersDir commit -m "sync: local wallpaper changes" 2>&1
        if ($LASTEXITCODE -eq 0)
        {
            _PrintRow "󰄬" "Commit" "Changes committed" "Green"
        } else
        {
            _PrintRow "󰅙" "Commit" "Failed: $($commitResult | Select-Object -Last 1)" "Red"
        }
    }

    $pullResult = git -C $wallpapersDir pull --rebase --autostash 2>&1
    if ($LASTEXITCODE -eq 0)
    {
        _PrintRow "󰄬" "Pull" "Up to date" "Green"
    } else
    {
        _PrintRow "󰅙" "Pull" "Failed: $($pullResult | Select-Object -Last 1)" "Red"
    }

    $pushResult = git -C $wallpapersDir push 2>&1
    if ($LASTEXITCODE -eq 0)
    {
        _PrintRow "󰄬" "Push" "Synced to GitHub" "Green"
    } else
    {
        _PrintRow "󰅙" "Push" "Failed: $($pushResult | Select-Object -Last 1)" "Gray"
    }

    _PrintFooter
}

# ==============================================================================
# 9. NETWORK
# ==============================================================================
function wgsocks
{ & "$RepoPath\scripts\wgsocks.ps1" @args
}
function warp
{ & "$RepoPath\scripts\warp.ps1" @args
}

# ==============================================================================
# 10. INFO & DOCUMENTATION
# ==============================================================================
function info
{
    _PrintHeader "󱈄" "Custom Shell Commands"
    _PrintRow "󰒍" "Profile"   "conf, reload"
    _PrintRow "" "System"    "rr, open, exp, cleanup, touch, sz"
    _PrintRow "󰚰" "Updates"   "upall, cup, upa, ups, upw, upf, upc"
    _PrintRow "󰍉" "FZF"       "ff, inst, instd, upas, la, Ctrl+H"
    _PrintRow "󰎈" "Media"     "pirith, wp"
    _PrintRow "󱓞" "Tools"     "ctt, massgrave"
    _PrintRow "󰒄" "Network"   "wgsocks, warp"
    _PrintFooter
}

# ==============================================================================
# 11. OVERRIDES
# ==============================================================================
Remove-Item Alias:cd -Force -ErrorAction SilentlyContinue
Remove-Item Alias:z  -Force -ErrorAction SilentlyContinue

function cd
{
    if ($args.Count -eq 0)
    { return
    }
    if (-not (Test-Path $args[0]))
    {
        Write-Host "󱞣 Path not found: $($args[0])" -ForegroundColor Red; return
    }
    if (-not (Test-Path $args[0] -PathType Container))
    {
        Write-Host "󰅙 Not a directory: $($args[0])" -ForegroundColor Red; return
    }
    Set-Location $args[0]
    Get-ChildItem -Force
}

function z
{
    if ($args.Count -eq 0)
    { return
    }
    $before = $PWD.Path
    __zoxide_z $args
    if ($PWD.Path -eq $before)
    {return
    }
    Get-ChildItem -Force
}
function la
{ Get-ChildItem -Force @args
}
