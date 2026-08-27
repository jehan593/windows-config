<#
.SYNOPSIS
    GitGet — a simple terminal-based Windows installer tracker.

.DESCRIPTION
    Tracks apps by their GitHub repo, checks for new releases, and downloads
    + runs the matching Windows installer (.exe/.msi/.msix/.msixbundle).
    Only real installers are tracked - portable binaries and archives
    (.zip/.tar.gz) are not supported. Pure PowerShell, no dependencies
    beyond what ships with Windows 11.

.EXAMPLE
    gitget add sharkdp/bat

.EXAMPLE
    gitget add alacritty/alacritty -Pattern "*x64*.msi"

.EXAMPLE
    # Adding software you already have installed? Tell it the version, or it
    # won't know what you're on and 'check' will (correctly) flag an update.
    gitget add sharkdp/bat -CurrentVersion v0.24.0

.EXAMPLE
    gitget check

.EXAMPLE
    gitget update

.EXAMPLE
    gitget update -All

.EXAMPLE
    gitget ls

.EXAMPLE
    gitget proxy 127.0.0.1:1080

.EXAMPLE
    gitget proxy socks5h://127.0.0.1:1080

.EXAMPLE
    gitget proxy clear

.NOTES
    Config and downloads live in:
      $env:LOCALAPPDATA\windows-config-files\gitget\config.json
      $env:LOCALAPPDATA\windows-config-files\gitget\downloads\<app_name>\

    Set $env:GITHUB_TOKEN to raise the GitHub API rate limit
    (60/hr unauthenticated -> 5000/hr authenticated). Not required for normal use.

    Asset picking: when you're prompted to pick (during 'add', or during
    'update' if a release no longer has the previously-picked file), only
    files that look like Windows installers (.exe, .msi, .msix,
    .msixbundle) are ever offered - everything else on a release (archives,
    checksums, portable binaries for other OSes, etc.) is filtered out
    before you see the picker. Your CPU arch is preferred automatically.
    'add' asks you to pick the installer once (fzf menu if installed,
    numbered menu otherwise) and remembers that choice. Routine 'check'/
    'update' runs after that just reuse the remembered file name/pattern
    directly - no re-filtering.

    Not every .exe on a release is actually an installer - some projects
    ship a plain portable binary alongside (or instead of) a real
    installer, and GitGet can't tell the difference by filename alone.
    The picker warns about this; pick the one that's actually an installer
    (typically named things like "*-setup.exe", "*-installer.exe", or a
    .msi/.msix), not a bare portable .exe.

    After downloading, the installer is run automatically (.msi via
    'msiexec /passive', .msix/.msixbundle via Add-AppxPackage, .exe run
    directly) and the downloaded file is deleted once it exits cleanly /
    installs successfully.

    You may need to allow local scripts to run:
      Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
#>

param(
    [Parameter(Position = 0)]
    [string]$Command,

    [Parameter(Position = 1)]
    [string]$Target,          # repo (for add), app name (for rm/check), or proxy URL/clear (for proxy)

    [string]$RestorePath,     # path to config file to restore (for 'restore')

    [string]$Name,             # local name override for 'add'
    [string]$Pattern,          # asset glob pattern for 'add'
    [string]$Dir,               # download staging dir override for 'add' (installer runs from here, then gets deleted)
    [string]$CurrentVersion,    # version you already have installed, for 'add'

    [string]$VersionExe,        # exe filename (relative to install_dir) to query for version, for 'add'
    [string]$VersionCommand,    # arg to pass the exe to print its version, e.g. "--version", for 'add'
    [string]$VersionRegex,      # regex (first capture group = version) to pull the version out of that output, for 'add'

    [string]$Proxy,             # socks5://host:port for one-off override (not persisted)

    [switch]$All                # for 'update': update all without fzf picker
)

$ErrorActionPreference = "Stop"

$ConfigPath = $env:WINDOWS_CONFIG_PATH
. "$ConfigPath\helpers\dep-checker.ps1"

$missingDeps = @(_TestDependencies -Commands "git", "fzf")
if ($Proxy -or $Command -eq "proxy") {
    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
        $missingDeps += "curl.exe"
    }
}
if ($missingDeps.Count -gt 0)
{
    foreach ($dep in $missingDeps) { Write-Host "$dep not found" -ForegroundColor Red }
    Write-Host "Script stopped due to missing dependencies.`n" -ForegroundColor Red
    return
}

$AppDir         = Join-Path $env:LOCALAPPDATA "windows-config-files\gitget"
$ConfFilePath   = Join-Path $AppDir "config.json"
$DownloadsDir   = Join-Path $AppDir "downloads"

# Only these are ever offered/tracked - this script only handles Windows
# installers, not portable binaries or archives.
$InstallerExtensions = @(".exe", ".msi", ".msix", ".msixbundle")

function _TestIsInstallerAsset($AssetName) {
    $ext = [System.IO.Path]::GetExtension($AssetName).ToLower()
    return $InstallerExtensions -contains $ext
}

function _TestIsSocks5($Url) {
    return $Url -and ($Url.StartsWith("socks5://") -or $Url.StartsWith("socks5h://"))
}

function _ParseSocks5Url($Url) {
    # "socks5://127.0.0.1:1080" -> @{ host = "127.0.0.1"; port = "1080" }
    $stripped = $Url -replace '^socks5h?://', ''
    $parts = $stripped -split ':', 2
    return @{ host = $parts[0]; port = if ($parts.Count -gt 1) { $parts[1] } else { "1080" } }
}

