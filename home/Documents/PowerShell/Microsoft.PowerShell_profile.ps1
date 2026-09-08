# ==============================================================================
# 1. ENVIRONMENT & INITIALIZATION
# ==============================================================================
$ConfigPath = $env:WINDOWS_CONFIG_PATH
. "$ConfigPath\helpers\dep-checker.ps1"

$missingDeps = @(_TestDependencies -Commands "starship", "fzf", "git", "fd", "gsudo", "winget")
if ($missingDeps.Count -gt 0)
{
    foreach ($dep in $missingDeps) { Write-Host "$dep not found" -ForegroundColor Red }
    Write-Host "Profile loading failed due to missing dependencies." -ForegroundColor Red
    return
}

. "$ConfigPath\helpers\keep-awake.ps1"
. "$ConfigPath\helpers\repo-list.ps1"
. "$ConfigPath\helpers\wireproxy-install.ps1"
. "$ConfigPath\helpers\font-install.ps1"

$env:FZF_DEFAULT_OPTS = '--exact --cycle --border=rounded --color=bg+:#3b4252,bg:#2e3440,spinner:#81a1c1,hl:#c2a166,fg:#d8dee9,header:#5e81ac,info:#b48ead,pointer:#88c0d0,marker:#ebcb8b,fg+:#e5e9f0,prompt:#81a1c1,hl+:#ebcb8b,border:#4c566a --bind "ctrl-a:toggle-all"'

function Import-CachedCommand
{
    param([string]$Command, [string]$CacheName)
    $src = (Get-Command $Command -ErrorAction SilentlyContinue)?.Source
    if (-not $src) { return }

    $cacheDir = "$env:LOCALAPPDATA\windows-config-files\ps-cache"
    $null = New-Item -ItemType Directory -Path $cacheDir -Force
    $cache = "$cacheDir\$CacheName.ps1"

    if (-not (Test-Path $cache) -or (Get-Item $src).LastWriteTime -gt (Get-Item $cache).LastWriteTime)
    {
        & $Command init powershell | Set-Content $cache -Encoding utf8
    }
    . $cache
}

Import-CachedCommand -Command "starship" -CacheName "starship_init"

