# ==============================================================================
# REGISTRY TWEAKS
# ==============================================================================
$ConfigPath = $env:WINDOWS_CONFIG_PATH
. "$ConfigPath\scripts\common-helpers\dependencies.ps1"              

if (-not (_TestDependencies -Commands "gsudo", "fzf"))
{
    Write-Host "Script stopped due to missing dependencies." -ForegroundColor Red
    return
}

# ==============================================================================
# TWEAKS
# ==============================================================================
function _Tweak_RemoveGitContextMenu
{
    Write-Host "`n01. Remove Git GUI & Bash Here from Context Menu" -ForegroundColor Blue

    $paths = @(
        "HKLM:\SOFTWARE\Classes\Directory\shell\git_gui"
        "HKLM:\SOFTWARE\Classes\Directory\shell\git_shell"
        "HKLM:\SOFTWARE\Classes\Directory\Background\shell\git_gui"
        "HKLM:\SOFTWARE\Classes\Directory\Background\shell\git_shell"
    )

    gsudo {
        param($targetPaths)
        foreach ($path in $targetPaths)
        {
            try {
                $lastPart = $path -split '\\' | Select-Object -Last 1
                $cleanName = if ($lastPart -eq "git_gui") { "Git GUI" } else { "Git Bash" }
                $context = if ($path -match "Background") { "background menu" } else { "folder menu" }
                Remove-Item -Path $path -Recurse -Force -ErrorAction Stop
                Write-Host "Removed $cleanName from the $context." -ForegroundColor Green
            } catch {
                Write-Host "Failed to remove $cleanName from the ${context}: $_" -ForegroundColor Red
            }
        }
    } -args (,$paths)
}

function _Tweak_WindowsUpdateRecommended
{
    Write-Host "`n02. Set Windows Update to Recommended Settings" -ForegroundColor Blue

    gsudo {
        try{
        New-Item -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Force | Out-Null
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "BranchReadinessLevel"            -Value 20  -Type DWord -Force
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "DeferFeatureUpdatesPeriodInDays" -Value 365 -Type DWord -Force
        Write-Host "Feature updates successfully delayed by 365 days." -ForegroundColor Green
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "DeferQualityUpdatesPeriodInDays" -Value 4   -Type DWord -Force
        Write-Host "Quality updates successfully delayed by 4 days." -ForegroundColor Green

        New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Force | Out-Null
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoRebootWithLoggedOnUsers" -Value 1 -Type DWord -Force
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "AUPowerManagement"              -Value 0 -Type DWord -Force
        Write-Host "Automatic reboots while users are logged in have been disabled." -ForegroundColor Green
        } catch {
            Write-Host "Failed to apply registry tweaks: $($_.Exception.Message)" -ForegroundColor Red
        }
    }    
}

function _Tweak_EditWithNeovim
{
    Write-Host "`n03. Add 'Edit with Neovim' to File Context Menu" -ForegroundColor Blue

    $nvimPath = "C:\Program Files\Neovim\bin\nvim.exe"
    gsudo {
        param($path, $cmdArgs)
        try {
            $hklm  = [Microsoft.Win32.Registry]::LocalMachine
            $shell = $hklm.CreateSubKey("SOFTWARE\Classes\*\shell\EditWithNeovim")
            $shell.SetValue("", "Edit with Neovim")
            $shell.SetValue("Icon", "$path,0")
            $cmd = $shell.CreateSubKey("command")
            $cmd.SetValue("", $cmdArgs)
            $cmd.Close(); $shell.Close()
            Write-Host "Successfully added" -ForegroundColor Green
        } catch {
            Write-Host "Failed to add : $($_.Exception.Message)" -ForegroundColor Red
        }
    } -args $nvimPath, "wt.exe nvim `"%1`""
}

# ==============================================================================
# MENU
# ==============================================================================
$tweaks = @(
    "01  Remove Git GUI & Bash Here from Context Menu"
    "02  Set Windows Update to Recommended Settings"
    "03  Add 'Edit with Neovim' to File Context Menu"
)

$selected = $tweaks | fzf --exact --multi --reverse `
    --header "Registry Tweaks (Tab: multi-select, Enter: apply)"

if (-not $selected) { exit }

foreach ($item in $selected)
{
    switch -Regex ($item)
    {
        "^01" { _Tweak_RemoveGitContextMenu }
        "^02" { _Tweak_WindowsUpdateRecommended }
        "^03" { _Tweak_EditWithNeovim }
    }
}