function _ResolveProxy {
    # Resolution order: -Proxy param > config > env > none
    if ($Proxy) { return $Proxy }
    $config = _GetConfig
    if ($config.proxy) { return $config.proxy }
    if ($env:GITHUB_PROXY) { return $env:GITHUB_PROXY }
    return $null
}

# --------------------------------------------------------------------------
# Config handling
# --------------------------------------------------------------------------

function _GetConfig {
    if (-not (Test-Path $ConfFilePath)) {
        return [PSCustomObject]@{ apps = [PSCustomObject]@{} }
    }
    $raw = Get-Content $ConfFilePath -Raw | ConvertFrom-Json
    if (-not $raw.apps) {
        $raw | Add-Member -NotePropertyName apps -NotePropertyValue ([PSCustomObject]@{}) -Force
    }
    return $raw
}

function _SaveConfig($config) {
    New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
    $config | ConvertTo-Json -Depth 10 | Set-Content -Path $ConfFilePath -Encoding UTF8
}

function _GetAppEntry($config, $name) {
    $config.apps.PSObject.Properties | Where-Object { $_.Name -eq $name } | Select-Object -First 1
}

# --------------------------------------------------------------------------
# GitHub API
# --------------------------------------------------------------------------

function _InvokeGitHubApi($Url, $ProxyUrl) {
    $headers = @{
        "Accept"     = "application/vnd.github+json"
        "User-Agent" = "GitGet-PS/1.0"
    }
    if ($env:GITHUB_TOKEN) {
        $headers["Authorization"] = "Bearer $env:GITHUB_TOKEN"
    }
    try {
        if (_TestIsSocks5 $ProxyUrl) {
            $parsed = _ParseSocks5Url $ProxyUrl
            $curlArgs = @("--socks5-hostname", "$($parsed.host):$($parsed.port)", "-s", "-f")
            foreach ($k in $headers.Keys) {
                $curlArgs += "-H"; $curlArgs += "${k}: $($headers[$k])"
            }
            $curlArgs += $Url
            $out = & curl.exe @curlArgs 2>&1
            if ($LASTEXITCODE -ne 0) { throw "curl exited with code $LASTEXITCODE" }
            return ($out -join "`n") | ConvertFrom-Json
        }
        return Invoke-RestMethod -Uri $Url -Headers $headers -Method Get
    }
    catch {
        $status = $_.Exception.Response.StatusCode.value__
        if ($status -eq 404) {
            throw "Repo or release not found: $Url"
        }
        elseif ($status -eq 403) {
            throw "GitHub API rate limit hit. Set `$env:GITHUB_TOKEN to raise it."
        }
        else {
            throw "GitHub API error: $($_.Exception.Message)"
        }
    }
}

function _GetLatestRelease($Repo, $ProxyUrl) {
    return _InvokeGitHubApi "https://api.github.com/repos/$Repo/releases/latest" $ProxyUrl
}

function _GetReleases($Repo, $Count = 40, $ProxyUrl) {
    return @(_InvokeGitHubApi "https://api.github.com/repos/$Repo/releases?per_page=$Count" $ProxyUrl)

}

# Some projects split their releases per platform into separate tags instead
# of one release with all assets (streetwriters/notesnook keeps desktop
# installers under "v3.4.6"-style tags and APKs under "3.4.9-android"). Which
# of those GitHub marks as "latest" just depends on what was published/marked
# last, so it can be a tag with no Windows installer at all. Instead of
# trusting /releases/latest, track the newest release that actually ships our
# kind of installer.
function _GetTagFamily($Tag) {
    # Non-numeric skeleton of a tag - identifies the product/platform release
    # line inside repos that publish several in parallel (ente/ente ships
    # auth-, photos-, locker-, ensu-, cli- lines; notesnook splits desktop
    # vs "-android"). "auth-v4.4.25" -> "auth-v", "v3.4.6" -> "v",
    # "3.4.9-android" -> "-android".
    if (-not $Tag) { return $null }
    return ($Tag.Trim() -replace '[\d\.]', '')
}

function _GetTrackedRelease($AppName, $App, $ProxyUrl) {
    $releases = _GetReleases $App.repo 40 $ProxyUrl
    if (-not $releases -or $releases.Count -eq 0) {
        return (_GetLatestRelease $App.repo $ProxyUrl)
    }
    $stable = @($releases | Where-Object { -not $_.prerelease })

    # Monorepo product line (ente/ente publishes auth-/photos-/locker-/cli-
    # lines on one releases page): stay inside the family the app was added
    # from, no matter how much more active its sibling products are.
    if ($App.tag_family) {
        foreach ($rel in $stable) {
            if ((_GetTagFamily $rel.tag_name) -eq $App.tag_family) { return $rel }
        }
    }

    # Newest stable release still carrying exactly the file we track (by
    # remembered name or pattern). This pins us to our platform's tag family
    # even when sibling platform releases get published more often.
    foreach ($rel in $stable) {
        $assets         = @($rel.assets)
        $matchByName    = $App.current_asset -and ($assets.name -contains $App.current_asset)
        $matchByPattern = $App.pattern -and (@($assets | Where-Object { $_.name -like $App.pattern }).Count -gt 0)
        if ($matchByName -or $matchByPattern) { return $rel }
    }

    # Otherwise: newest stable release carrying any installer-type asset.
    foreach ($rel in $stable) {
        if (@($rel.assets | Where-Object { _TestIsInstallerAsset $_.name }).Count -gt 0) { return $rel }
    }

    # Last resort: old behavior.
    return (_GetLatestRelease $App.repo $ProxyUrl)
}

