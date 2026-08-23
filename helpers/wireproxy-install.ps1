# ==============================================================================
# WIREPROXY BINARY INSTALL
# ==============================================================================
# Silent by design - returns a result object for the caller to report on:
#   Path     full path of wireproxy.exe (pre-existing or freshly installed)
#   UpToDate $true when the binary already matches the latest release tag,
#            i.e. nothing was downloaded or written this run
function Install-Wireproxy
{
    # -CheckOnly resolves the release tag and compares it against the local
    # marker without downloading anything, so callers can decide whether an
    # update is worth disrupting running services.
    param([switch]$CheckOnly)

    $wireproxyBinDir  = "$env:LOCALAPPDATA\windows-config-files\bin"
    $wireproxyExe     = Join-Path $wireproxyBinDir "wireproxy.exe"
    $versionFile      = Join-Path $wireproxyBinDir "wireproxy.version"

    New-Item -ItemType Directory -Path $wireproxyBinDir -Force | Out-Null

    # Resolve the current release tag so the download can be skipped entirely
    # when the installed binary already matches; on API failure we lose the
    # shortcut but not the ability to (re)install.
    $latestTag = $null
    try {
        $latestTag = (Invoke-RestMethod -Uri "https://api.github.com/repos/windtf/wireproxy/releases/latest" -ErrorAction Stop).tag_name
    }
    catch { }

    # Marker matches AND binary still present => up to date. The second check
    # covers manual deletion while the marker survived.
    $upToDate = [bool]($latestTag -and
        (Test-Path $versionFile) -and
        ((Get-Content $versionFile -Raw).Trim() -eq $latestTag) -and
        (Test-Path $wireproxyExe))

    if (-not $upToDate -and -not $CheckOnly)
    {
        $wireproxyTarUrl  = if ($latestTag) { "https://github.com/windtf/wireproxy/releases/download/$latestTag/wireproxy_windows_amd64.tar.gz" }
                            else            { "https://github.com/windtf/wireproxy/releases/latest/download/wireproxy_windows_amd64.tar.gz" }
        $wireproxyTarPath = Join-Path $env:TEMP "wireproxy.tar.gz"

        Invoke-WebRequest -Uri $wireproxyTarUrl -OutFile $wireproxyTarPath -UseBasicParsing
        tar -xzf $wireproxyTarPath -C $wireproxyBinDir wireproxy.exe
        Remove-Item $wireproxyTarPath -Force

        if ($latestTag) { Set-Content -Path $versionFile -Value $latestTag -NoNewline }
    }

    if (-not $CheckOnly)
    {
        $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
        if ($userPath -notlike "*$wireproxyBinDir*")
        {
            [Environment]::SetEnvironmentVariable("Path", "$userPath;$wireproxyBinDir", "User")
        }
        $env:Path += ";$wireproxyBinDir"
    }

    return [pscustomobject]@{
        Path     = $wireproxyExe
        UpToDate = $upToDate
    }
}
