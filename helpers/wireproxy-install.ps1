# ==============================================================================
# WIREPROXY BINARY INSTALL
# ==============================================================================
# Silent by design - returns a result object:
#   Success  install succeeded (never throws)
#   UpToDate already at latest release
#   Error    exception message (when Success is $false)
#   Path     path to wireproxy.exe
function Install-Wireproxy
{
    # -CheckOnly compares release tags only, no download.
    param([switch]$CheckOnly)

    $wireproxyBinDir  = "$env:LOCALAPPDATA\windows-config-files\bin"
    $wireproxyExe     = Join-Path $wireproxyBinDir "wireproxy.exe"
    $versionFile      = Join-Path $wireproxyBinDir "wireproxy.version"

    # Never throw - surface failures through the result object.
    $result = [pscustomobject]@{
        Success  = $true
        UpToDate = $false
        Error    = $null
        Path     = $wireproxyExe
    }

    try
    {
        New-Item -ItemType Directory -Path $wireproxyBinDir -Force | Out-Null

        # Resolve the latest tag to skip the download when already up to date.
        $latestTag = $null
        try {
            $latestTag = (Invoke-RestMethod -Uri "https://api.github.com/repos/windtf/wireproxy/releases/latest" -ErrorAction Stop).tag_name
        }
        catch { }

        # Marker + binary present => up to date. Second check covers manual deletion.
        $upToDate = [bool]($latestTag -and
            (Test-Path $versionFile) -and
            ((Get-Content $versionFile -Raw).Trim() -eq $latestTag) -and
            (Test-Path $wireproxyExe))

        # Without a resolved tag a check is inconclusive, not "update pending".
        if ($CheckOnly)
        {
            if (-not $latestTag)
            {
                $result.Success = $false
                $result.Error   = "Could not resolve latest wireproxy release"
            }
            $result.UpToDate = $upToDate
            return $result
        }

        if (-not $upToDate)
        {
            $wireproxyTarUrl  = if ($latestTag) { "https://github.com/windtf/wireproxy/releases/download/$latestTag/wireproxy_windows_amd64.tar.gz" }
                                else            { "https://github.com/windtf/wireproxy/releases/latest/download/wireproxy_windows_amd64.tar.gz" }
            $wireproxyTarPath = Join-Path $env:TEMP "wireproxy.tar.gz"

            Invoke-WebRequest -Uri $wireproxyTarUrl -OutFile $wireproxyTarPath -UseBasicParsing -ErrorAction Stop
            tar -xzf $wireproxyTarPath -C $wireproxyBinDir wireproxy.exe
            if ($LASTEXITCODE -ne 0) { throw "tar extraction of wireproxy failed (exit code $LASTEXITCODE)" }
            Remove-Item $wireproxyTarPath -Force

            if ($latestTag) { Set-Content -Path $versionFile -Value $latestTag -NoNewline }
        }

        if (-not $CheckOnly -and -not (Test-Path $wireproxyExe))
        { throw "wireproxy.exe not found at '$wireproxyExe' after install" }

        if (-not $CheckOnly)
        {
            $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
            if ($userPath -notlike "*$wireproxyBinDir*")
            {
                [Environment]::SetEnvironmentVariable("Path", "$userPath;$wireproxyBinDir", "User")
            }
            $env:Path += ";$wireproxyBinDir"
        }

        $result.UpToDate = $upToDate
        return $result
    }
    catch {
        $result.Success = $false
        $result.Error   = $_.Exception.Message
        return $result
    }
}