function _GetReleaseLines($InstallableReleases) {
    # Group installer-bearing releases by their tag family (release line),
    # keeping each group's newest release first. Returns Group-Object output.
    return @(@($InstallableReleases | ForEach-Object {
        [PSCustomObject]@{ rel = $_; family = _GetTagFamily $_.tag_name }
    } | Group-Object family))
}

function _SelectReleaseLine($FamilyGroups) {
    Write-Host "This repo publishes several independent release lines - which one do you want to track?"
    $lines = @($FamilyGroups | ForEach-Object {
        $label = "{0}  ({1} release(s), e.g. {2})" -f $_.Name, $_.Count, $_.Group[0].rel.tag_name
        if ($_.Group[0].rel.tag_name -eq $FamilyGroups[0].Group[0].rel.tag_name) { $label += "  [recommended]" }
        $label
    })
    $picked = @($lines | fzf --prompt="release line> " --no-sort)[0]
    if ($LASTEXITCODE -eq 0 -and $picked) {
        return $FamilyGroups[[array]::IndexOf($lines, $picked)].Group[0].rel
    }
    return $FamilyGroups[0].Group[0].rel
}

function _GetNativeArch {
    switch ($env:PROCESSOR_ARCHITECTURE) {
        "ARM64" { return "arm64" }
        "AMD64" { return "x64" }
        "X86"   { return "x86" }
        default { return $null }
    }
}

# --------------------------------------------------------------------------
# Installed-version detection
#
# The config's "current_version" is only ever a claim - it's whatever was
# true the last time GitGet itself downloaded/installed something, or
# whatever you typed via -CurrentVersion / set-version. If the app got
# updated (or reinstalled, or removed) through some other means, that claim
# goes stale silently. These functions try to find the *actual* installed
# version by other means, in order of trustworthiness, before ever falling
# back to the recorded value.
# --------------------------------------------------------------------------

function _NormalizeVersion($v) {
    if (-not $v) { return $v }
    $t = $v.Trim()
    # Strip non-numeric scheme prefixes so "auth-v4.4.25" (monorepo product
    # tags, e.g. ente/ente), "ver1.2" and "v9.8" all compare as "4.4.25".
    # Also drop "+build" metadata ("4.4.25+1072") - semver ignores it too.
    $stripped = (($t -replace '^[^\d]+', '') -replace '\+.*$', '')
    return $(if ($stripped) { $stripped } else { $t })
}

function _TestSameVersion($a, $b) {
    # Chromium-family browsers write "<chromium-major>.<real-version>" into
    # the registry (Brave 1.93.138 -> 151.1.93.138) while their GitHub tags
    # are just "v<real-version>". Two versions are the same release when
    # they match exactly or differ by exactly one extra leading segment.
    $na = _NormalizeVersion $a
    $nb = _NormalizeVersion $b
    if ($na -eq $nb) { return $true }
    if (-not $na -or -not $nb) { return $false }

    $pa = @($na -split '\.')
    $pb = @($nb -split '\.')
    if ([Math]::Abs($pa.Count - $pb.Count) -ne 1) { return $false }
    if ($pa.Count -gt $pb.Count) { $pa = @($pa[1..($pa.Count - 1)]) }
    else                         { $pb = @($pb[1..($pb.Count - 1)]) }
    return (($pa -join '.') -eq ($pb -join '.'))
}

function _FindInstalledExe($App) {
    if ($App.version_exe -and $App.install_dir) {
        $candidate = Join-Path $App.install_dir $App.version_exe
        if (Test-Path $candidate) { return $candidate }
    }
    if ($App.install_dir -and (Test-Path $App.install_dir)) {
        return (Get-ChildItem -Path $App.install_dir -Filter *.exe -Recurse -ErrorAction SilentlyContinue |
                Select-Object -First 1).FullName
    }
    return $null
}

function _InvokeWithTimeout($ExePath, $Arg, $TimeoutMs = 4000) {
    # Some exe won't recognize --version/-v and may just hang (waiting on
    # stdin, opening a GUI, etc.) instead of erroring. Run it out-of-line
    # with redirected output and a hard kill after $TimeoutMs so a single
    # misbehaving app can't freeze 'check'/'list -Verify'.
    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $proc = Start-Process -FilePath $ExePath -ArgumentList $Arg -WindowStyle Hidden -PassThru `
                    -RedirectStandardOutput $outFile -RedirectStandardError $errFile -ErrorAction Stop
        $exited = $proc.WaitForExit($TimeoutMs)
        if (-not $exited) {
            try { $proc.Kill() } catch { }
            return $null
        }
        return (Get-Content $outFile -Raw -ErrorAction SilentlyContinue) + "`n" + (Get-Content $errFile -Raw -ErrorAction SilentlyContinue)
    }
    catch {
        return $null
    }
    finally {
        Remove-Item $outFile, $errFile -ErrorAction SilentlyContinue
    }
}

function _GetVersionFromCommand($ExePath, [string[]]$ArgList, $Regex) {
    if (-not $ExePath -or -not (Test-Path $ExePath)) { return $null }
    $pattern = if ($Regex) { $Regex } else { 'v?(\d+\.\d+(?:\.\d+){0,2})' }
    foreach ($a in $ArgList) {
        $out = _InvokeWithTimeout $ExePath $a
        if (-not $out) { continue }
        $m = [regex]::Match($out, $pattern)
        if ($m.Success) {
            return $(if ($m.Groups.Count -gt 1 -and $m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Value })
        }
    }
    return $null
}

