# ==============================================================================
# REGISTRY TWEAKS
# ==============================================================================

function _IsAdmin
{
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
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

if (-not (_IsAdmin))
{
    $cwd     = (Get-Location).Path
    $cwdSafe = $cwd -replace "'", "''"
    $encoded = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes(
            "Set-Location '$cwdSafe'; & '$PSCommandPath'"
        )
    )
    Start-Process "wt" -ArgumentList "pwsh", "-NoExit", "-ExecutionPolicy", "Bypass", "-EncodedCommand", $encoded -Verb RunAs
    exit
}

# ==============================================================================
# TWEAKS
# ==============================================================================

function _Tweak_TextFileContextMenu
{
    _PrintHeader "󰒓" "01. Add Text Document to New Context Menu (Notepad++)"

    # Use HKLM:\SOFTWARE\Classes instead of HKCR: — the PSDrive shim has
    # broken parameter support. HKLM\SOFTWARE\Classes is the actual backing
    # store and supports -Type natively like all built-in registry drives.
    $base = "HKLM:\SOFTWARE\Classes"

    if (!(Test-Path "$base\.txt"))
    { New-Item -Path "$base\.txt" -Force | Out-Null
    }
    Set-ItemProperty -Path "$base\.txt" -Name "(Default)"     -Value "txtfile"    -Type String -Force
    Set-ItemProperty -Path "$base\.txt" -Name "Content Type"  -Value "text/plain" -Type String -Force
    Set-ItemProperty -Path "$base\.txt" -Name "PerceivedType" -Value "text"       -Type String -Force
    _PrintRow "󰄬" "Association" ".txt set to txtfile" "Green"

    if (!(Test-Path "$base\.txt\ShellNew"))
    { New-Item -Path "$base\.txt\ShellNew" -Force | Out-Null
    }
    Set-ItemProperty -Path "$base\.txt\ShellNew" -Name "NullFile" -Value "" -Type String -Force
    _PrintRow "󰄬" "ShellNew" "Entry added" "Green"

    if (!(Test-Path "$base\txtfile"))
    { New-Item -Path "$base\txtfile" -Force | Out-Null
    }
    Set-ItemProperty -Path "$base\txtfile" -Name "(Default)" -Value "Text Document" -Type String -Force
    _PrintRow "󰄬" "Class" "txtfile set" "Green"

    if (!(Test-Path "$base\txtfile\shell\open\command"))
    { New-Item -Path "$base\txtfile\shell\open\command" -Force | Out-Null
    }
    Set-ItemProperty -Path "$base\txtfile\shell\open\command" -Name "(Default)" -Value "`"C:\Program Files\Notepad++\notepad++.exe`" `"%1`"" -Type String -Force
    _PrintRow "󰄬" "Open With" "Notepad++ set" "Green"

    _PrintRow "󰋼" "Note" "Restart Explorer to apply" "Blue"
    _PrintFooter
}

function _Tweak_RemoveGitContextMenu
{
    _PrintHeader "󰒓" "02. Remove Git GUI & Bash Here from Context Menu"

    $paths = @(
        "HKLM:\SOFTWARE\Classes\Directory\shell\git_gui"
        "HKLM:\SOFTWARE\Classes\Directory\shell\git_shell"
        "HKLM:\SOFTWARE\Classes\Directory\Background\shell\git_gui"
        "HKLM:\SOFTWARE\Classes\Directory\Background\shell\git_shell"
    )

    foreach ($path in $paths)
    {
        if (Test-Path $path)
        {
            Remove-Item -Path $path -Recurse -Force
            _PrintRow "󰄬" "Removed" ($path -split '\\' | Select-Object -Last 1) "Green"
        } else
        {
            _PrintRow "󰋼" "Skipped" ($path -split '\\' | Select-Object -Last 1) "Blue"
        }
    }

    _PrintFooter
}

function _Tweak_DisableGameBar
{
    _PrintHeader "󰒓" "03. Disable Microsoft Game Bar / Gaming Overlay"

    if (!(Test-Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"))
    {
        New-Item -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR" -Force | Out-Null
    }
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR" -Name "AppCaptureEnabled" -Value 0 -Type DWord -Force
    _PrintRow "󰄬" "GameDVR" "Capture disabled" "Green"

    if (!(Test-Path "HKCU:\System\GameConfigStore"))
    {
        New-Item -Path "HKCU:\System\GameConfigStore" -Force | Out-Null
    }
    Set-ItemProperty -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_Enabled" -Value 0 -Type DWord -Force
    _PrintRow "󰄬" "Overlay" "Game Bar disabled" "Green"

    _PrintFooter
}

function _Tweak_WindowsUpdateRecommended
{
    _PrintHeader "󰒓" "04. Set Windows Update to Recommended Settings"

    if (!(Test-Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"))
    {
        New-Item -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Force | Out-Null
    }
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "BranchReadinessLevel"            -Value 20  -Type DWord -Force
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "DeferFeatureUpdatesPeriodInDays" -Value 365 -Type DWord -Force
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "DeferQualityUpdatesPeriodInDays" -Value 4   -Type DWord -Force
    _PrintRow "󰄬" "Feature" "Deferred 365 days" "Green"
    _PrintRow "󰄬" "Quality" "Deferred 4 days" "Green"

    if (!(Test-Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"))
    {
        New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Force | Out-Null
    }
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoRebootWithLoggedOnUsers" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "AUPowerManagement"             -Value 0 -Type DWord -Force
    _PrintRow "󰄬" "Auto-Reboot" "Disabled" "Green"

    _PrintFooter
}

# ==============================================================================
# MENU
# ==============================================================================
$tweaks = @(
    "01  Add Text Document to New Context Menu (Notepad++)"
    "02  Remove Git GUI & Bash Here from Context Menu"
    "03  Disable Microsoft Game Bar / Gaming Overlay"
    "04  Set Windows Update to Recommended Settings"
)

$selected = $tweaks | fzf --exact --multi --reverse `
    --header "󰒓 Registry Tweaks (Tab: multi-select, Enter: apply)"

if (-not $selected)
{ return
}

foreach ($item in $selected)
{
    switch -Regex ($item)
    {
        "^01"
        { _Tweak_TextFileContextMenu
        }
        "^02"
        { _Tweak_RemoveGitContextMenu
        }
        "^03"
        { _Tweak_DisableGameBar
        }
        "^04"
        { _Tweak_WindowsUpdateRecommended
        }
    }
}