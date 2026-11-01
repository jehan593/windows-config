# ==============================================================================
# REGISTRY TWEAKS
# ==============================================================================
$ConfigPath = $env:WINDOWS_CONFIG_PATH
. "$ConfigPath\helpers\dep-checker.ps1"

$missingDeps = @(_TestDependencies -Commands "gsudo", "fzf")
if ($missingDeps.Count -gt 0)
{
    Write-Host "Missing: $($missingDeps -join ', ')" -ForegroundColor Red
    Write-Host "Stopped." -ForegroundColor Red
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

function _Tweak_WindowsUpdateReboots
{
    Write-Host "`n02. Disable Windows Update Auto Reboots" -ForegroundColor Blue

    gsudo {
        try{
        if (-not (Test-Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU")) {
            New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Force | Out-Null
        }
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoRebootWithLoggedOnUsers" -Value 1 -Type DWord -Force -ErrorAction Stop
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "AUPowerManagement"              -Value 0 -Type DWord -Force -ErrorAction Stop
        Write-Host "Automatic reboots while users are logged in have been disabled." -ForegroundColor Green
        } catch {
            Write-Host "Failed to apply registry tweaks: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

function _Tweak_EditWithNeovim
{
    Write-Host "`n03. Add 'Edit with Neovim' to File Context Menu" -ForegroundColor Blue

    # Neovim is found on the PATH, wherever it was installed.
    $nvimPath = (Get-Command nvim -ErrorAction SilentlyContinue).Source
    if (-not $nvimPath) {
        Write-Host "Neovim not found on the PATH - install it first." -ForegroundColor Red
        return
    }
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
            Write-Host "Added" -ForegroundColor Green
        } catch {
            Write-Host "Failed to add: $($_.Exception.Message)" -ForegroundColor Red
        }
    } -args $nvimPath, "wt.exe nvim `"%1`""
}

function _Tweak_OpenWithOpenCode
{
    Write-Host "`n04. Add 'Open with Opencode' to Folder Context Menu" -ForegroundColor Blue

    $parents = @(
        "SOFTWARE\Classes\Directory\shell"
        "SOFTWARE\Classes\Directory\Background\shell"
    )
    $cmdFolder     = "wt.exe -d `"%1`" opencode"
    $cmdBackground = "wt.exe -d `"%V`" opencode"
    $opencodeExe   = (Get-Command opencode -ErrorAction SilentlyContinue).Source

    foreach ($parent in $parents)
    {
        $isBackground = $parent -match "Background"
        $cmd  = if ($isBackground) { $cmdBackground } else { $cmdFolder }
        # gsudo flatten/joins array args with spaces, so only pass scalars here.
        gsudo {
            param($parent, $cmd, $icon)
            try {
                $hklm  = [Microsoft.Win32.Registry]::LocalMachine
                $parentKey = $hklm.OpenSubKey($parent, $true)
                if ($parentKey)
                {
                    foreach ($sub in @($parentKey.GetSubKeyNames()))
                    {
                        if ($sub -like "OpenWithOpenCode*") { $parentKey.DeleteSubKeyTree($sub) }
                    }
                    $parentKey.Close()
                }
                $shell = $hklm.CreateSubKey("$parent\OpenWithOpenCode")
                $shell.SetValue("", "Open with Opencode")
                if ($icon) { $shell.SetValue("Icon", $icon) }
                $cmdKey = $shell.CreateSubKey("command")
                $cmdKey.SetValue("", $cmd)
                $cmdKey.Close(); $shell.Close()
                $where = if ($parent -match "Background") { "folder background menu" } else { "folder menu" }
                Write-Host "Added 'Open with Opencode' to the $where." -ForegroundColor Green
            } catch {
                Write-Host "Failed to add: $($_.Exception.Message)" -ForegroundColor Red
            }
        } -args $parent, $cmd, $opencodeExe
    }
}

# ==============================================================================
# MENU
# ==============================================================================
$tweaks = @(
    "01  Remove Git GUI & Bash Here from Context Menu"
    "02  Disable Windows Update Auto Reboots"
    "03  Add 'Edit with Neovim' to File Context Menu"
    "04  Add 'Open with Opencode' to Folder Context Menu"
)

$selected = $tweaks | fzf --exact --multi --reverse `
    --header "Registry Tweaks (Tab: multi-select, Enter: apply)"

if (-not $selected) { exit }

foreach ($item in $selected)
{
    switch -Regex ($item)
    {
        "^01" { _Tweak_RemoveGitContextMenu }
        "^02" { _Tweak_WindowsUpdateReboots }
        "^03" { _Tweak_EditWithNeovim }
        "^04" { _Tweak_OpenWithOpenCode }
    }
}