function _GetVersionFromFileMetadata($ExePath) {
    if (-not $ExePath -or -not (Test-Path $ExePath)) { return $null }
    $vi = (Get-Item $ExePath).VersionInfo
    foreach ($v in @($vi.ProductVersion, $vi.FileVersion)) {
        if ($v -and $v.Trim() -and $v.Trim() -ne "0.0.0.0") { return $v.Trim() }
    }
    return $null
}

function _GetVersionSearchNeedles($App, $AppName) {
    # What's recorded as the app name/repo often isn't literally what shows
    # up in the registry or winget (e.g. tracked as "brave-browser" but the
    # installed DisplayName is just "Brave"). Try the full name first, then
    # fall back to the repo owner and individual word-tokens split out of
    # the name, so a partial/marketing-name match still succeeds.
    $repoName  = ($App.repo -split '/')[1]
    $repoOwner = ($App.repo -split '/')[0]
    $whole     = @($AppName, $repoName, $repoOwner) | Where-Object { $_ }

    $tokens = @()
    foreach ($w in @($AppName, $repoName)) {
        if (-not $w) { continue }
        $tokens += ($w -split '[-_\s]+' | Where-Object { $_.Length -ge 3 })
    }

    # CamelCase / PascalCase splitting: "LenovoLegionToolkit" -> "Lenovo",
    # "Legion", "Toolkit" so the unspaced repo name still matches the
    # spaced DisplayName ("Lenovo Legion Toolkit") in registry/winget.
    $splitTokens = @()
    foreach ($w in @($AppName, $repoName)) {
        if (-not $w) { continue }
        $parts = [regex]::Split($w, '(?<=[a-z])(?=[A-Z])')
        $splitTokens += ($parts | Where-Object { $_.Length -ge 3 })
    }

    return @($whole + $tokens + $splitTokens | Where-Object { $_ } | Select-Object -Unique)
}

function _TestDisplayNameMatch($DisplayName, $Needle) {
    # Exact name wins outright; otherwise the needle must appear delimited by
    # non-alphanumerics (or string edges). Plain substring matching was too
    # loose - tracking "ente" used to match "Microsoft 365 Apps for
    # enterprise" and read Office's 16.0.x as the installed version.
    if (-not $DisplayName) { return $false }
    if ($DisplayName -eq $Needle) { return $true }
    return ($DisplayName -match "(?i)(^|[^a-z0-9])$([regex]::Escape($Needle))([^a-z0-9]|$)")
}

function _GetVersionFromRegistry($App, $AppName) {
    $roots = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    $entries = @(Get-ItemProperty -Path $roots -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName })
    if (-not $entries) { return $null }

    $needles = _GetVersionSearchNeedles $App $AppName
    foreach ($n in $needles) {
        $exact = @($entries | Where-Object { $_.DisplayName -eq $n -and $_.DisplayVersion })
        if ($exact.Count -gt 0) { return $exact[0].DisplayVersion }

        $hit = @($entries | Where-Object { $_.DisplayVersion -and (_TestDisplayNameMatch $_.DisplayName $n) })
        if ($hit.Count -gt 0) { return $hit[0].DisplayVersion }
    }
    return $null
}

function _GetVersionFromWinget($App, $AppName) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { return $null }

    $needles = _GetVersionSearchNeedles $App $AppName
    foreach ($n in $needles) {
        try {
            $lines = @(winget list --name $n --accept-source-agreements 2>&1 | Where-Object { $_ -and $_.Trim() -ne "" })
        }
        catch { continue }
        if (-not $lines) { continue }

        # winget prints a fixed-width table: "Name  Id  Version  ...". Find
        # the header row so we know where the Version column starts/ends,
        # since names/ids can themselves contain spaces.
        $headerIdx = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^Name\s+Id\s+Version') { $headerIdx = $i; break }
        }
        if ($headerIdx -lt 0) { continue }

        $header     = $lines[$headerIdx]
        $versionCol = $header.IndexOf("Version")
        $availCol   = $header.IndexOf("Available")
        if ($versionCol -lt 0) { continue }

        for ($i = $headerIdx + 1; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            if ($line -match '^-+$' -or $line.Length -le $versionCol) { continue }
            $endCol = if ($availCol -gt $versionCol) { $availCol } else { $line.Length }
            $name = $line.Substring(0, $versionCol).Trim()
            $ver = $line.Substring($versionCol, [Math]::Min($endCol, $line.Length) - $versionCol).Trim()
            if ($ver -and (_TestDisplayNameMatch $name $n)) { return $ver }
        }
    }
    return $null
}

function _GetInstalledVersion($AppName, $App) {
    # Returns @{ version = <string-or-null>; source = <string> }, trying
    # progressively less-direct sources. Anything above "recorded" is an
    # independent check of reality; "recorded" is just trusting the config.
    $exePath = _FindInstalledExe $App

    if ($App.version_command) {
        $v = _GetVersionFromCommand $exePath @($App.version_command) $App.version_regex
        if ($v) { return @{ version = $v; source = "version command" } }
    }

    if ($exePath) {
        $v = _GetVersionFromCommand $exePath @("--version", "-version", "-v", "-V") $App.version_regex
        if ($v) { return @{ version = $v; source = "exe --version" } }

        $v = _GetVersionFromFileMetadata $exePath
        if ($v) { return @{ version = $v; source = "file metadata" } }
    }

    $v = _GetVersionFromRegistry $App $AppName
    if ($v) { return @{ version = $v; source = "registry" } }

    $v = _GetVersionFromWinget $App $AppName
    if ($v) { return @{ version = $v; source = "winget" } }

    if ($App.current_version) { return @{ version = $App.current_version; source = "recorded (unverified)" } }

    return @{ version = $null; source = "unknown" }
}

