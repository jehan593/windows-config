# ==============================================================================
# 1. ENVIRONMENT & INITIALIZATION
# ==============================================================================
$RepoPath = "$HOME\windows-config"
$env:STARSHIP_CONFIG = "$RepoPath\configs\starship.toml"
. "$RepoPath\scripts\helpers\printers.ps1"
. "$RepoPath\scripts\helpers\prompt.ps1" 
. "$RepoPath\scripts\helpers\elevate.ps1"
. "$RepoPath\scripts\helpers\keepawake.ps1"

$env:FZF_DEFAULT_OPTS = '--exact --cycle --color=bg+:#3b4252,bg:#2e3440,spinner:#81a1c1,hl:#c2a166,fg:#d8dee9,header:#5e81ac,info:#b48ead,pointer:#88c0d0,marker:#ebcb8b,fg+:#e5e9f0,prompt:#81a1c1,hl+:#ebcb8b'

function Import-CachedCommand
{
    param([string]$Command, [string]$CacheName)
    $src   = (Get-Command $Command -ErrorAction SilentlyContinue)?.Source
    if (-not $src) { return }
    $cache = "$env:TEMP\$CacheName.ps1"
    if (-not (Test-Path $cache) -or (Get-Item $src).LastWriteTime -gt (Get-Item $cache).LastWriteTime)
    {
        & $Command init powershell | Set-Content $cache -Encoding utf8
    }
    . $cache
}

Import-CachedCommand -Command "starship" -CacheName "starship_init"

# ==============================================================================
# 2. DEFERRED LOADING
# Runs once, just before your first interactive prompt — shell feels instant.
# ==============================================================================
$_deferredWork = {
    Import-Module Terminal-Icons -ErrorAction SilentlyContinue
    Import-CachedCommand -Command "zoxide"   -CacheName "zoxide_init"

    # Remove the alias zoxide sets (aliases beat functions in PowerShell)
    Remove-Item Alias:z -Force -ErrorAction SilentlyContinue

    function global:z
    {
        $before = $PWD.Path
        __zoxide_z @args
        if ($PWD.Path -ne $before) { Get-ChildItem }
    }
}

$_origPromptDef = (Get-Item Function:\prompt -ErrorAction SilentlyContinue)?.ScriptBlock

function prompt
{
    if ($script:_deferredWork)
    {
        & $script:_deferredWork
        $script:_deferredWork = $null
    }
    if ($script:_origPromptDef) { & $script:_origPromptDef } else { "PS $($PWD.Path)> " }
}

# ==============================================================================
# 3. INTERNAL HELPERS
# ==============================================================================
function Invoke-Elevated
{
    param([string]$Command)
    if (-not (_AssertGsudo)) { return }
    gsudo pwsh -Command "$Command"
}

function _WingetAction
{
    param([string]$Verb, [string[]]$Ids, [string[]]$ExtraArgs = @())

    foreach ($id in $Ids)
    {
        Write-Host "${Verb}: $id" -ForegroundColor Cyan
        winget $Verb --id $id --exact --interactive @ExtraArgs
        
        if ($LASTEXITCODE -eq 0) { Write-Host "Done: $id" -ForegroundColor Green }
        else                     { Write-Host "Error: $id" -ForegroundColor Red }
        
        # Format and append command to both PSReadLine file and active session history
        $argsStr = if ($ExtraArgs) { " " + ($ExtraArgs -join " ") } else { "" }
        $cmdEntry = "winget $Verb --id $id --exact --interactive$argsStr"
        
        Add-Content -Path (Get-PSReadLineOption).HistorySavePath -Value $cmdEntry
        try { [Microsoft.PowerShell.PSConsoleReadLine]::AddToHistory($cmdEntry) } catch { }
    }
}

function _InfoGroup([string]$Title)
{
    Write-Host "$Title" -ForegroundColor Yellow
}

function _InfoCmd([string]$Cmd, [string]$Desc)
{
    Write-Host "  " -NoNewline
    Write-Host ("{0,-12}" -f $Cmd) -NoNewline -ForegroundColor Cyan
    Write-Host " $Desc" -ForegroundColor Gray
}

function _FormatSize([long]$bytes = 0)
{
    if     ($bytes -ge 1TB) { "{0:N2} TB" -f ($bytes / 1TB) }
    elseif ($bytes -ge 1GB) { "{0:N2} GB" -f ($bytes / 1GB) }
    elseif ($bytes -ge 1MB) { "{0:N2} MB" -f ($bytes / 1MB) }
    elseif ($bytes -ge 1KB) { "{0:N2} KB" -f ($bytes / 1KB) }
    else                    { "$bytes B" }
}

