# ==============================================================================
# REGISTRY TWEAKS
# ==============================================================================
if (-not (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process "wt" -ArgumentList "pwsh", "-NoExit", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"" -Verb RunAs
    exit
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

function _Ok   { param([string]$Msg) Write-Host ("│  [OK]    {0}" -f $Msg) -ForegroundColor Green }
function _Info { param([string]$Msg) Write-Host ("│  [INFO]  {0}" -f $Msg) -ForegroundColor Blue }
function _Err  { param([string]$Msg) Write-Host ("│  [ERR]   {0}" -f $Msg) -ForegroundColor Red }

function _IsAdmin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ==============================================================================
# TWEAKS
# ==============================================================================

function _Tweak_TextFileContextMenu {
    _PrintHeader "󰒓" "01. Add Text Document to New Context Menu (Notepad++)"
    if (-not (_IsAdmin)) { _Err "Requires admin. Run as administrator."; _PrintFooter; return }

    # Set .txt association
    if (!(Test-Path "HKCR:")) { New-PSDrive -Name HKCR -PSProvider Registry -Root HKEY_CLASSES_ROOT | Out-Null }

    $txtPath = "HKCR:\.txt"
    if (!(Test-Path $txtPath)) { New-Item -Path $txtPath -Force | Out-Null }
    Set-ItemProperty -Path $txtPath -Name "(Default)" -Value "txtfile" -Type String -Force
    Set-ItemProperty -Path $txtPath -Name "Content Type" -Value "text/plain" -Type String -Force
    Set-ItemProperty -Path $txtPath -Name "PerceivedType" -Value "text" -Type String -Force
    _Ok ".txt association set."

    # Add ShellNew for New > Text Document
    $shellNewPath = "HKCR:\.txt\ShellNew"
    if (!(Test-Path $shellNewPath)) { New-Item -Path $shellNewPath -Force | Out-Null }
    Set-ItemProperty -Path $shellNewPath -Name "NullFile" -Value "" -Type String -Force
    _Ok "ShellNew entry added."

    # Set txtfile class
    $txtfilePath = "HKCR:\txtfile"
    if (!(Test-Path $txtfilePath)) { New-Item -Path $txtfilePath -Force | Out-Null }
    Set-ItemProperty -Path $txtfilePath -Name "(Default)" -Value "Text Document" -Type String -Force
    _Ok "txtfile class set."

    # Set open command to Notepad++
    $openCmdPath = "HKCR:\txtfile\shell\open\command"
    if (!(Test-Path $openCmdPath)) { New-Item -Path $openCmdPath -Force | Out-Null }
    Set-ItemProperty -Path $openCmdPath -Name "(Default)" -Value "`"C:\Program Files\Notepad++\notepad++.exe`" `"%1`"" -Type String -Force
    _Ok "Open command set to Notepad++."

    _Info "Restart Explorer or sign out to apply context menu changes."
    _PrintFooter
}
function _Tweak_RemoveGitContextMenu {
    _PrintHeader "󰒓" "02. Remove Git GUI & Bash Here from Context Menu"
    if (-not (_IsAdmin)) { _Err "Requires admin. Run as administrator."; _PrintFooter; return }

    if (!(Test-Path "HKCR:")) { New-PSDrive -Name HKCR -PSProvider Registry -Root HKEY_CLASSES_ROOT | Out-Null }

    $paths = @(
        "HKCR:\Directory\shell\git_gui"
        "HKCR:\Directory\shell\git_shell"
        "HKCR:\Directory\Background\shell\git_gui"
        "HKCR:\Directory\Background\shell\git_shell"
    )

    foreach ($path in $paths) {
        if (Test-Path $path) {
            Remove-Item -Path $path -Recurse -Force
            _Ok "Removed: $path"
        } else {
            _Info "Not found, skipping: $path"
        }
    }

    _PrintFooter
}

function _Tweak_WallpaperSlideshowInterval {
    _PrintHeader "󰒓" "04. Custom Wallpaper Slideshow Interval"

    $val = Read-Host "│  Enter interval in minutes"
    if (-not $val -or $val -notmatch '^\d+$') {
        _Err "Invalid input. Please enter a number."
        _PrintFooter; return
    }

    $ms = [int]$val * 60000
    $path = "HKCU:\Control Panel\Personalization\Desktop Slideshow"
    if (!(Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
    Set-ItemProperty -Path $path -Name "Interval" -Value $ms -Type DWord -Force
    _Ok "Slideshow interval set to $val minute(s)."
    _PrintFooter
}
# ==============================================================================
# MENU
# ==============================================================================
$tweaks = @(
    "01  Add Text Document to New Context Menu (Notepad++)"
    "02  Remove Git GUI & Bash Here from Context Menu"
    "03  Custom Wallpaper Slideshow Interval"
)

$selected = $tweaks | fzf --exact --multi --reverse `
    --header "󰒓 Registry Tweaks (Tab: multi-select, Enter: apply)"

if (-not $selected) { return }

foreach ($item in $selected) {
    switch -Regex ($item) {
        "^01" { _Tweak_TextFileContextMenu }
        "^02" { _Tweak_RemoveGitContextMenu }
        "^03" { _Tweak_WallpaperSlideshowInterval }
    }
}