function _GetArchScore($FileName, $Arch) {
    if (-not $Arch) { return 1 }
    $n     = $FileName.ToLower()
    $isArm = $n -match 'aarch64|arm64|\barm\b'
    $isX64 = $n -match 'x64|amd64|x86[_-]64|win64|64bit'
    $isX86 = $n -match '\bx86\b|win32|i[36]86|32bit'
    switch ($Arch) {
        "arm64" { if ($isArm -and -not $isX64) { return 2 } }
        "x64"   { if ($isX64 -and -not $isArm) { return 2 } }
        "x86"   { if ($isX86 -and -not ($isX64 -or $isArm)) { return 2 } }
    }
    if (-not ($isArm -or $isX64 -or $isX86)) { return 1 }
    return 0
}

function _SelectAssetFromList($Candidates, $RecommendedName) {
    $ordered = @($Candidates)
    if ($RecommendedName) {
        $rec  = @($ordered | Where-Object { $_.name -eq $RecommendedName })
        $rest = @($ordered | Where-Object { $_.name -ne $RecommendedName })
        $ordered = $rec + $rest
    }

    $names = @($ordered | ForEach-Object {
        $label = "{0}  ({1} MB)" -f $_.name, [math]::Round($_.size / 1MB, 1)
        if ($RecommendedName -and $_.name -eq $RecommendedName) { $label += "  [recommended]" }
        $label
    })

    Write-Host "Warning: not every .exe here is necessarily an installer - some projects also"
    Write-Host "ship a plain portable binary. Don't pick that; pick the actual installer"
    Write-Host "(often named like '*-setup.exe'/'*-installer.exe', or a .msi/.msix)."

    Write-Host "Pick an installer (showing all $($names.Count) installer-type files on this release, esc to cancel):"
    $picked = @($names | fzf --prompt="installer> " --no-sort)[0]
    if ($LASTEXITCODE -eq 0 -and $picked) {
        return $ordered[[array]::IndexOf($names, $picked)]
    }
    return $null
}

function _SelectAsset($Assets, $GlobPattern, [switch]$Interactive) {
    if (-not $Assets -or @($Assets).Count -eq 0) { return $null }

    if ($Interactive) {
        # Only the interactive picker (used by 'add', and by 'update' when
        # it needs you to re-pick a type) restricts to installer extensions.
        # Automatic matching below (check/update reusing an already-tracked
        # pattern) doesn't need this - the stored pattern already pins down
        # exactly the file that was picked before.
        $installers = @($Assets | Where-Object { _TestIsInstallerAsset $_.name })
        if ($installers.Count -eq 0) { return $null }

        $candidates = $installers
        if ($GlobPattern) {
            $matched = @($candidates | Where-Object { $_.name -like $GlobPattern })
            if ($matched) { $candidates = $matched }
        }

        $arch   = _GetNativeArch
        $scored = @($candidates |
            ForEach-Object { [PSCustomObject]@{ asset = $_; score = _GetArchScore $_.name $arch } } |
            Sort-Object @{Expression = "score"; Descending = $true }, @{Expression = { $_.asset.name }; Descending = $false })
        $topScore = $scored[0].score
        $final    = @($scored | Where-Object { $_.score -eq $topScore } | ForEach-Object { $_.asset })

        # Always offer the picker over the FULL list of installer-type
        # assets when there's more than one - even if the arch-narrowing
        # above landed on a single "best guess". That guess can be wrong
        # (bad arch detection), and previously that meant you'd never even
        # see the file you wanted.
        if ($installers.Count -gt 1) {
            $recommendedName = if ($final.Count -gt 0) { $final[0].name } else { $null }
            return _SelectAssetFromList $installers $recommendedName
        }
        return $installers[0]
    }

    # Non-interactive: just match by pattern + arch, no extension filtering.
    $candidates = @($Assets)
    if ($GlobPattern) {
        $matched = @($candidates | Where-Object { $_.name -like $GlobPattern })
        if ($matched) { $candidates = $matched }
    }

    $arch   = _GetNativeArch
    $scored = @($candidates |
        ForEach-Object { [PSCustomObject]@{ asset = $_; score = _GetArchScore $_.name $arch } } |
        Sort-Object @{Expression = "score"; Descending = $true }, @{Expression = { $_.asset.name }; Descending = $false })
    $topScore = $scored[0].score
    $final = @($scored | Where-Object { $_.score -eq $topScore } | ForEach-Object { $_.asset })
    return $final[0]
}

function _SaveAsset($Asset, $DestDir, $ProxyUrl) {
    New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
    $destPath = Join-Path $DestDir $Asset.name
    $sizeMb = [math]::Round($Asset.size / 1MB, 1)
    Write-Host "Downloading $($Asset.name) ($sizeMb MB)..."

    if (_TestIsSocks5 $ProxyUrl) {
        $parsed = _ParseSocks5Url $ProxyUrl
        & curl.exe --socks5-hostname "$($parsed.host):$($parsed.port)" -L -f -o $destPath $Asset.browser_download_url
        if ($LASTEXITCODE -ne 0) {
            throw "curl download failed (exit code $LASTEXITCODE)"
        }
    }
    else {
        Invoke-WebRequest -Uri $Asset.browser_download_url -OutFile $destPath -UseBasicParsing
    }
    return $destPath
}

