# ==============================================================================
# MARTIAN MONO NERD FONT INSTALL
# ==============================================================================
# Silent by design - returns a result object for the caller to report on:
#   Success       $true unless the install failed
#   UpToDate      $true when the version marker already matches (nothing done)
#   Error         exception message, only meaningful when Success is $false
#   Installed     font files newly copied into \Windows\Fonts
#   Updated       existing font files overwritten this run
#   SkippedInUse  files left untouched because a running app holds them open
#   RebootCleanup stale copies queued for deletion at next reboot
function Install-MartianMonoFont
{
    # -Update overwrites already-installed font files with the freshly downloaded
    # ones; without it (plain setup run) existing files are left untouched.
    # -CheckOnly resolves the release tag and compares it against the local
    # version marker without downloading anything; Success + UpToDate means
    # installed, Success without UpToDate means an update is pending.
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

        # Resolve the current release tag so we can skip the download entirely
        # when the installed version already matches; if the API call fails we
        # lose the shortcut but not the ability to install/update.
        $latestTag = $null
        try {
            $latestTag = (Invoke-RestMethod -Uri "https://api.github.com/repos/ryanoasis/nerd-fonts/releases/latest" -ErrorAction Stop).tag_name
        }
        catch { }

        # Marker matches AND font files still present => nothing to do. The
        # second check covers manual deletion while the marker survived.
        if ($latestTag -and
            (Test-Path $versionFile) -and
            ((Get-Content $versionFile -Raw).Trim() -eq $latestTag) -and
            (Test-Path (Join-Path $windowsFontDir "MartianMono*")))
        {
            $result.UpToDate = $true
            return $result
        }

        # Without a resolved tag there is nothing to compare against, so a check
        # is inconclusive rather than "update pending" (the install path can
        # still proceed via the /releases/latest/ alias).
        if ($CheckOnly)
        {
            if (-not $latestTag)
            {
                $result.Success = $false
                $result.Error   = "Could not resolve latest nerd-fonts release"
            }
            return $result
        }

        $fontZipUrl  = if ($latestTag) { "https://github.com/ryanoasis/nerd-fonts/releases/download/$latestTag/MartianMono.zip" }
                       else            { "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/MartianMono.zip" }
        $fontTempDir = Join-Path $env:TEMP "MartianMonoNerdFont"
        $fontZipPath = Join-Path $env:TEMP "MartianMono.zip"

        Invoke-WebRequest -Uri $fontZipUrl -OutFile $fontZipPath -UseBasicParsing -ErrorAction Stop
        Expand-Archive -Path $fontZipPath -DestinationPath $fontTempDir -Force -ErrorAction Stop

        $fontFiles      = Get-ChildItem -Path $fontTempDir -Include "*.ttf", "*.otf" -Recurse

        foreach ($font in $fontFiles) {
            $destPath  = Join-Path $windowsFontDir $font.Name
            $stalePath = "$destPath.old"

            # Leftover from a previous in-use swap whose reboot-delete hasn't
            # happened yet (or that survived because the machine wasn't rebooted).
            if ($Update) { Remove-Item $stalePath -Force -ErrorAction SilentlyContinue }

            if ($Update -and (Test-Path $destPath)) {
                try {
                    Copy-Item -Path $font.FullName -Destination $destPath -Force -ErrorAction Stop
                    $result.Updated += $font.Name
                }
                catch [System.IO.IOException] {
                    # Loaded by a running app (possibly this very terminal), so a
                    # direct overwrite can never succeed. Renaming an in-use file
                    # IS permitted though - move it aside, drop the new copy into
                    # the original name, and queue the stale one for reboot-deletion.
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
                Copy-Item -Path $font.FullName -Destination $destPath -Force
                $result.Installed += $font.Name
            }

            $fontName = [System.IO.Path]::GetFileNameWithoutExtension($font.Name)
            $fontType = if ($font.Extension -eq ".otf") { "OpenType" } else { "TrueType" }
            $regName  = "$fontName ($fontType)"

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
