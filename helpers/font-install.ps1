# ==============================================================================
# MARTIAN MONO NERD FONT INSTALL
# ==============================================================================
# Silent by design - returns a result object:
#   Success       install succeeded
#   UpToDate      already at latest version
#   Error         exception message (when Success is $false)
#   Installed     newly copied to \Windows\Fonts
#   Updated       existing files overwritten
#   SkippedInUse  held open by a running app, left alone
#   RebootCleanup queued for deletion at next reboot
# Also exposes Get-FontRegistryName so setup/reset compute the same key name.
function Get-FontRegistryName
{
    param([Parameter(Mandatory)][string]$FontName)

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($FontName)
    $type     = if ($FontName -like "*.otf") { "OpenType" } else { "TrueType" }
    return "$baseName ($type)"
}

function Install-MartianMonoFont
{
    # -Update overwrites existing font files; without it they're untouched.
    # -CheckOnly compares release tags only, no download.
    param(
        [switch]$Update,
        [switch]$CheckOnly
    )

    $result = [pscustomobject]@{
        Success       = $true
        UpToDate      = $false
        Error         = $null
        Installed     = @()
        Updated       = @()
        Registered    = @()
        SkippedInUse  = @()
        RebootCleanup = @()
    }

    if (-not ([System.Management.Automation.PSTypeName]'Win32.FontUtil').Type) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace Win32 {
    public static class FontUtil {
        // MOVEFILE_DELAY_UNTIL_REBOOT with a null target deletes the file at
        // next boot - the only way to remove a file an app still holds open.
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern bool MoveFileEx(string lpExistingFileName, string lpNewFileName, int dwFlags);
    }
}
"@
    }

    try
    {
        $versionFile    = "$env:LOCALAPPDATA\windows-config-files\martianmono.version"
        $fontsRegPath   = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts"
        $windowsFontDir = "$env:WINDIR\Fonts"

        # Resolve the latest tag to skip the download when already up to date.
        $latestTag = $null
        try {
            $latestTag = (Invoke-RestMethod -Uri "https://api.github.com/repos/ryanoasis/nerd-fonts/releases/latest" -ErrorAction Stop).tag_name
        }
        catch { }

        # Marker + font files present => nothing to do. Second check covers manual deletion.
        if ($latestTag -and
            (Test-Path $versionFile) -and
            ((Get-Content $versionFile -Raw).Trim() -eq $latestTag) -and
            (Test-Path (Join-Path $windowsFontDir "MartianMono*")))
        {
            $result.UpToDate = $true
            return $result
        }

        # No resolved tag -> abort rather than download unconditionally.
        if (-not $latestTag)
        {
            $result.Success = $false
            $result.Error   = "Could not resolve latest nerd-fonts release"
            return $result
        }

        $fontZipUrl = "https://github.com/ryanoasis/nerd-fonts/releases/download/$latestTag/MartianMono.zip"
        $fontTempDir = Join-Path $env:TEMP "MartianMonoNerdFont"
        $fontZipPath = Join-Path $env:TEMP "MartianMono.zip"

        Invoke-WebRequest -Uri $fontZipUrl -OutFile $fontZipPath -UseBasicParsing -ErrorAction Stop
        Expand-Archive -Path $fontZipPath -DestinationPath $fontTempDir -Force -ErrorAction Stop

        $fontFiles      = Get-ChildItem -Path $fontTempDir -Include "*.ttf", "*.otf" -Recurse

        foreach ($font in $fontFiles) {
            $destPath  = Join-Path $windowsFontDir $font.Name
            $stalePath = "$destPath.old"

            # Leftover from a previous in-use swap whose reboot-delete hasn't happened.
            if ($Update) { Remove-Item $stalePath -Force -ErrorAction SilentlyContinue }

            if ($Update -and (Test-Path $destPath)) {
                try {
                    Copy-Item -Path $font.FullName -Destination $destPath -Force -ErrorAction Stop
                    $result.Updated += $font.Name
                }
                catch [System.IO.IOException] {
                    # File in use - can't overwrite, but CAN rename. Move it aside, put the
                    # new copy in place, and queue the stale one for reboot-delete.
                    try {
                        Move-Item -Path $destPath -Destination $stalePath -Force -ErrorAction Stop
                        Copy-Item -Path $font.FullName -Destination $destPath -Force -ErrorAction Stop
                        $result.Updated += $font.Name

                        try { Remove-Item $stalePath -Force -ErrorAction Stop }
                        catch {
                            $null = [Win32.FontUtil]::MoveFileEx($stalePath, $null, 4)
                            $result.RebootCleanup += "$($font.Name).old"
                        }
                    }
                    catch {
                        if ((Test-Path $stalePath) -and -not (Test-Path $destPath)) {
                            Move-Item -Path $stalePath -Destination $destPath -Force -ErrorAction SilentlyContinue
                        }
                        $result.SkippedInUse += $font.Name
                    }
                }
            }
            elseif (-not (Test-Path $destPath)) {
                Copy-Item -Path $font.FullName -Destination $destPath -Force -ErrorAction Stop
                $result.Installed += $font.Name
            }

            $regName  = Get-FontRegistryName $font.Name

            if (-not (Get-ItemProperty -Path $fontsRegPath -Name $regName -ErrorAction SilentlyContinue)) {
                New-ItemProperty -Path $fontsRegPath -Name $regName -Value $font.Name -PropertyType String -Force | Out-Null
                $result.Registered += $font.Name
            }
        }

        Remove-Item $fontZipPath, $fontTempDir -Recurse -Force

        if ($latestTag) {
            $versionDir = Split-Path $versionFile
            if (-not (Test-Path $versionDir)) { New-Item -ItemType Directory -Path $versionDir | Out-Null }
            Set-Content -Path $versionFile -Value $latestTag -NoNewline
        }

        return $result
    }
    catch {
        $result.Success = $false
        $result.Error   = $_.Exception.Message
        return $result
    }
}