# ==============================================================================
# 2. DEFERRED LOADING
# ==============================================================================
$_deferredWork = {
    Import-Module Terminal-Icons -ErrorAction SilentlyContinue
    Import-CachedCommand -Command "zoxide"   -CacheName "zoxide_init"
    Add-Type -AssemblyName Microsoft.VisualBasic
    Set-PSReadLineOption -PredictionSource HistoryAndPlugin
    Set-PSReadLineOption -PredictionViewStyle Inline
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
function _WingetAction
{
    param([string]$Verb, [string[]]$Ids, [string[]]$ExtraArgs = @())

    foreach ($id in $Ids)
    {
        Write-Host ""
        winget $Verb --id $id --exact --interactive @ExtraArgs
                
        $argsStr = if ($ExtraArgs) { " " + ($ExtraArgs -join " ") } else { "" }
        $cmdEntry = "winget $Verb --id $id --exact --interactive$argsStr"
        
        [Microsoft.PowerShell.PSConsoleReadLine]::AddToHistory($cmdEntry)
    }
}

function _WingetUpgradeIds
{
    $packages = Get-WinGetPackage -Source winget | Where-Object { $_.IsUpdateAvailable }
    if ($packages) {
        $packages | ForEach-Object { $_.Id }
    }
}

# ==============================================================================
# 4. PROFILE MANAGEMENT
# ==============================================================================
function reload
{
    $loc = $PWD.Path -replace "'", "''"
    pwsh -NoExit -Command "Set-Location '$loc'"
    exit
}

# ==============================================================================
# 5. SHELL ADDITIONS
# ==============================================================================
function lsf{ Get-ChildItem -Force @args }
function rmf { Remove-Item -Force @args }
function rmr { Remove-Item -Recurse @args }
function rmrf { Remove-Item -Recurse -Force @args }
function cpr { Copy-Item -Recurse @args }
function .. { Set-Location .. }
function ... { Set-Location ../.. }

function trash {
    foreach ($item in $args) {
        $path = Get-Item -LiteralPath $item -Force -ErrorAction SilentlyContinue
        try {
            if ($path.PSIsContainer) {
                [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($path.FullName, 'OnlyErrorDialogs', 'SendToRecycleBin')
            } else {
                [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($path.FullName, 'OnlyErrorDialogs', 'SendToRecycleBin')
            }
        } catch {
            Write-Host "Failed: $_" -ForegroundColor Red
        }
    }
}

function sz {
    param(
        [Parameter(ValueFromPipeline=$true)]
        [string]$path = "."
    )

    # -Strict surfaces access-denied instead of swallowing it, so un-elevated
    # attempts detect when to escalate without spawning gsudo every call.
    $sizeScript = {
        param($targetPath, [switch]$Strict)
        $eap = if ($Strict) { 'Stop' } else { 'SilentlyContinue' }

        $obj = Get-Item -LiteralPath $targetPath -ErrorAction Stop
        $fullName = $obj.FullName
        $size = 0
        if ($obj.PSIsContainer) {
            $size = (Get-ChildItem -Path $fullName -Recurse -Force -File -ErrorAction $eap |
                     Measure-Object -Property Length -Sum).Sum
            if ($null -eq $size) { $size = 0 }
        } else {
            $size = $obj.Length
        }

        $friendlySize = if ($size -lt 1KB) { "$size bytes" }
                        elseif ($size -lt 1MB) { "{0:N2} KB" -f ($size / 1KB) }
                        elseif ($size -lt 1GB) { "{0:N2} MB" -f ($size / 1MB) }
                        else { "{0:N2} GB" -f ($size / 1GB) }

        Write-Host "$friendlySize ($fullName)"
    }

    try {
        & $sizeScript $path -Strict
    }
    catch [System.UnauthorizedAccessException] {
        Write-Host "Access denied, retrying elevated..." -ForegroundColor Yellow
        gsudo $sizeScript -args $path
    }
    catch {
        Write-Host "Failed: $_" -ForegroundColor Red
    }
}

function wage
{
   try{ 
    $installDate = (Get-CimInstance Win32_OperatingSystem).InstallDate
    $days = (New-TimeSpan -Start $installDate -End (Get-Date)).Days
        Write-Host "$days day(s)"
    }
    catch {
        Write-Host "Failed: $_" -ForegroundColor Red
    }
}

# ==============================================================================
# 6. CORE UTILITIES
# ==============================================================================
function rr
{
    $lastCommand = (Get-History -Count 1).CommandLine
    if (-not $lastCommand)
    {
        Write-Host "No history found in current session." -ForegroundColor Yellow
        return
    }
    gsudop $lastCommand
}

function gsudop
{
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$CommandArgs
    )
    if ($CommandArgs.Count -eq 1) {
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($CommandArgs[0]))
        gsudo --loadProfile pwsh -EncodedCommand $encoded
    }
    elseif ($CommandArgs) {
        gsudo --loadProfile $CommandArgs
    }
    else {
        gsudo 
    }
}

function cleanup
{
    gsudo {
        param($userTemp, $sysTemp)
        Write-Host "`n>DISM Cleanup" -ForegroundColor Blue
        try {
            dism.exe /online /Cleanup-Image /StartComponentCleanup
        } catch {
            Write-Host "DISM Failed: $($_.Exception.Message)" -ForegroundColor Red
        }

        Write-Host "`n>Disk Cleanup" -ForegroundColor Blue
        try {
            cleanmgr.exe /d C: /VERYLOWDISK
            Write-Host "Disk Cleanup Started" -ForegroundColor Green
        } catch {
            Write-Host "Disk Cleanup Failed: $($_.Exception.Message)" -ForegroundColor Red
        }

        Write-Host "`n>Temp Folder Cleanup" -ForegroundColor Blue
        foreach ($path in @($userTemp, $sysTemp))
        {
            try {
                Remove-Item -Path "$path\*" -Recurse -Force -ErrorAction Stop
                Write-Host "Cleared items inside: $path" -ForegroundColor Green
            }
            catch {
                Write-Host "Failed to clear ${path}: $($_.Exception.Message)" -ForegroundColor Red
            }
        }

        Write-Host "`n>Recycle Bin Cleanup" -ForegroundColor Blue
        try {
            Clear-RecycleBin -Force -ErrorAction Stop
            Write-Host "Recycle Bin Cleaned" -ForegroundColor Green
        }
        catch {
            Write-Host "Recycle Bin Cleanup Failed: $($_.Exception.Message)" -ForegroundColor Red
        }
                 
    } -args $env:TEMP, "$env:SystemRoot\Temp"
}

function fixgpu
{
    gsudo {
        Write-Host "`n>GPU Processes Cleanup" -ForegroundColor Blue
        try {
            $smiPath = "C:\Windows\System32\nvidia-smi.exe"
            $smiOutput = (& $smiPath --query-compute-apps=pid --format=csv,noheader 2>$null) | 
                             Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            if ($null -eq $smiOutput -or $smiOutput.Count -eq 0) {
                Write-Host "No active GPU processes found to clean." -ForegroundColor Yellow
            } else {
                foreach ($line in $smiOutput) {
                    $procId = $line.Trim()
                    if ($procId -match '^\d+$') {
                        try {
                            Stop-Process -Id ([int]$procId) -Force -ErrorAction Stop
                            Write-Host "Stopped GPU Process: $procId" -ForegroundColor Green
                        }
                        catch {
                            Write-Host "Failed to stop ${procId}: $($_.Exception.Message)" -ForegroundColor Red
                        }
                    }
                }
            }
            Start-Sleep -Milliseconds 500
        }catch {
            Write-Host "Process cleanup critical failure: $($_.Exception.Message)" -ForegroundColor Red
        }

        Write-Host "`n>GPU Quick Kick" -ForegroundColor Blue
        try {
            $Definition = @"
            using System;
            using System.Runtime.InteropServices;
            public class GPUKick {
                [DllImport("d3d9.dll")] public static extern IntPtr Direct3DCreate9(uint sdkVersion);
            }
"@
            if (-not ([System.Management.Automation.PSTypeName]'GPUKick').Type) {
                Add-Type -TypeDefinition $Definition -ErrorAction Stop
            }
            
            [GPUKick]::Direct3DCreate9(32) | Out-Null
            Start-Sleep -Milliseconds 800
            Write-Host "GPU Quick Kick completed" -ForegroundColor Green
        }catch {
            Write-Host "GPU Kick Failed: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

function regtwk
{
    & "$ConfigPath\tools\regtwk.ps1"
}

# ==============================================================================
# 7. PACKAGE MANAGEMENT (WINGET + FZF)
# ==============================================================================
function _FzfWingetPicker
{
    param(
        [Parameter(Mandatory)][string[]]$Ids,
        [Parameter(Mandatory)][string]$Header,
        [string]$Height,
        [string]$Prompt
    )

    $fzfArgs = @(
        "--multi", "--reverse",
        "--header", $Header,
        "--preview", "winget show --id {}",
        "--preview-window", "right:60%:hidden",
        "--bind", "ctrl-p:toggle-preview"
    )
    if ($Height) { $fzfArgs += @("--height", $Height) }
    if ($Prompt) { $fzfArgs += @("--prompt", $Prompt) }

    $selected = $Ids | fzf @fzfArgs
    return @($selected | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function inst
{
    param(
        [switch]$Refresh
    )

    $cacheFile = "$env:LOCALAPPDATA\windows-config-files\winget_search_cache.txt"
    $null = New-Item -ItemType Directory -Path "$env:LOCALAPPDATA\windows-config-files" -Force

    if ($Refresh)
    {
        Remove-Item $cacheFile -ErrorAction SilentlyContinue
        Write-Host "Cache cleared" -ForegroundColor Green
    }

    if (-not (Test-Path $cacheFile) -or (Get-Item $cacheFile).LastWriteTime -lt (Get-Date).AddDays(-7))
    {
        Write-Host "Fetching package list..." -ForegroundColor Gray
        Find-WinGetPackage -Source winget | ForEach-Object { $_.Id } | Set-Content $cacheFile
    }

    $cacheIds = Get-Content $cacheFile
    $ids = _FzfWingetPicker -Ids $cacheIds -Header "[Ctrl-P]: Preview Info | [Tab]: Multi-select"
    if (-not $ids.Count) { return }

    Write-Host ""
    Write-Host "Selected to install:" -ForegroundColor Green
    $ids | ForEach-Object { Write-Host "+ $_" }

    _WingetAction -Verb "install" -Ids $ids -ExtraArgs @('--source', 'winget')
}

function uinst
{
    $allIds = Get-WinGetPackage | Select-Object -ExpandProperty Id
    $ids = _FzfWingetPicker -Ids $allIds -Header "[Ctrl-P]: Preview Info | [Tab]: Multi-select | [Ctrl-A]: Toggle All"
    if (-not $ids.Count) { return }

    Write-Host ""
    Write-Host "Selected to remove:" -ForegroundColor Red
    $ids | ForEach-Object { Write-Host "- $_"}

    _WingetAction -Verb "uninstall" -Ids $ids
}

function upp
{
    param([switch]$all)

    $updates = @(Get-WinGetPackage -Source winget | Where-Object { $_.IsUpdateAvailable })
    if (-not $updates.Count) { Write-Host "Up to date" -ForegroundColor Green; return }

    $allIds = $updates | Select-Object -ExpandProperty Id

    if ($all)
    {
        $ids = $allIds
    }
    else
    {
        $ids = _FzfWingetPicker -Ids $allIds -Header "[Ctrl-P]: Preview | [Tab]: Multi-select | [Ctrl-A]: Toggle All" -Height "70%" -Prompt "Upgrade › "
        if (-not $ids.Count) { return }
    }

    Write-Host ""
    Write-Host "Selected to update:" -ForegroundColor Yellow
    $ids | ForEach-Object { Write-Host "-> $_" }

    _WingetAction -Verb "upgrade" -Ids $ids
}

# ==============================================================================
# 8. UPDATES & MAINTENANCE
# ==============================================================================
function _GetSha256([string]$Text)
{
    $sha = [System.Security.Cryptography.SHA256]::Create()
    [System.Convert]::ToHexString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text)))
}

# Shared by 'cup' (check) and 'upf' (apply) so both hash the same content.
function _GetBetterfoxUserJs
{
    $url           = "https://raw.githubusercontent.com/yokoffing/Betterfox/main/user.js"
    $removalsPath  = "$ConfigPath\data\firefox\user-removals.txt"
    $overridesPath = "$ConfigPath\data\firefox\overrides.txt"

    $lines = (Invoke-WebRequest -Uri $url -UseBasicParsing -ErrorAction Stop).Content -split "`n"

    $removals = Get-Content $removalsPath | Where-Object { $_.Trim() -ne "" }
    foreach ($key in $removals)
    {
        $escaped = [regex]::Escape($key.Trim())
        $lines   = $lines | Where-Object { $_ -notmatch "user_pref\(`"$escaped`"" }
    }

    $content = $lines -join "`n"

    $overrides = (Get-Content $overridesPath -Raw).Trim()
    if ($overrides)
    { $content = $content.TrimEnd() + "`n`n// overrides.txt`n" + $overrides + "`n" }

    return ($content -replace "`r`n", "`n").TrimEnd()
}

# Hash of last-deployed content - local edits retrigger 'upf' like a new release.
function Test-BetterfoxUpToDate
{
    $hashFile = "$env:LOCALAPPDATA\windows-config-files\betterfox_hash.txt"
    $newHash  = _GetSha256 (_GetBetterfoxUserJs)
    $upToDate = (Test-Path $hashFile) -and ((Get-Content $hashFile -Raw).Trim() -eq $newHash)

    return [pscustomobject]@{
        HashFile = $hashFile
        NewHash  = $newHash
        UpToDate = $upToDate
    }
}

function _ShowGitUpdateStatus
{
    param(
        [string]$RepoPath,
        [string]$Label,
        [string]$Hint,
        [switch]$AsObject
    )

    if (-not (Test-Path (Join-Path $RepoPath ".git")))
    {
        if ($AsObject) { return [pscustomobject]@{ Status = "missing"; Label = $Label; Message = "$Label not found" } }
        Write-Host "$Label not found" -ForegroundColor Yellow; return
    }

    git -C $RepoPath fetch --quiet 2>$null
    if ($LASTEXITCODE -ne 0)
    {
        if ($AsObject) { return [pscustomobject]@{ Status = "error"; Label = $Label; Message = "$Label fetch failed" } }
        Write-Host "$Label fetch failed" -ForegroundColor Red; return
    }

    $behind = git -C $RepoPath rev-list --count 'HEAD..@{u}' 2>$null
    if ($LASTEXITCODE -ne 0)
    {
        if ($AsObject) { return [pscustomobject]@{ Status = "error"; Label = $Label; Message = "$Label has no upstream branch" } }
        Write-Host "$Label has no upstream branch" -ForegroundColor Yellow; return
    }

    if ([int]$behind -gt 0)
    {
        $msg = "$Label $behind commit(s) behind"
        if ($Hint) { $msg += ", run '$Hint'" }
        if ($AsObject) { return [pscustomobject]@{ Status = "update"; Label = $Label; Message = $msg } }
        Write-Host $msg -ForegroundColor Yellow
    }
    else
    {
        if ($AsObject) { return [pscustomobject]@{ Status = "ok"; Label = $Label; Message = "$Label up to date" } }
        Write-Host "$Label up to date" -ForegroundColor Green
    }
}

function cup
{
    Write-Host "`n>Winget" -ForegroundColor Blue
    $ids = @(_WingetUpgradeIds)
    if ($ids.Count -gt 0) {
        $ids | ForEach-Object { Write-Host "$_" -ForegroundColor Yellow }
        Write-Host ""
        Write-Host "$($ids.Count) update(s) available" -ForegroundColor Yellow
    } else {
        Write-Host "Up to date" -ForegroundColor Green
    }

    Write-Host "`n>Microsoft Store" -ForegroundColor Blue
    'n' | store updates

    Write-Host "`n>Betterfox" -ForegroundColor Blue
    try
    {
        $profilesPath = "$env:APPDATA\Mozilla\Firefox\Profiles"
        $bf        = Test-BetterfoxUpToDate
        $behind    = @()
        $profiles  = Get-ChildItem $profilesPath -Directory -ErrorAction SilentlyContinue
        foreach ($prof in $profiles)
        {
            $jsPath = Join-Path $prof.FullName "user.js"
            $current = (Test-Path $jsPath) -and (_GetSha256 ((Get-Content $jsPath -Raw) -replace "`r`n", "`n").TrimEnd()) -eq $bf.NewHash
            if (-not $current)
            { $behind += $prof.Name }
        }
        if ($behind.Count -eq 0)
        { Write-Host "Up to date" -ForegroundColor Green }
        else
        {
            Write-Host "New or outdated profile(s), run 'upf'" -ForegroundColor Yellow
            foreach ($p in $behind) { Write-Host "  $p" -ForegroundColor Yellow }
        }
    }
    catch { Write-Host "Check failed: $($_.Exception.Message)" -ForegroundColor Red }

    Write-Host "`n>Martian Mono Nerd Font" -ForegroundColor Blue
    try
    {
        $r = Install-MartianMonoFont -CheckOnly
        if     ($r.UpToDate) { Write-Host "Up to date" -ForegroundColor Green }
        elseif ($r.Success)  { Write-Host "Update available, run 'upfont'" -ForegroundColor Yellow }
        else                 { Write-Host "Check failed: $($r.Error)" -ForegroundColor Red }
    }
    catch { Write-Host "Check failed: $($_.Exception.Message)" -ForegroundColor Red }

    Write-Host "`n>Wireproxy" -ForegroundColor Blue
    try
    {
        $r = Install-Wireproxy -CheckOnly
        if     ($r.UpToDate) { Write-Host "Up to date" -ForegroundColor Green }
        elseif ($r.Success)  { Write-Host "Update available, run 'wpm update'" -ForegroundColor Yellow }
        else                 { Write-Host "Check failed: $($r.Error)" -ForegroundColor Red }
    }
    catch { Write-Host "Check failed: $($_.Exception.Message)" -ForegroundColor Red }

    Write-Host "`n>GitGet" -ForegroundColor Blue
    gitget check

    Write-Host "`n>Cloned Repos" -ForegroundColor Blue
    $repoResults = foreach ($entry in (Get-RepoList))
    {
        $repo = Get-RepoEntry $entry
        _ShowGitUpdateStatus -RepoPath $repo.Path -Label $repo.Name -Hint "uprep" -AsObject
    }
    $repoUpdates = @($repoResults | Where-Object { $_.Status -eq "update" })
    $repoErrors  = @($repoResults | Where-Object { $_.Status -ne "update" -and $_.Status -ne "ok" })
    if ($repoUpdates.Count -gt 0 -or $repoErrors.Count -gt 0) {
        $repoResults | Where-Object { $_.Status -ne "ok" } | ForEach-Object {
            $color = if ($_.Status -eq "update") { "Yellow" } else { if ($_.Status -eq "missing") { "Yellow" } else { "Red" } }
            Write-Host $_.Message -ForegroundColor $color
        }
    } else {
        Write-Host "Up to date" -ForegroundColor Green
    }

    Write-Host "`n>Windows Config" -ForegroundColor Blue
    $r = _ShowGitUpdateStatus -RepoPath $ConfigPath -Label "windows-config" -Hint "upc" -AsObject
    if ($r.Status -eq "ok") { Write-Host "Up to date" -ForegroundColor Green }
    else                    { Write-Host $r.Message -ForegroundColor $(if ($r.Status -eq "missing") { "Yellow" } else { "Red" }) }
}

function upall
{
    Write-Host "`n>Winget Updates" -ForegroundColor Blue
    winget source update
    Write-Host ""
    upp -all
    upf
    ups
    upfont
    Write-Host "`n>Wireproxy Update" -ForegroundColor Blue
    wpm update
    Write-Host "`n>GitGet Update" -ForegroundColor Blue
    gitget update -All
    uprep
    upc
}

function ups
{
    Write-Host "`n>Store App Updates" -ForegroundColor Blue
    store updates --apply
}

function upf
{
    Write-Host "`n>Betterfox - Firefox user.js Update" -ForegroundColor Blue
    try
    {
        $profilesPath = "$env:APPDATA\Mozilla\Firefox\Profiles"
        $profiles = Get-ChildItem $profilesPath -Directory -ErrorAction SilentlyContinue
        if ($profiles.Count -eq 0)
        { Write-Host "No Firefox profiles found" -ForegroundColor Red; return }

        $bf = Test-BetterfoxUpToDate
        $content  = _GetBetterfoxUserJs
        $hashFile = $bf.HashFile
        $newHash  = $bf.NewHash

        $updated = 0; $current = 0; $failed = 0
        foreach ($prof in $profiles)
        {
            $jsPath = Join-Path $prof.FullName "user.js"
            if ((Test-Path $jsPath) -and ((_GetSha256 ((Get-Content $jsPath -Raw) -replace "`r`n", "`n").TrimEnd()) -eq $newHash))
            { $current++; continue }

            try
            {
                [System.IO.File]::WriteAllText($jsPath, $content, (New-Object System.Text.UTF8Encoding($false)))
                Write-Host "Updated profile: $($prof.Name)" -ForegroundColor Green
                $updated++
            }
            catch
            {
                Write-Host "Failed profile: $($prof.Name)" -ForegroundColor Red
                $failed++
            }
        }

        $total = $updated + $current + $failed
        if ($total -eq 0)
        { Write-Host "No Firefox profiles found" -ForegroundColor Red; return }

        if ($current -gt 0)
        { Write-Host "$current profile(s) already up to date" -ForegroundColor Green }

        if ($updated -gt 0)
        {
            $null = New-Item -ItemType Directory -Path (Split-Path $hashFile) -Force
            Set-Content -Path $hashFile -Value $newHash -ErrorAction SilentlyContinue
        }

        if ($updated -eq 0 -and $failed -gt 0)
        { Write-Host "Failed to update profile(s)" -ForegroundColor Red }
    }
    catch
    { Write-Host "Failed: $($_.Exception.Message)" -ForegroundColor Red }
}

function upfont
{
    Write-Host "`n>Martian Mono Nerd Font Update" -ForegroundColor Blue
    gsudo {
        param($configPath)
        . "$configPath\helpers\font-install.ps1"
        $r = Install-MartianMonoFont -Update
        if (-not $r.Success) {
            Write-Host "Martian Mono Nerd Font update failed: $($r.Error)" -ForegroundColor Red
        }
        elseif ($r.UpToDate) {
            Write-Host "Martian Mono Nerd Font already up to date." -ForegroundColor Green
        }
        else {
            foreach ($name in $r.Installed)     { Write-Host "Installed: $name" -ForegroundColor Gray }
            foreach ($name in $r.Updated)       { Write-Host "Updated: $name" -ForegroundColor Gray }
            foreach ($name in $r.SkippedInUse)  { Write-Host "In use, skipped: $name" -ForegroundColor Yellow }
            if ($r.RebootCleanup.Count -gt 0)   { Write-Host "Old copies pending deletion at next reboot." -ForegroundColor Yellow }
            Write-Host "Martian Mono Nerd Font update complete." -ForegroundColor Green
            Write-Host "Restart terminal apps to pick up new font glyphs" -ForegroundColor Yellow
        }
    } -args $ConfigPath
}

function upc
{
    Write-Host "`n>Windows Config Update" -ForegroundColor Blue
    git -C $ConfigPath pull --rebase --autostash 2>&1 | ForEach-Object { Write-Host "$_" }
    if ($LASTEXITCODE -ne 0)
    { Write-Host "Windows Config update failed" -ForegroundColor Red; return }
    Write-Host "`n'reload' to apply changes" -ForegroundColor Yellow
}

function uprep
{
    Write-Host "`n>Repo Updates" -ForegroundColor Blue
    $anyUpdated = $false
    $failed = $false
    foreach ($entry in (Get-RepoList)) {
        $repo = Get-RepoEntry $entry
        $repoPath    = $repo.Path
        $displayPath = $repo.DisplayPath

        if (-not (Test-Path $repoPath)) {
            Write-Host "$($repo.Name) not found, skipping." -ForegroundColor Yellow
            continue
        }

        $output = git -C $repoPath pull --rebase --autostash 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "$($repo.Name) pull failed:" -ForegroundColor Red
            $output | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
            $failed = $true
            continue
        }
        if ($output -match "Already up to date") { continue }
        Write-Host "$($repo.Name) ($displayPath)" -ForegroundColor Yellow
        $output | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
        $anyUpdated = $true
    }
    if (-not $anyUpdated -and -not $failed) { Write-Host "Up to date" -ForegroundColor Green }
}

function topgrade {gsudo topgrade $args }

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
    if (-not $search) { Write-Host "Path not found: $Path" -ForegroundColor Red; return }

    # ForEach-Object avoids the raw OS pipe that throws "pipe is being closed"
    # when fzf exits before fd finishes (PowerShell/PowerShell#20827).
    $selection = fd . $search --hidden --color never --exclude "Windows" |
        ForEach-Object { $_ } |
        fzf --no-multi --layout=reverse --header "Searching: $search"

    if (-not $selection) { return }

    "`"$($selection.Trim())`"" | Set-Clipboard
    Write-Host "Copied path to clipboard" -ForegroundColor Green
}

Set-PSReadLineKeyHandler -Key "Ctrl+h" -ScriptBlock {
    $historyFile = (Get-PSReadLineOption).HistorySavePath
    if (-not (Test-Path $historyFile)) { return }

    $history = [System.Collections.Generic.List[string]]((Get-Content $historyFile))
    $history.Reverse()
    
    $uniqueHistory = [System.Collections.Generic.HashSet[string]]::new()
    $deduplicated = foreach ($cmd in $history) {
        if ($uniqueHistory.Add($cmd)) { $cmd }
    }

    $selected = $deduplicated | fzf --no-multi --reverse --height 40% 

    if ($null -eq $selected) { return }

    [Microsoft.PowerShell.PSConsoleReadLine]::DeleteLine()
    [Microsoft.PowerShell.PSConsoleReadLine]::Insert($selected.Trim()) 
}

# ==============================================================================
# 10. NETWORK & UTILITIES
# ==============================================================================
function wpm
{
    & "$ConfigPath\tools\wpm.ps1" @args
}

function wgm
{
    & "$ConfigPath\tools\wgm.ps1" @args
}

function timer
{
    & "$ConfigPath\tools\timer.ps1" @args
}

function gitget
{
    & "$ConfigPath\tools\gitget.ps1" @args
}

function keepawake
{
    Write-Host "Keeping screen awake. Press Ctrl+C to cancel..." -ForegroundColor Gray
    try
    {
        _EnableKeepAwake
        while ($true)
        {
            Start-Sleep -Seconds 60
        }
    } 
    finally
    {
        _DisableKeepAwake
        Write-Host "Keepawake cancelled, normal sleep behavior restored." -ForegroundColor Yellow
    }
}

# ==============================================================================
# 11. THIRD PARTY TOOLS
# ==============================================================================
function ctt
{
    Invoke-RestMethod https://christitus.com/win | Invoke-Expression 
}

function massgrave
{
    Invoke-RestMethod https://get.activated.win | Invoke-Expression
}