# ==============================================================================
# 4. PROFILE MANAGEMENT
# ==============================================================================
function reload
{
    Write-Host "Reloading..." -ForegroundColor Cyan
    $loc = $PWD.Path -replace "'", "''"
    pwsh -NoExit -Command "Set-Location '$loc'"
    exit
}

function conf
{
    Write-Host "Opening configs..." -ForegroundColor Cyan
    zed $RepoPath
}

# ==============================================================================
# 5. SHELL OVERRIDES
# ==============================================================================
Remove-Item Alias:cd -Force -ErrorAction SilentlyContinue

function cd
{
    param([string]$Path)
    if (-not $Path)
    { Set-Location ~; Get-ChildItem -Force; return }

    if (-not (Test-Path $Path -PathType Container))
    {
        $msg = if (Test-Path $Path) { "Error: Not a directory" } else { "Error: Path not found" }
        Write-Host "${msg}: $Path" -ForegroundColor Red; return
    }
    Set-Location $Path
    Get-ChildItem
}

function la
{
    Get-ChildItem -Force @args
}

Set-Alias sudo  gsudo
Set-Alias open  Invoke-Item
Set-Alias touch New-Item

# ==============================================================================
# 6. CORE UTILITIES
# ==============================================================================
function rr
{
    if (-not (_AssertGsudo)) { return }
    $lastCommand = (Get-History -Count 1).CommandLine
    if (-not $lastCommand)
    {
        Write-Host "Error: No history found." -ForegroundColor Red; return
    }
    Write-Host ""
    Write-Host "Run as Admin:" -ForegroundColor Yellow
    Write-Host "  $lastCommand" -ForegroundColor Cyan
    Write-Host ""
    if (-not (_Confirm "Elevate? (Y/n)" -Y)) { return }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($lastCommand))
    gsudo pwsh -EncodedCommand $encoded
}

function exp
{
    param([string]$Path = ".")
    $resolved = (Resolve-Path $Path -ErrorAction SilentlyContinue).Path
    if (-not $resolved) { Write-Host "Error: Path not found: $Path" -ForegroundColor Red; return }
    $target = if (Test-Path $resolved -PathType Container) { $resolved } else { Split-Path $resolved }
    Invoke-Item $target
}

function sz
{
    param([Parameter(Mandatory)][string]$Path)
    $target = (Resolve-Path $Path -ErrorAction SilentlyContinue).Path
    if (-not $target) { Write-Host "Error: Path not found: $Path" -ForegroundColor Red; return }

    _PrintHeader "Storage Analysis"
    if (Test-Path $target -PathType Leaf)
    {
        $file = Get-Item $target
        _PrintRow "File" $file.Name "White"
        _PrintRow "Size" (_FormatSize $file.Length) "Cyan"
    } else
    {
        $items   = Get-ChildItem $target -Recurse -Force -ErrorAction SilentlyContinue
        $files   = $items | Where-Object { -not $_.PSIsContainer }
        $folders = $items | Where-Object { $_.PSIsContainer }
        $size    = [long](($files | Measure-Object -Property Length -Sum).Sum)
        _PrintRow "Files"      $files.Count   "White"
        _PrintRow "Folders"    $folders.Count "White"
        _PrintRow "Total Size" (_FormatSize $size) "Cyan"
    }
    _PrintFooter
}