function _NewAssetPattern($FileName) {
    # Turns a concrete asset name into a reusable glob by dropping
    # version-ish tokens: bat-v0.26.1-x86_64-pc-windows-msvc.zip ->
    # *x86_64*pc*windows*msvc.zip
    $kept = @($FileName -split '[\s-]+' | Where-Object { $_ } | Where-Object {
        $_ -notmatch '^v?\d+$' -and $_ -notmatch '^v?\d+(\.\d+)+$' -and $_ -notmatch '\d\.\d'
    })
    if ($kept.Count -eq 0) { return "*" }
    return "*" + ($kept -join "*")
}

function _InstallDownloadedAsset($Path) {
    $leaf = Split-Path -Leaf $Path
    $ext  = [System.IO.Path]::GetExtension($Path).ToLower()

    switch ($ext) {
        ".msi" {
            Write-Host "Installing (msiexec /passive): $leaf"
            try {
                $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i", "`"$Path`"", "/passive", "/norestart" -Wait -PassThru
                if ($proc.ExitCode -eq 0) {
                    Remove-Item -LiteralPath $Path -Force
                    Write-Host "Install finished; deleted $leaf" -ForegroundColor Green
                }
                else {
                    Write-Host "msiexec exited with code $($proc.ExitCode); installer kept at $Path" -ForegroundColor Yellow
                }
            }
            catch {
                Write-Host "Could not start install ($($_.Exception.Message)); installer kept at $Path" -ForegroundColor Red
            }
        }
        ".exe" {
            Write-Host "Running installer: $leaf"
            try {
                $proc = Start-Process -FilePath $Path -Wait -PassThru
                if ($proc.ExitCode -eq 0) {
                    Remove-Item -LiteralPath $Path -Force
                    Write-Host "Installer finished; deleted $leaf" -ForegroundColor Green
                }
                else {
                    Write-Host "Installer exited with code $($proc.ExitCode); file kept at $Path" -ForegroundColor Yellow
                }
            }
            catch {
                Write-Host "Could not start installer ($($_.Exception.Message)); file kept at $Path" -ForegroundColor Red
            }
        }
        { $_ -in ".msix", ".msixbundle" } {
            Write-Host "Installing (Add-AppxPackage): $leaf"
            try {
                Add-AppxPackage -Path $Path -ErrorAction Stop
                Remove-Item -LiteralPath $Path -Force
                Write-Host "Install finished; deleted $leaf" -ForegroundColor Green
            }
            catch {
                Write-Host "Add-AppxPackage failed ($($_.Exception.Message)); file kept at $Path" -ForegroundColor Red
                Write-Host "(this usually means the package's signing certificate isn't trusted yet)" -ForegroundColor Yellow
            }
        }
        default {
            # Shouldn't normally happen - _SelectAsset only ever returns
            # installer-extension assets - but kept as a safety net.
            Write-Host "Unrecognized installer type ($ext); kept for manual install at $Path" -ForegroundColor Yellow
        }
    }
}

# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------

function _ConvertToRepoSlug($Raw) {
    # Accepts 'owner/repo', a full https://github.com/owner/repo URL, or
    # git@github.com:owner/repo.git, and returns 'owner/repo' (or $null).
    $s = $Raw.Trim().Trim('/')

    if ($s.StartsWith("git@github.com:")) {
        $s = $s.Substring("git@github.com:".Length)
    }
    elseif ($s -match 'github\.com/(.+)$') {
        $s = $Matches[1]
    }

    $s = $s.Trim('/')
    if ($s.EndsWith(".git")) { $s = $s.Substring(0, $s.Length - 4) }

    $parts = $s -split '/' | Where-Object { $_ -ne '' }
    if ($parts.Count -lt 2) { return $null }
    return "$($parts[0])/$($parts[1])"
}

function _Backup {
    if (-not (Test-Path $ConfFilePath)) {
        Write-Host "No config file found." -ForegroundColor Yellow
        return
    }
    $backupDir = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "windows-config-backup\gitget"
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    $dest = Join-Path $backupDir "config.json"
    Copy-Item -LiteralPath $ConfFilePath -Destination $dest -Force
    Write-Host "Backed up to: Documents\windows-config-backup\gitget\config.json" -ForegroundColor Green
}

function _Restore {
    if (-not $RestorePath) {
        Write-Host "Provide a config file path, e.g. gitget restore C:\path\to\config.json" -ForegroundColor Red
        return
    }
    if (-not (Test-Path $RestorePath)) {
        Write-Host "File not found: $RestorePath" -ForegroundColor Red
        return
    }
    New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
    Copy-Item -LiteralPath $RestorePath -Destination $ConfFilePath -Force
    Write-Host "Restored config from: $RestorePath" -ForegroundColor Green
}