function cleanup
{
    if (-not (_IsAdmin)) { Invoke-Elevated -Command $MyInvocation.MyCommand.Name; return }
    _PrintHeader "System Cleanup"

    Write-Host "Cleaning component store..." -ForegroundColor Cyan
    dism.exe /online /Cleanup-Image /StartComponentCleanup
    if ($LASTEXITCODE -eq 0)
    { Write-Host "Component store clean" -ForegroundColor Green }
    else
    { Write-Host "Error: Component store clean failed" -ForegroundColor Red }

    Write-Host "Running disk cleanup..." -ForegroundColor Cyan
    cleanmgr.exe /d C: /VERYLOWDISK
    if ($LASTEXITCODE -eq 0)
    { Write-Host "Disk cleanup OK" -ForegroundColor Green }
    else
    { Write-Host "Error: Disk cleanup failed" -ForegroundColor Red }

    Write-Host "Purging temp folders..." -ForegroundColor Cyan
    foreach ($path in @($env:TEMP, "$env:SystemRoot\Temp"))
    {
        Get-ChildItem $path -Recurse -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host "Temp folders clean" -ForegroundColor Green

    _PrintFooter
}

function fixgpu
{
    if (-not (_IsAdmin)) { Invoke-Elevated -Command $MyInvocation.MyCommand.Name; return }

    _PrintHeader "GPU Stutter Fix"

    Write-Host "Clearing GPU apps..." -ForegroundColor Cyan
    $smiOutput = & "C:\Windows\System32\nvidia-smi.exe" --query-compute-apps=pid --format=csv,noheader 2>$null
    if ($smiOutput)
    {
        $smiOutput | ForEach-Object {
            $procId = $_.Trim()
            if ($procId -match '^\d+$')
            {
                Stop-Process -Id ([int]$procId) -Force -ErrorAction SilentlyContinue
            }
        }
    }
    Write-Host "GPU apps cleared" -ForegroundColor Green

    Start-Sleep -Milliseconds 500

    Write-Host "Resetting graphics..." -ForegroundColor Cyan
    $kickScript = {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class GPUKick {
    [DllImport("d3d9.dll")] public static extern IntPtr Direct3DCreate9(uint sdkVersion);
}
"@
        [GPUKick]::Direct3DCreate9(32)
        Start-Sleep -Milliseconds 800
    }
    Start-Process pwsh -WindowStyle Hidden -ArgumentList "-Command & { $kickScript }" -Wait
    Write-Host "Graphics reset" -ForegroundColor Green

    _PrintFooter
}

function regtwk
{
    & "$RepoPath\scripts\regtwk.ps1"
}

# ==============================================================================
# 7. PACKAGE MANAGEMENT (WINGET + FZF)
# ==============================================================================
function inst
{
    param(
        [switch]$Refresh,
        [switch]$IgnoreHash
    )

    $cacheFile = "$env:LOCALAPPDATA\windows-config\winget_search_cache.txt"
    $null = New-Item -ItemType Directory -Path "$env:LOCALAPPDATA\windows-config" -Force

    if ($Refresh)
    {
        Remove-Item $cacheFile -ErrorAction SilentlyContinue
        Write-Host "Cache cleared" -ForegroundColor Cyan
    }

    if (-not (Test-Path $cacheFile) -or (Get-Item $cacheFile).LastWriteTime -lt (Get-Date).AddDays(-7))
    {
        Write-Host "Fetching package list..." -ForegroundColor Cyan
        Find-WinGetPackage -Source winget | ForEach-Object { $_.Id } | Set-Content $cacheFile
    }

    $cacheIds  = Get-Content $cacheFile
    $extraArgs = if ($IgnoreHash) { @('--ignore-security-hash') } else { @() }

    $ids = $cacheIds | fzf --multi --reverse `
        --header "Package Menu: [Ctrl-P]: Preview Info | [Tab]: Multi-select" `
        --preview "winget show --id {}" `
        --preview-window "right:60%:hidden" `
        --bind "ctrl-p:toggle-preview"

    $ids = @($ids | Where-Object { $_ })
    if (-not $ids.Count) { return }

    Write-Host "Selected to install:" -ForegroundColor Cyan
    $ids | ForEach-Object { Write-Host "  + $_" -ForegroundColor Green }
    
    if (-not (_Confirm "`nInstall $($ids.Count) package(s)? (Y/n)" -Y)) { return }
    _WingetAction -Verb "install" -Ids $ids -ExtraArgs (@('--source', 'winget') + $extraArgs)
}

function uinst
{
    $ids = @(Get-WinGetPackage |
            Select-Object -ExpandProperty Id |
            fzf --multi --reverse `
                --header "Package Menu: [Ctrl-P]: Preview Info | [Tab]: Multi-select" `
                --preview "winget show --id {}" `
                --preview-window "right:60%:hidden" `
                --bind "ctrl-p:toggle-preview" |
            ForEach-Object { $_.Trim() } | Where-Object { $_ })
            
    $names = $ids
    if (-not $ids.Count) { return }

    Write-Host "Selected to remove:" -ForegroundColor Cyan
    $names | ForEach-Object { Write-Host "  - $_" -ForegroundColor Gray }
    
    if (-not (_Confirm "`nUninstall $($ids.Count) package(s)? (Y/n)" -Y)) { return }
    _WingetAction -Verb "uninstall" -Ids $ids
}

function upp
{
    param([switch]$all)

    $updates = @(Get-WinGetPackage | Where-Object { $_.IsUpdateAvailable })
    if (-not $updates.Count) { Write-Host "Up to date!" -ForegroundColor Green; return }

    $allIds = $updates | Select-Object -ExpandProperty Id

    if ($all)
    {
        $ids = $allIds
    }
    else
    {
        $allOption = "All Updates"
        $fzfInput  = @($allOption) + $allIds

        $previewScript = Join-Path $env:TEMP "upp_preview_$PID.ps1"

        @"
param([string]`$Item)
if (`$Item -match 'All Updates$') {
    Write-Output 'Upgrade all $($allIds.Count) packages'
} else {
    winget show --id `$Item
}
"@ | Set-Content -Path $previewScript -Encoding UTF8

        $selected = @($fzfInput |
                fzf --multi --reverse `
                    --header "[Ctrl-P]: Preview | [Tab]: Multi-select" `
                    --preview "powershell -NoProfile -ExecutionPolicy Bypass -File `"$previewScript`" -Item {}" `
                    --preview-window "right:60%:hidden" `
                    --bind "ctrl-p:toggle-preview" `
                    --height "70%" `
                    --prompt "Upgrade › ")

        $selected = $selected | ForEach-Object { $_.Trim() }
        Remove-Item $previewScript -ErrorAction SilentlyContinue

        if ($selected | Where-Object { $_ -match 'All Updates$' })
        {
            $ids = $allIds
        }
        else
        {
            $ids = $selected | Where-Object { $_ }
        }
    }

    $names = $ids
    if (-not $ids.Count) { return }

    Write-Host "Selected to update:" -ForegroundColor Cyan
    $names | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
    
    if (-not (_Confirm "`nUpgrade $($ids.Count) package(s)? (Y/n)" -Y)) { return }
    _WingetAction -Verb "upgrade" -Ids $ids
}

# ==============================================================================
# 8. UPDATES & MAINTENANCE
# ==============================================================================
function cup
{
    if (-not (_IsAdmin)) { Invoke-Elevated -Command $MyInvocation.MyCommand.Name; return }
    _PrintHeader "Update Checker"

    _PrintHeader "Winget" -Sub
    winget upgrade

    _PrintHeader "Microsoft Store" -Sub
    if (Get-Command store -ErrorAction SilentlyContinue)
    {
        'n' | store updates 2>$null
    }
    else
    {
        Write-Host "Store CLI missing" -ForegroundColor Gray
    }

    _PrintFooter
}

function upall
{
    if (-not (_IsAdmin)) { Invoke-Elevated -Command $MyInvocation.MyCommand.Name; return }

    _PrintHeader "Winget Updates"
    winget source update
    Write-Host ""
    try { upp }
    catch { Write-Host "Error: upp failed" -ForegroundColor Red }
    _PrintFooter
    
    try { upf }
    catch { Write-Host "Error: upf failed" -ForegroundColor Red }
    try { ups }
    catch { Write-Host "Error: ups failed" -ForegroundColor Red }

    try { upwp }
    catch { Write-Host "Error: Wallpaper sync failed" -ForegroundColor Red }

    try { wgsocks update }
    catch { Write-Host "Error: wgsocks update failed" -ForegroundColor Red }

    try { upc }
    catch { Write-Host "Error: upc failed" -ForegroundColor Red }

    if (_Confirm "`nRun topgrade as well? (y/N)" -N)
    {
        try { topgrade }
        catch { Write-Host "Error: topgrade failed" -ForegroundColor Red }
    }    
}

function ups
{
    if (-not (Get-Command store -ErrorAction SilentlyContinue))
    {
        Write-Host "Error: Store CLI missing" -ForegroundColor Gray; return
    }
    _PrintHeader "Store App Updates"
    store updates --apply
    if ($LASTEXITCODE -eq 0)
    { Write-Host "Store apps updated" -ForegroundColor Green }
    else
    { Write-Host "Error: Store updates failed" -ForegroundColor Red }
    _PrintFooter
}

function upf
{
    $url           = "https://raw.githubusercontent.com/yokoffing/Betterfox/main/user.js"
    $removalsPath  = "$RepoPath\configs\firefox\user-removals.txt"
    $overridesPath = "$RepoPath\configs\firefox\overrides.txt"
    $profilesPath  = "$env:APPDATA\Mozilla\Firefox\Profiles"
    _PrintHeader "Firefox Betterfox Sync"
    if (-not (Test-Path $profilesPath))
    { Write-Host "Error: Profiles path missing" -ForegroundColor Red; _PrintFooter; return }
    $profiles = Get-ChildItem $profilesPath -Directory
    if ($profiles.Count -eq 0)
    { Write-Host "Error: No profiles found" -ForegroundColor Red; _PrintFooter; return }
    try
    {
        $lines = (Invoke-WebRequest -Uri $url -UseBasicParsing -ErrorAction Stop).Content -split "`n"
    } catch
    {
        Write-Host "Error: Download failed" -ForegroundColor Red; _PrintFooter; return
    }
    if (Test-Path $removalsPath)
    {
        $removals = Get-Content $removalsPath | Where-Object { $_.Trim() -ne "" }
        foreach ($key in $removals)
        {
            $escaped = [regex]::Escape($key.Trim())
            $lines   = $lines | Where-Object { $_ -notmatch "user_pref\(`"$escaped`"" }
        }
    }
    $content = $lines -join "`n"
    if (Test-Path $overridesPath)
    {
        $overrides = (Get-Content $overridesPath -Raw).Trim()
        if ($overrides)
        { $content = $content.TrimEnd() + "`n`n// overrides.txt`n" + $overrides + "`n" }
    }
    foreach ($prof in $profiles)
    {
        try
        {
            Set-Content -Path (Join-Path $prof.FullName "user.js") -Value $content -ErrorAction Stop
            Write-Host "Synced: $($prof.Name)" -ForegroundColor Green
        } catch
        {
            Write-Host "Error: Failed: $($prof.Name)" -ForegroundColor Red
        }
    }
    _PrintFooter
}

function upc
{
    _PrintHeader "Dotfiles Repo Sync"
    git -C $RepoPath pull --rebase --autostash
    if ($LASTEXITCODE -eq 0)
    {
        Write-Host "Repo synced" -ForegroundColor Green
        _PrintFooter
        Write-Host "Notice: Run 'reload' to apply changes" -ForegroundColor Yellow
    } else
    {
        Write-Host "Error: Sync error or conflict." -ForegroundColor Red
        _PrintFooter
    }
}

function topgrade {
    _PrintHeader "Topgrade"
    try { gsudo topgrade $args }
    catch { Write-Host "Error: topgrade failed: $_" -ForegroundColor Red }
    _PrintFooter
}

# ==============================================================================
# 9. INTERACTIVE TOOLS (FZF)
# ==============================================================================
function ff
{
    param(
        [Parameter(Position = 0)]
        [string]$Path = "C:\"
    )
    $search = (Resolve-Path $Path -ErrorAction SilentlyContinue).Path
    if (-not $search) { Write-Host "Error: Path not found: $Path" -ForegroundColor Red; return }

    $selection = fd . $search --hidden --color never --exclude "Windows" |
        fzf --no-multi --layout=reverse --height=40% --header "Searching: $search"

    if (-not $selection) { return }

    "`"$($selection.Trim())`"" | Set-Clipboard
    Write-Host "Copied path to clipboard" -ForegroundColor Green
}

Set-PSReadLineKeyHandler -Key "Ctrl+h" -ScriptBlock {
    $historyFile = (Get-PSReadLineOption).HistorySavePath
    if (-not (Test-Path $historyFile)) { Write-Host "Error: History file missing" -ForegroundColor Red; return }

    $content = Get-Content $historyFile
    [Array]::Reverse($content)

    $result = @($content |
            Select-Object -Unique |
            fzf --multi --reverse --height 40% `
                --header "History ([Enter]: Use | [Tab]: Select | [Ctrl-D]: Delete)" `
                --expect=ctrl-d)

    if (-not $result.Count) { return }

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
    { [Microsoft.PowerShell.PSConsoleReadLine]::Insert($selected[0].Trim()) }
    else
    { [Microsoft.PowerShell.PSConsoleReadLine]::Insert(($selected | ForEach-Object { $_.Trim() }) -join " & ") }
}

# ==============================================================================
# 10. NETWORK & UTILITIES
# ==============================================================================
function wgsocks
{
    & "$RepoPath\scripts\wgsocks.ps1" @args
}

function vpn
{
    & "$RepoPath\scripts\vpn.ps1" @args
}

function timer
{
    & "$RepoPath\scripts\timer.ps1" @args
}

function keepawake
{
    Write-Host "Keeping screen awake. Press Ctrl+C to cancel..." -ForegroundColor Cyan

    try
    {
        while ($true)
        {
            _EnableKeepAwake
            Start-Sleep -Seconds 30
        }
    } finally
    {
        _DisableKeepAwake
        Write-Host "Keepawake cancelled, normal sleep behavior restored." -ForegroundColor Yellow
    }
}

# ==============================================================================
# 11. MEDIA
# ==============================================================================
function upwp
{
    $dir = Join-Path ([Environment]::GetFolderPath("MyPictures")) "config-wallpapers"
    _PrintHeader "Wallpaper Sync"

    if (-not (Test-Path $dir))
    { Write-Host "Error: Folder missing" -ForegroundColor Red; _PrintFooter; return }

    git -C $dir pull --rebase --autostash
    if ($LASTEXITCODE -eq 0)
    { Write-Host "Wallpapers updated" -ForegroundColor Green }
    else
    { Write-Host "Error: Pull failed." -ForegroundColor Red }

    _PrintFooter
}

# ==============================================================================
# 12. THIRD PARTY TOOLS
# ==============================================================================
function ctt
{
    if (-not (_IsAdmin)) { Invoke-Elevated -Command "ctt"; return }
    _PrintHeader "CTT Windows Toolbox"
    Invoke-RestMethod https://christitus.com/win | Invoke-Expression
}

function massgrave
{
    if (-not (_IsAdmin)) { Invoke-Elevated -Command "massgrave"; return }
    _PrintHeader "Massgrave Activation"
    Invoke-RestMethod https://get.activated.win | Invoke-Expression
}

# ==============================================================================
# 13. INFO & DOCUMENTATION
# ==============================================================================
function info
{
    _PrintHeader "Shell Toolkit Utilities"

    _InfoGroup "Configuration"
    _InfoCmd "conf"    "Open workspace in Zed"
    _InfoCmd "reload"  "Restart shell session"
    _InfoCmd "sudo"    "Elevate command"
    Write-Host ""

    _InfoGroup "System & Files"
    _InfoCmd "z"       "Zoxide jump + ls"
    _InfoCmd "la"      "List all files"
    _InfoCmd "open"    "Open file or folder"
    _InfoCmd "touch"   "Create new file"
    _InfoCmd "rr"      "Elevate last command"
    _InfoCmd "exp"     "Open in File Explorer"
    _InfoCmd "sz"      "Calculate folder sizes"
    _InfoCmd "cleanup" "Purge system temp/bloat"
    _InfoCmd "regtwk"  "Registry optimization"
    _InfoCmd "fixgpu"  "Fix GPU hybrid stutter"
    _InfoCmd "timer"   "Countdown timer"
    _InfoCmd "keepawake" "Keep screen on (Ctrl+C to stop)"
    Write-Host ""

    _InfoGroup "Maintenance"
    _InfoCmd "upall"   "Run all system updates"
    _InfoCmd "cup"     "Check updates info"
    _InfoCmd "upp"     "Winget update menu (FZF, -all for all )"
    _InfoCmd "ups"     "Update App Store apps"
    _InfoCmd "upf"     "Sync Betterfox configs"
    _InfoCmd "upc"     "Pull dotfiles repository"
    Write-Host ""

    _InfoGroup "Fuzzy Menu (FZF)"
    _InfoCmd "ff"      "Find file and copy path"
    _InfoCmd "inst"    "Winget install menu"
    _InfoCmd "uinst"   "Winget uninstall menu"
    _InfoCmd "Ctrl+H"  "Fuzzy command history"
    Write-Host ""

    _InfoGroup "Media & Extras"
    _InfoCmd "upwp"    "Pull wallpaper repo"
    _InfoCmd "ctt"     "CTT WinUtil script"
    _InfoCmd "massgrave" "Activation suite"
    Write-Host ""

    _InfoGroup "Networking"
    _InfoCmd "wgsocks" "WireGuard proxy"
    _InfoCmd "vpn"     "VPN tunnel control"

    Write-Host ""

    _PrintFooter
}

# ==============================================================================
# 14. STARTUP MESSAGE
# ==============================================================================
if (-not (_IsAdmin))
{
    Write-Host "`n`e[38;2;235;203;139mType 'info' to see custom utilities.`e[0m`n"
}