function _Add {
    if (-not $Target) { Write-Host "Provide a repo, e.g. gitget add sharkdp/bat" -ForegroundColor Red; return }
    $repo = _ConvertToRepoSlug $Target
    if (-not $repo) {
        Write-Host "Couldn't parse a repo. Use 'owner/repo' or a github.com URL." -ForegroundColor Red
        return
    }

    $proxyUrl = _ResolveProxy

    $defaultName = ($repo -split '/')[1]
    if ($Name) {
        $appName = $Name
    } else {
        $resp = Read-Host "Name? [$defaultName]"
        $appName = if ($null -eq $resp -or $resp.Trim() -eq "") { $defaultName } else { $resp.Trim() }
    }
    $config = _GetConfig
    if (_GetAppEntry $config $appName) {
        Write-Host "'$appName' already tracked." -ForegroundColor Yellow
        return
    }

    $releases = _GetReleases $repo 40 $proxyUrl
    $installable = @(@($releases | Where-Object { -not $_.prerelease }) |
        Where-Object { @($_.assets | Where-Object { _TestIsInstallerAsset $_.name }).Count -gt 0 })
    $release = $null
    if ($installable.Count -gt 0) {
        $byFamily = @(_GetReleaseLines $installable)
        if ($byFamily.Count -gt 1) {
            $release = _SelectReleaseLine $byFamily
        } else {
            $release = $installable[0]
        }
    }
    if (-not $release) { $release = _GetLatestRelease $repo $proxyUrl }
    $asset = _SelectAsset $release.assets $Pattern -Interactive

    if (-not $asset) {
        Write-Host "No installer assets found on latest release." -ForegroundColor Yellow
        if ($release.assets) {
            $release.assets | ForEach-Object { Write-Host "  $($_.name)" }
        }
        return
    }

    $installDir = if ($Dir) { $Dir } else { Join-Path $DownloadsDir $appName }

    $entry = [PSCustomObject]@{
        repo             = $repo
        tag_family       = _GetTagFamily $release.tag_name
        pattern          = if ($Pattern) { $Pattern } else { _NewAssetPattern $asset.name }
        install_dir      = $installDir
        current_version  = if ($CurrentVersion) { $CurrentVersion } else { $null }
        current_asset    = $asset.name
        last_checked     = (Get-Date).ToUniversalTime().ToString("o")
        version_exe      = if ($VersionExe) { $VersionExe } else { $null }
        version_command  = if ($VersionCommand) { $VersionCommand } else { $null }
        version_regex    = if ($VersionRegex) { $VersionRegex } else { $null }
    }
    $config.apps | Add-Member -NotePropertyName $appName -NotePropertyValue $entry -Force
    _SaveConfig $config

    Write-Host "$appName $($release.tag_name) ($($asset.name))" -ForegroundColor Green
}

function _Remove {
    $config = _GetConfig
    $entries = $config.apps.PSObject.Properties
    if (-not $entries -or $entries.Count -eq 0) {
        Write-Host "Nothing tracked." -ForegroundColor Yellow
        return
    }

    $names = @($entries | ForEach-Object { $_.Name })
    $selected = $names | fzf --multi --reverse --height=40% --header="Select to remove"
    if (-not $selected) { return }

    foreach ($name in $selected) {
        $config.apps.PSObject.Properties.Remove($name)
    }
    _SaveConfig $config
}

function _List {
    $config = _GetConfig
    $entries = $config.apps.PSObject.Properties
    if (-not $entries -or $entries.Count -eq 0) {
        Write-Host "Nothing tracked." -ForegroundColor Yellow
        return
    }

    $maxLen = ($entries | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum
    foreach ($prop in $entries) {
        $detected = _GetInstalledVersion $prop.Name $prop.Value
        $ver = if ($detected.version) { $detected.version } else { "-" }
        Write-Host ("{0,-$maxLen}  {1}" -f $prop.Name, $ver)
    }
}

function _CheckOne($appName, $app, $ProxyUrl) {
    try {
        $release = _GetTrackedRelease $appName $app $ProxyUrl
    }
    catch {
        Write-Host "$appName error: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }

    $latestVersion = $release.tag_name
    $configChanged = $false

    if ((_TestSameVersion $app.current_version $latestVersion) -and `
            ((_NormalizeVersion $app.current_version) -ne (_NormalizeVersion $latestVersion))) {
        $app.current_version = $latestVersion
        $configChanged = $true
    }

    $detected = _GetInstalledVersion $appName $app
    if ($detected.version -and $detected.source -ne "recorded (unverified)" `
            -and -not (_TestSameVersion $detected.version $app.current_version)) {
        $app.current_version = $detected.version
        $configChanged = $true
    }

    $asset = _SelectAsset $release.assets $app.pattern
    $hasUpdate = -not (_TestSameVersion $latestVersion $app.current_version)

    if ($hasUpdate) {
        Write-Host $appName -ForegroundColor Yellow
    }

    return [PSCustomObject]@{ release = $release; asset = $asset; hasUpdate = $hasUpdate; configChanged = $configChanged }
}

function _Check {
    $config = _GetConfig
    $entries = $config.apps.PSObject.Properties
    if (-not $entries -or $entries.Count -eq 0) { Write-Host "Nothing tracked." -ForegroundColor Yellow; return }

    if ($Target -and -not (_GetAppEntry $config $Target)) {
        Write-Host "'$Target' is not tracked." -ForegroundColor Yellow; return
    }
    $targets = if ($Target) { $entries | Where-Object { $_.Name -eq $Target } } else { $entries }

    $proxyUrl = _ResolveProxy
    $updateCount = 0
    $configChanged = $false
    foreach ($prop in $targets) {
        $result = _CheckOne $prop.Name $prop.Value $proxyUrl
        if ($result -and $result.hasUpdate) { $updateCount++ }
        if ($result -and $result.configChanged) { $configChanged = $true }
    }
    if ($configChanged) { _SaveConfig $config }

    if ($updateCount -eq 0) {
        Write-Host "Up to date" -ForegroundColor Green
    }
    else {
        Write-Host ""
        Write-Host "$updateCount update(s) available" -ForegroundColor Yellow
    }
}

function _Update {
    $config = _GetConfig
    $entries = $config.apps.PSObject.Properties
    if (-not $entries -or $entries.Count -eq 0) { Write-Host "Nothing tracked." -ForegroundColor Yellow; return }

    $proxyUrl = _ResolveProxy
    $updatable = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($prop in $entries) {
        $appName = $prop.Name
        $app = $prop.Value

        try {
            $release = _GetTrackedRelease $appName $app $proxyUrl
        }
        catch {
            Write-Host "$appName error: $($_.Exception.Message)" -ForegroundColor Red
            continue
        }

        $detected = _GetInstalledVersion $appName $app
        if ($detected.version -and $detected.source -ne "recorded (unverified)" `
                -and -not (_TestSameVersion $detected.version $app.current_version)) {
            $app.current_version = $detected.version
            _SaveConfig $config
        }

        $latestVersion = $release.tag_name
        if ((_TestSameVersion $app.current_version $latestVersion) -and `
                ((_NormalizeVersion $app.current_version) -ne (_NormalizeVersion $latestVersion))) {
            $app.current_version = $latestVersion
            _SaveConfig $config
        }
        if ((_TestSameVersion $latestVersion $app.current_version)) {
            continue
        }

        $updatable.Add([PSCustomObject]@{
            appName = $appName
            app     = $app
            release = $release
            latest  = $latestVersion
        })
    }

    if ($updatable.Count -eq 0) {
        Write-Host "Up to date" -ForegroundColor Green
        return
    }

    $toUpdate = if ($All) {
        $updatable
    }
    else {
        $lines = @($updatable | ForEach-Object {
            $cur = if ($_.app.current_version) { $_.app.current_version } else { "?" }
            "{0}  ({1} -> {2})" -f $_.appName, $cur, $_.latest
        })
        $selected = @($lines | fzf --multi --reverse --height=40% --header="Tab: multi-select, esc: cancel" --prompt="update> ")
        if ($selected.Count -eq 0) { return }
        $picked = @()
        foreach ($s in $selected) {
            $idx = [array]::IndexOf($lines, $s)
            if ($idx -ge 0) { $picked += $updatable[$idx] }
        }
        $picked
    }

    foreach ($item in $toUpdate) {
        Write-Host ""
        $appName = $item.appName
        $app = $item.app
        $release = $item.release
        $latestVersion = $item.latest

        $asset = $null
        if ($app.current_asset) {
            $asset = @($release.assets | Where-Object { $_.name -eq $app.current_asset }) | Select-Object -First 1
            if (-not $asset) {
                Write-Host "$appName new type needed:" -ForegroundColor Yellow
            }
        }
        if (-not $asset) {
            $asset = _SelectAsset $release.assets $app.pattern -Interactive
        }
        if (-not $asset) { continue }

        $path = _SaveAsset $asset $app.install_dir $proxyUrl
        $app.current_version = $latestVersion
        $app.current_asset = $asset.name
        $app.pattern = _NewAssetPattern $asset.name
        $app.last_checked = (Get-Date).ToUniversalTime().ToString("o")
        _SaveConfig $config
        _InstallDownloadedAsset $path
    }
}

function _Proxy {
    $config = _GetConfig

    if (-not $Target -or $Target.Trim() -eq "") {
        # Show current proxy
        if ($config.proxy) {
            Write-Host "Proxy: $($config.proxy)" -ForegroundColor Green
        }
        else {
            Write-Host "No proxy set." -ForegroundColor Yellow
        }
        return
    }

    if ($Target -eq "clear") {
        if ($config.proxy) {
            $config.PSObject.Properties.Remove("proxy")
            _SaveConfig $config
            Write-Host "Proxy cleared." -ForegroundColor Green
        }
        else {
            Write-Host "No proxy was set." -ForegroundColor Yellow
        }
        return
    }

    # Set proxy
    $url = $Target.Trim()
    if (-not (_TestIsSocks5 $url)) {
        # Bare host:port — prepend socks5://
        if ($url -match '^[\w.\-]+:\d+$') {
            $url = "socks5://$url"
        }
        else {
            Write-Host "Proxy must be host:port or socks5://host:port" -ForegroundColor Red
            return
        }
    }
    if ($config.PSObject.Properties["proxy"]) {
        $config.proxy = $url
    }
    else {
        $config | Add-Member -NotePropertyName proxy -NotePropertyValue $url
    }
    _SaveConfig $config
    Write-Host "Proxy set: $url" -ForegroundColor Green
}

# --------------------------------------------------------------------------
# Dispatch
# --------------------------------------------------------------------------

switch ($Command) {
    "add"     { _Add }
    "rm"      { _Remove }
    "ls"      { _List }
    "check"   { _Check }
    "update"  { _Update }
    "backup"  { _Backup }
    "restore" { _Restore }
    "proxy"   { _Proxy }
    default {
        Write-Host ">GitGet" -ForegroundColor Blue
        Write-Host "Usage: gitget <command>" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Commands:"
        Write-Host "  add         - Track a GitHub repo (gitget add owner/repo)"
        Write-Host "  ls          - List tracked apps"
        Write-Host "  rm          - Remove tracked apps (fzf picker)"
        Write-Host "  check       - Check for updates"
        Write-Host "  update      - Download and install available updates (fzf picker, -All to skip)"
        Write-Host "  backup      - Backup config to Documents\windows-config-backup\gitget"
        Write-Host "  restore     - Restore config from a file path"
        Write-Host "  proxy       - Set/show/clear SOCKS5 proxy (gitget proxy host:port)"
        Write-Host ""
    }
}
