<#
.SYNOPSIS
    GitGet — track GitHub repos and install their Windows releases.

.DESCRIPTION
    Downloads + runs the matching Windows installer (.exe/.msi/.msix/.msixbundle).
    No portable binaries or archives. Pure PowerShell, no extra dependencies.

.EXAMPLE
    gitget add sharkdp/bat
    gitget add alacritty/alacritty -Pattern "*x64*.msi"
    gitget add sharkdp/bat -CurrentVersion v0.24.0
    gitget check
    gitget update
    gitget ls
    gitget proxy 127.0.0.1:1080
    gitget proxy clear

.NOTES
    Config: $env:LOCALAPPDATA\windows-config-files\gitget\config.json
    Set $env:GITHUB_TOKEN for higher API rate limits (60/hr -> 5000/hr).
    Allow local scripts: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
#>

param(
    [Parameter(Position = 0)]
    [string]$Command,

    [Parameter(Position = 1)]
    [string]$Target,          # repo (for add), app name (for rm/check/update), or proxy URL/clear (for proxy)

    [string]$RestorePath,     # path to config file to restore (for 'restore')

    [string]$Name,             # local name override for 'add'
    [string]$Pattern,          # asset glob pattern for 'add'
    [string]$Dir,               # download staging dir override for 'add' (installer runs from here, then gets deleted)
    [string]$CurrentVersion,    # version you already have installed, for 'add'

    [string]$VersionExe,        # exe filename (relative to install_dir) to query for version, for 'add'
    [string]$VersionCommand,    # arg to pass the exe to print its version, e.g. "--version", for 'add'
    [string]$VersionRegex,      # regex (first capture group = version) to pull the version out of that output, for 'add'

    [string]$TagPattern,        # optional glob selecting release tags
    [string]$ReleaseNamePattern,# optional glob selecting release names
    [string]$ReleaseVersionRegex, # extract comparable version from release tag
    [string]$InstalledVersionRegex, # extract comparable version from installed sources
    [string]$DisplayName,       # exact Windows uninstall display name
    [string]$DisplayNamePattern,# glob for display names containing a version
    [Nullable[bool]]$IncludePrerelease,
    [ValidateRange(1, 1000)]
    [int]$ReleaseLimit = 40,

    [string]$Proxy,             # socks5://host:port for one-off override (not persisted)

    [switch]$All,               # for 'update': update all without fzf picker

    [switch]$Force              # for 'check'/'update': ignore cache, always hit the API
)

$ErrorActionPreference = "Stop"

$requiredCommands = @()
if ($Command -in @('add', 'rm', 'update')) { $requiredCommands += 'fzf' }
$missingDeps = @($requiredCommands | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
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
$CacheDir        = Join-Path $AppDir "cache"
$CacheTtlMinutes = if ($env:GITGET_CACHE_TTL_MINUTES) { [int]$env:GITGET_CACHE_TTL_MINUTES } else { 10 }

# Only these are ever offered/tracked - this script only handles Windows
# installers, not portable binaries or archives.
$InstallerExtensions = @(".exe", ".msi", ".msix", ".msixbundle")

function _TestIsInstallerAsset($AssetName) {
    $ext = [System.IO.Path]::GetExtension($AssetName).ToLower()
    return $InstallerExtensions -contains $ext
}

function _TestIsInstallerLike($FileName) {
    if (-not $FileName) { return $false }
    return $FileName -match '(?i)setup|installer|install|update|updater|stub'
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

function _ExtractConfiguredVersion($Value, $Regex) {
    if (-not $Regex -or -not $Value) { return $Value }
    $match = [regex]::Match($Value, $Regex)
    if (-not $match.Success) { throw "Version '$Value' does not match configured regex '$Regex'." }
    if ($match.Groups.Count -gt 1 -and $match.Groups[1].Success) { return $match.Groups[1].Value }
    return $match.Value
}

function _Configure {
    $config = _GetConfig
    $entry = _GetAppEntry $config $Target
    if (-not $entry) { Write-Host "'$Target' is not tracked." -ForegroundColor Yellow; return }
    $settings = @{
        Pattern='pattern'; TagPattern='tag_pattern'; ReleaseNamePattern='release_name_pattern'
        ReleaseVersionRegex='release_version_regex'; InstalledVersionRegex='installed_version_regex'
        DisplayName='display_name'; DisplayNamePattern='display_name_pattern'; VersionExe='version_exe'; VersionCommand='version_command'
        VersionRegex='version_regex'; IncludePrerelease='include_prerelease'; CurrentVersion='current_version'
        ReleaseLimit='release_limit'
    }
    $changed = $false
    foreach ($key in $settings.Keys) {
        if (-not $script:PSBoundParameters.ContainsKey($key)) { continue }
        $value = $script:PSBoundParameters[$key]
        if ($key -like '*Regex' -and $value) { $null = [regex]::new($value) }
        $entry.Value | Add-Member -NotePropertyName $settings[$key] -NotePropertyValue $value -Force
        if ($key -eq 'Pattern') { $entry.Value | Add-Member -NotePropertyName pattern_explicit -NotePropertyValue ([bool]$value) -Force }
        $changed = $true
    }
    if ($changed) { _SaveConfig $config }
    $entry.Value | ConvertTo-Json -Depth 10
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
            $curlArgs = @("--socks5-hostname", "$($parsed.host):$($parsed.port)", "--connect-timeout", "10", "--max-time", "30", "-s", "-f")
            foreach ($k in $headers.Keys) {
                $curlArgs += "-H"; $curlArgs += "${k}: $($headers[$k])"
            }
            $curlArgs += $Url
            $out = & curl.exe @curlArgs 2>&1
            if ($LASTEXITCODE -ne 0) { throw "curl exited with code $LASTEXITCODE" }
            $result = ($out -join "`n") | ConvertFrom-Json
            return $result
        }
        $result = Invoke-RestMethod -Uri $Url -Headers $headers -Method Get -TimeoutSec 30
        return $result
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

function _ProjectRelease($Rel) {
    if ($null -eq $Rel) { return $null }
    $assets = @()
    if ($Rel.assets) {
        $assets = @(@($Rel.assets) | ForEach-Object {
            [PSCustomObject]@{
                name                 = $_.name
                size                 = $_.size
                browser_download_url = $_.browser_download_url
            }
        })
    }
    return [PSCustomObject]@{
        tag_name   = $Rel.tag_name
        name       = $Rel.name
        prerelease = [bool]$Rel.prerelease
        assets     = $assets
    }
}

function _GetCachePath($Repo, $Endpoint) {
    $safe = $Repo -replace '[^a-zA-Z0-9._-]', '_'
    $hash = [System.BitConverter]::ToString([System.Security.Cryptography.MD5]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($Endpoint))).Replace("-", "").Substring(0, 8)
    return Join-Path $CacheDir "$safe-$hash.json"
}

function _ReadCache($Repo, $Endpoint) {
    $path = _GetCachePath $Repo $Endpoint
    if (-not (Test-Path $path)) { return $null }
    try {
        $raw = Get-Content $path -Raw | ConvertFrom-Json
    }
    catch { return $null }
    if ((-not $raw) -or (-not $raw.cached_at) -or ($raw.endpoint -ne $Endpoint)) { return $null }
    $age = [DateTimeOffset]::UtcNow - ([DateTimeOffset]$raw.cached_at).ToUniversalTime()
    if ($age.TotalMinutes -gt $CacheTtlMinutes) {
        Remove-Item $path -Force -ErrorAction SilentlyContinue
        return $null
    }
    return $raw.data
}

function _WriteCache($Repo, $Endpoint, $Data) {
    New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
    $payload = [PSCustomObject]@{
        endpoint  = $Endpoint
        cached_at = (Get-Date).ToUniversalTime().ToString("o")
        data      = $Data
    }
    $payload | ConvertTo-Json -Depth 12 | Set-Content -Path (_GetCachePath $Repo $Endpoint) -Encoding UTF8
}

function _GetLatestRelease($Repo, $ProxyUrl, [switch]$Force) {
    $endpoint = "https://api.github.com/repos/$Repo/releases/latest"
    if (-not $Force) {
        $cached = _ReadCache $Repo $endpoint
        if ($null -ne $cached) { return $cached }
    }
    $result = _ProjectRelease (_InvokeGitHubApi $endpoint $ProxyUrl)
    _WriteCache $Repo $endpoint $result
    return $result
}

function _GetReleases($Repo, $Count = 40, $ProxyUrl, [switch]$Force) {
    if ($Count -gt 100) {
        $result = @()
        for ($page = 1; $result.Count -lt $Count; $page++) {
            $endpoint = "https://api.github.com/repos/$Repo/releases?per_page=100&page=$page"
            $batch = if (-not $Force) { _ReadCache $Repo $endpoint } else { $null }
            if ($null -eq $batch) {
                $batch = @(@(_InvokeGitHubApi $endpoint $ProxyUrl) | ForEach-Object { _ProjectRelease $_ })
                _WriteCache $Repo $endpoint $batch
            }
            $result += @($batch)
            if (@($batch).Count -lt 100) { break }
        }
        return @($result | Select-Object -First $Count)
    }
    $endpoint = "https://api.github.com/repos/$Repo/releases?per_page=$Count"
    if (-not $Force) {
        $cached = _ReadCache $Repo $endpoint
        if ($null -ne $cached) { return @($cached) }
    }
    $result = @(@(_InvokeGitHubApi $endpoint $ProxyUrl) | ForEach-Object { _ProjectRelease $_ })
    _WriteCache $Repo $endpoint $result
    return $result
}

# Some repos split releases per platform into separate tags. /releases/latest
# can point to a tag with no Windows installer. Track the newest release that
# actually ships our kind of installer instead.
function _GetTagFamily($Tag) {
    # Non-numeric skeleton of a tag - e.g. "auth-v4.4.25" -> "auth-v",
    # "v3.4.6" -> "v", "3.4.9-android" -> "-android".
    if (-not $Tag) { return $null }
    return ($Tag.Trim() -replace '[\d\.]', '')
}

function _GetReleaseChannel($Rel) {
    # Brave puts its channel before the version, followed by Chromium metadata.
    # Check this first so changing Chromium versions do not become release lines.
    if ($Rel -and $Rel.name -match '^(Release|Stable|Beta|Nightly|Dev|Canary)\s+v?\d') {
        return $Matches[1].ToLower()
    }
    # Some repos use a trailing parenthetical in the release NAME to mark
    # channels (e.g. "v2.34.0 (Stable)" vs "v2.35.4 (Dev)").
    if (-not $Rel -or -not $Rel.name) { return $null }
    if ($Rel.name -match '\(([^)]+)\)\s*$') {
        $marker = $Matches[1].Trim().ToLower()
        return $marker
    }
    return $null
}

function _GetReleaseKey($Rel) {
    # Family + optional channel - pins to a specific release line.
    $ch = _GetReleaseChannel $Rel
    if ($ch) { return "$(_GetTagFamily $Rel.tag_name) [$ch]" }
    return _GetTagFamily $Rel.tag_name
}

function _GetTrackedRelease($AppName, $App, $ProxyUrl, [switch]$Force) {
    $limit = if ($App.release_limit) { $App.release_limit } else { 40 }
    $releases = _GetReleases $App.repo $limit $ProxyUrl -Force:$Force
    $stable = @($releases | Where-Object { -not $_.prerelease -or $App.include_prerelease })
    $explicitLine = $App.tag_pattern -or $App.release_name_pattern
    if ($App.tag_pattern) { $stable = @($stable | Where-Object { $_.tag_name -like $App.tag_pattern }) }
    if ($App.release_name_pattern) { $stable = @($stable | Where-Object { $_.name -like $App.release_name_pattern }) }

    # An empty family is valid (numeric-only tags). For legacy entries without
    # a saved family, use the old asset to identify the release line, not to
    # select the update version: filenames commonly embed a version number.
    $hasFamily = $null -ne $App.PSObject.Properties['tag_family'] -and $null -ne $App.tag_family
    $family = $App.tag_family
    if (-not $hasFamily -and -not $explicitLine) {
        foreach ($rel in $stable) {
            $assets = @($rel.assets)
            $matchByName = $App.current_asset -and ($assets.name -contains $App.current_asset)
            $matchByPattern = $App.pattern -and (@($assets | Where-Object { $_.name -like $App.pattern }).Count -gt 0)
            if ($matchByName -or $matchByPattern) {
                $family = _GetReleaseKey $rel
                $hasFamily = $true
                break
            }
        }
    }

    if (-not $hasFamily -and -not $explicitLine) {
        $lines = @(_GetReleaseLines @($stable | Where-Object {
            @($_.assets | Where-Object { _TestIsInstallerAsset $_.name }).Count -gt 0
        }))
        if ($lines.Count -gt 1) { throw "Release line is ambiguous for $AppName. Use gitget configure $AppName -TagPattern <glob>." }
    }

    # Newest stable release in the tracked line that ships an installer.
    # Asset selection remains separate and can ask for a new installer type.
    foreach ($rel in $stable) {
        if (-not $explicitLine -and $hasFamily -and (_GetReleaseKey $rel) -ne $family) { continue }
        if (@($rel.assets | Where-Object { _TestIsInstallerAsset $_.name }).Count -gt 0) { return $rel }
    }

    throw "No Windows installer release found for the tracked release line of $($App.repo). Configure release filters or increase -ReleaseLimit with gitget configure $AppName."
}

function _GetReleaseLines($InstallableReleases) {
    # Group by tag family + channel, keeping each group's newest first.
    return @(@($InstallableReleases | ForEach-Object {
        [PSCustomObject]@{ rel = $_; key = _GetReleaseKey $_ }
    } | Group-Object key))
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
# Installed-version detection - probe the real install before trusting config
# --------------------------------------------------------------------------

function _NormalizeVersion($v) {
    if (-not $v) { return $v }
    $t = $v.Trim()
    # Drop prefixes ("auth-v4.4.25" -> "4.4.25") and "+build" metadata.
    $stripped = (($t -replace '^[^\d]+', '') -replace '\+.*$', '')
    return $(if ($stripped) { $stripped } else { $t })
}

function _TestSameVersion($a, $b) {
    # Extra leading segments have meaning; format overrides belong in config.
    $na = _NormalizeVersion $a
    $nb = _NormalizeVersion $b
    if ($na -eq $nb) { return $true }
    if (-not $na -or -not $nb) { return $false }

    $cmp = _CompareVersions $a $b
    return ($null -ne $cmp -and $cmp -eq 0)
}

function _CompareVersions($a, $b) {
    # Numeric compare: -1 (a older), 0 (equal), 1 (a newer), $null if not comparable.
    $na = _NormalizeVersion $a
    $nb = _NormalizeVersion $b
    if (-not $na -or -not $nb) { return $null }
    if ($na -eq $nb) { return 0 }
    if ($na -match '^\d{4}-\d{2}-\d{2}$' -or $nb -match '^\d{4}-\d{2}-\d{2}$') {
        $dateA = [datetime]::MinValue
        $dateB = [datetime]::MinValue
        $culture = [System.Globalization.CultureInfo]::InvariantCulture
        $style = [System.Globalization.DateTimeStyles]::None
        if ([datetime]::TryParseExact($na, 'yyyy-MM-dd', $culture, $style, [ref]$dateA) -and
            [datetime]::TryParseExact($nb, 'yyyy-MM-dd', $culture, $style, [ref]$dateB)) {
            return [Math]::Sign($dateA.CompareTo($dateB))
        }
        return $null
    }
    # Compare numeric versions and SemVer prereleases; do not discard arbitrary
    # text and accidentally equate different opaque release identifiers.
    $syntax = '^(\d+(?:\.\d+)*)(?:-([0-9A-Za-z.-]+))?$'
    $ma = [regex]::Match($na, $syntax)
    $mb = [regex]::Match($nb, $syntax)
    if (-not $ma.Success -or -not $mb.Success) { return $null }
    $numsA = @($ma.Groups[1].Value -split '\.')
    $numsB = @($mb.Groups[1].Value -split '\.')
    $n = [Math]::Max($numsA.Count, $numsB.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $va = if ($i -lt $numsA.Count) { [System.Numerics.BigInteger]::Parse($numsA[$i]) } else { 0 }
        $vb = if ($i -lt $numsB.Count) { [System.Numerics.BigInteger]::Parse($numsB[$i]) } else { 0 }
        if ($va -gt $vb) { return 1 }
        if ($va -lt $vb) { return -1 }
    }
    $sa = $ma.Groups[2].Value
    $sb = $mb.Groups[2].Value
    if ($sa -ceq $sb) { return 0 }
    if (-not $sa) { return 1 }
    if (-not $sb) { return -1 }
    $partsA = @($sa -split '\.')
    $partsB = @($sb -split '\.')
    for ($i = 0; $i -lt [Math]::Min($partsA.Count, $partsB.Count); $i++) {
        $aNumeric = $partsA[$i] -match '^\d+$'
        $bNumeric = $partsB[$i] -match '^\d+$'
        if ($aNumeric -and $bNumeric) {
            $cmp = [System.Numerics.BigInteger]::Parse($partsA[$i]).CompareTo([System.Numerics.BigInteger]::Parse($partsB[$i]))
        } elseif ($aNumeric -ne $bNumeric) { $cmp = if ($aNumeric) { -1 } else { 1 } }
        else { $cmp = [string]::CompareOrdinal($partsA[$i], $partsB[$i]) }
        if ($cmp -ne 0) { return [Math]::Sign($cmp) }
    }
    return [Math]::Sign($partsA.Count - $partsB.Count)
}

function _TestIsNewer($Candidate, $Current) {
    # True only when $Candidate is a strictly higher version than $Current; an app
    # that self-updated past GitHub (e.g. Mullvad Browser) is NOT an update target.
    $cmp = _CompareVersions $Candidate $Current
    if (-not $Current) { return $true }
    if ($null -eq $cmp) { throw "Cannot compare '$Current' with '$Candidate'. Configure version extraction with gitget configure." }
    return ($cmp -gt 0)
}

function _FindInstalledExe($App) {
    if ($App.version_exe -and [System.IO.Path]::IsPathRooted($App.version_exe)) {
        if (Test-Path -LiteralPath $App.version_exe) { return $App.version_exe }
    }
    if ($App.version_exe -and $App.install_dir) {
        $candidate = Join-Path $App.install_dir $App.version_exe
        if (Test-Path $candidate) { return $candidate }
    }
    if ($App.version_exe) { return $null }
    if ($App.install_dir -and (Test-Path $App.install_dir)) {
        # Never probe the app's own downloaded installer (or any installer-like
        # exe) for a version - launching one would pop up its setup UI.
        return (Get-ChildItem -Path $App.install_dir -Filter *.exe -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ne $App.current_asset -and -not (_TestIsInstallerLike $_.Name) } |
                Select-Object -First 1).FullName
    }
    return $null
}

function _InvokeWithTimeout($ExePath, $Arg, $TimeoutMs = 4000) {
    # Some exes hang instead of erroring; kill after the timeout.
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
    # Accept punctuation/spacing differences without matching unrelated
    # programs from the same publisher or sharing one word.
    $repoName  = ($App.repo -split '/')[1]
    if ($App.display_name) { return @($App.display_name) }
    if ($App.display_name_pattern) { return @('') }
    # Whole names only: a publisher or one word can identify unrelated apps.
    return @(@($AppName, $repoName) | Where-Object { $_ } | Select-Object -Unique)
}

function _TestDisplayNameMatch($DisplayName, $Needle) {
    # Exact match wins; otherwise the needle must be delimited by
    # non-alphanumerics. Plain substring matching was too loose.
    if (-not $DisplayName) { return $false }
    if ($DisplayName -eq $Needle) { return $true }
    $characters = @($Needle.ToCharArray() | Where-Object { "$_" -match '[a-zA-Z0-9]' } | ForEach-Object { [regex]::Escape("$_") })
    if (-not $characters.Count) { return $false }
    $pattern = $characters -join '[^a-z0-9]*'
    return ($DisplayName -match "(?i)(^|[^a-z0-9])$pattern([^a-z0-9]|$)")
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
    if ($App.display_name -or $App.display_name_pattern) {
        $exact = @($entries | Where-Object {
            $_.DisplayVersion -and (($App.display_name -and $_.DisplayName -eq $App.display_name) -or
            ($App.display_name_pattern -and $_.DisplayName -like $App.display_name_pattern))
        })
        if (@($exact.DisplayName | Select-Object -Unique).Count -gt 1) { throw 'Configured display-name pattern matches multiple installed apps. Narrow it or configure VersionExe.' }
        $versions = @($exact.DisplayVersion | Select-Object -Unique)
        if ($versions.Count -gt 1) { throw "Multiple installed versions match '$($App.display_name)'. Configure VersionExe." }
        if ($versions.Count -eq 1) { return $versions[0] }
        return $null
    }
    foreach ($n in $needles) {
        $exact = @($entries | Where-Object { $_.DisplayName -eq $n -and $_.DisplayVersion })
        if ($exact.Count -gt 0) {
            $versions = @($exact.DisplayVersion | Select-Object -Unique)
            if ($versions.Count -ne 1) { throw "Multiple installed versions match '$n'. Configure DisplayName or VersionExe." }
            return $versions[0]
        }

        $hit = @($entries | Where-Object { $_.DisplayVersion -and (_TestDisplayNameMatch $_.DisplayName $n) })
        if ($hit.Count -gt 1) { throw "Multiple installed apps match '$n'. Configure DisplayName or VersionExe." }
        if ($hit.Count -eq 1) { return $hit[0].DisplayVersion }
    }
    return $null
}

function _GetVersionFromWinget($App, $AppName) {
    $wingetExe = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $wingetExe) { return $null }

    $needles = _GetVersionSearchNeedles $App $AppName
    foreach ($n in $needles) {
        try {
            $wingetArgs = @('list', '--accept-source-agreements')
            if ($n) { $wingetArgs += @('--name', $n) }
            $argumentString = ($wingetArgs | ForEach-Object { '"' + $_.Replace('"', '\"') + '"' }) -join ' '
            $output = _InvokeWithTimeout $wingetExe.Source $argumentString 8000
            $lines = @($output -split '\r?\n' | Where-Object { $_ -and $_.Trim() -ne "" })
        }
        catch { continue }
        if (-not $lines) { continue }

        # Find the Version column in winget's fixed-width table.
        $headerIdx = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^Name\s+Id\s+Version') { $headerIdx = $i; break }
        }
        if ($headerIdx -lt 0) { continue }

        $header     = $lines[$headerIdx]
        $versionCol = $header.IndexOf("Version")
        $availCol   = $header.IndexOf("Available")
        $sourceCol  = $header.IndexOf("Source")
        if ($versionCol -lt 0) { continue }

        $hits = @()
        $idCol = $header.IndexOf("Id")
        for ($i = $headerIdx + 1; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            if ($line -match '^-+$' -or $line.Length -le $versionCol) { continue }
            $endCol = if ($availCol -gt $versionCol) { $availCol } else { $line.Length }
            if ($sourceCol -gt $versionCol) { $endCol = [Math]::Min($endCol, $sourceCol) }
            $name = $line.Substring(0, $idCol).Trim()
            $ver = $line.Substring($versionCol, [Math]::Min($endCol, $line.Length) - $versionCol).Trim()
            if ($App.display_name) { $matchesName = $name -eq $App.display_name }
            elseif ($App.display_name_pattern) { $matchesName = $name -like $App.display_name_pattern }
            else { $matchesName = _TestDisplayNameMatch $name $n }
            if ($ver -and $matchesName) { $hits += $ver }
        }
        if ($hits.Count -gt 1) { throw "Multiple winget apps match '$n'. Configure DisplayName or VersionExe." }
        if ($hits.Count -eq 1) { return $hits[0] }
    }
    return $null
}

function _GetInstalledVersion($AppName, $App) {
    # Try progressively less-direct sources; "recorded" only trusts the config.
    $exePath = _FindInstalledExe $App
    if ($App.version_exe -and -not $exePath) { throw "Configured version executable not found: $($App.version_exe)" }

    if ($App.version_command) {
        $v = _GetVersionFromCommand $exePath @($App.version_command) $App.version_regex
        if ($v) { return @{ version = $v; source = "version command" } }
        throw "Configured version command did not return a version. Check VersionExe, VersionCommand and VersionRegex."
    }

    if ($exePath) {
        # Metadata does not launch a GUI or installer. Run commands only when
        # explicitly configured, since unknown executables can ignore flags.
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

    Write-Host "Some .exe assets are plain portable binaries, not installers - pick the actual" -ForegroundColor Yellow
    Write-Host "installer (often named like '*-setup.exe' or '*-installer.exe', or a .msi/.msix)." -ForegroundColor Yellow

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
        # Interactive pickers only offer installer extensions; automatic
        # matching below reuses the already-stored pattern.
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

        # Always show the full installer list when there's more than one -
        # arch scoring is just a guess and can be wrong.
        if ($installers.Count -gt 1 -or ($GlobPattern -and -not $matched)) {
            $recommendedName = if ($final.Count -gt 0) { $final[0].name } else { $null }
            return _SelectAssetFromList $installers $recommendedName
        }
        return $installers[0]
    }

    # A check must not silently select an unrelated asset on a pattern miss.
    $candidates = @($Assets | Where-Object { _TestIsInstallerAsset $_.name })
    if (-not $candidates.Count) { return $null }
    if ($GlobPattern) {
        $matched = @($candidates | Where-Object { $_.name -like $GlobPattern })
        if (-not $matched) { return $null }
        $candidates = $matched
    }

    $arch   = _GetNativeArch
    $scored = @($candidates |
        ForEach-Object { [PSCustomObject]@{ asset = $_; score = _GetArchScore $_.name $arch } } |
        Sort-Object @{Expression = "score"; Descending = $true }, @{Expression = { $_.asset.name }; Descending = $false })
    $topScore = $scored[0].score
    if ($topScore -eq 0) { return $null }
    $final = @($scored | Where-Object { $_.score -eq $topScore } | ForEach-Object { $_.asset })
    if ($final.Count -eq 1) { return $final[0] }
    return $null
}

function _SaveAsset($Asset, $DestDir, $ProxyUrl) {
    New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
    $destPath = Join-Path $DestDir $Asset.name
    $sizeMb = [math]::Round($Asset.size / 1MB, 1)
    Write-Host "Downloading $($Asset.name) ($sizeMb MB)..."

    if (_TestIsSocks5 $ProxyUrl) {
        $parsed = _ParseSocks5Url $ProxyUrl
        & curl.exe --socks5-hostname "$($parsed.host):$($parsed.port)" --connect-timeout 10 --max-time 300 -L -f -o $destPath $Asset.browser_download_url
        if ($LASTEXITCODE -ne 0) {
            throw "curl download failed (exit code $LASTEXITCODE)"
        }
    }
    else {
        Invoke-WebRequest -Uri $Asset.browser_download_url -OutFile $destPath -UseBasicParsing -TimeoutSec 300
    }
    return $destPath
}

function _NewAssetPattern($FileName) {
    # Turn a concrete asset name into a reusable glob by dropping version
    # tokens: bat-v0.26.1-x86_64-pc-windows-msvc.zip -> *x86_64*pc*windows*msvc.zip
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
                if ($proc.ExitCode -in @(0, 1641, 3010)) {
                    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
                    Write-Host "Install finished; deleted $leaf" -ForegroundColor Green
                    return $true
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
                    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
                    Write-Host "Installer finished; deleted $leaf" -ForegroundColor Green
                    return $true
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
                Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
                Write-Host "Install finished; deleted $leaf" -ForegroundColor Green
                return $true
            }
            catch {
                Write-Host "Add-AppxPackage failed ($($_.Exception.Message)); file kept at $Path" -ForegroundColor Red
                Write-Host "(this usually means the package's signing certificate isn't trusted yet)" -ForegroundColor Yellow
            }
        }
        default {
            # Safety net - _SelectAsset only returns installer extensions.
            Write-Host "Unrecognized installer type ($ext); kept for manual install at $Path" -ForegroundColor Yellow
        }
    }
    return $false
}

# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------

function _ConvertToRepoSlug($Raw) {
    # Accepts 'owner/repo', a github.com URL, or git@github.com:owner/repo.git.
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

    $releases = _GetReleases $repo $ReleaseLimit $proxyUrl
    $installable = @(@($releases | Where-Object { -not $_.prerelease -or $IncludePrerelease }) |
        Where-Object { @($_.assets | Where-Object { _TestIsInstallerAsset $_.name }).Count -gt 0 })
    if ($TagPattern) { $installable = @($installable | Where-Object { $_.tag_name -like $TagPattern }) }
    if ($ReleaseNamePattern) { $installable = @($installable | Where-Object { $_.name -like $ReleaseNamePattern }) }
    $release = $null
    if ($installable.Count -gt 0) {
        $byFamily = @(_GetReleaseLines $installable)
        if ($byFamily.Count -gt 1) {
            $release = _SelectReleaseLine $byFamily
        } else {
            $release = $installable[0]
        }
    }
    if (-not $release) { Write-Host "No installer release matches the requested filters." -ForegroundColor Yellow; return }
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
        tag_family       = _GetReleaseKey $release
        pattern          = if ($Pattern) { $Pattern } else { _NewAssetPattern $asset.name }
        install_dir      = $installDir
        current_version  = if ($CurrentVersion) { $CurrentVersion } else { $null }
        current_asset    = $asset.name
        last_checked     = (Get-Date).ToUniversalTime().ToString("o")
        version_exe      = if ($VersionExe) { $VersionExe } else { $null }
        version_command  = if ($VersionCommand) { $VersionCommand } else { $null }
        version_regex    = if ($VersionRegex) { $VersionRegex } else { $null }
        tag_pattern      = $TagPattern
        release_name_pattern = $ReleaseNamePattern
        release_version_regex = $ReleaseVersionRegex
        installed_version_regex = $InstalledVersionRegex
        display_name = $DisplayName
        display_name_pattern = $DisplayNamePattern
        include_prerelease = [bool]$IncludePrerelease
        pattern_explicit = [bool]$Pattern
        release_limit = $ReleaseLimit
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
        $ver = if ($detected.source -eq 'recorded (unverified)') { $detected.version }
               else { _ExtractConfiguredVersion $detected.version $prop.Value.installed_version_regex }
        if (-not $ver) { $ver = '-' }
        Write-Host ("{0,-$maxLen}  {1}" -f $prop.Name, $ver)
    }
}

function _CheckOne($appName, $app, $ProxyUrl, [switch]$Force) {
    try {
        $release = _GetTrackedRelease $appName $app $ProxyUrl -Force:$Force
        $latestVersion = _ExtractConfiguredVersion $release.tag_name $app.release_version_regex
        $detected = _GetInstalledVersion $appName $app
        $verified = $detected.source -notin @('recorded (unverified)', 'unknown')
        $current = $app.current_version
        if ($verified -and $detected.version) {
            $current = _ExtractConfiguredVersion $detected.version $app.installed_version_regex
        }
        $hasUpdate = _TestIsNewer $latestVersion $current
        $configChanged = $verified -and $current -and -not (_TestSameVersion $current $app.current_version)
        if ($configChanged) { $app.current_version = $current }
        $asset = _SelectAsset $release.assets $app.pattern
        if ($hasUpdate) { Write-Host $appName -ForegroundColor Yellow }
        return [PSCustomObject]@{
            release = $release; asset = $asset; hasUpdate = $hasUpdate
            configChanged = [bool]$configChanged; verified = $verified
        }
    }
    catch {
        Write-Host "$appName error: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
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
    $errorCount = 0
    $unverifiedCount = 0
    $configChanged = $false
    foreach ($prop in $targets) {
        $result = _CheckOne $prop.Name $prop.Value $proxyUrl -Force:$Force
        if ($null -eq $result) { $errorCount++; continue }
        if ($result.hasUpdate) { $updateCount++ }
        if (-not $result.verified) { $unverifiedCount++ }
        if ($result.configChanged) { $configChanged = $true }
    }
    if ($configChanged) { _SaveConfig $config }

    if ($errorCount -gt 0 -and $updateCount -eq 0) {
        Write-Host "$errorCount check(s) failed, results inconclusive" -ForegroundColor Red
    }
    elseif ($updateCount -eq 0 -and $unverifiedCount -gt 0) {
        Write-Host "No newer tracked releases found; $unverifiedCount installed version(s) could not be verified." -ForegroundColor Yellow
    }
    elseif ($updateCount -eq 0) {
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

    if ($Target -and -not (_GetAppEntry $config $Target)) {
        Write-Host "'$Target' is not tracked." -ForegroundColor Yellow; return
    }
    $targets = if ($Target) { $entries | Where-Object { $_.Name -eq $Target } } else { $entries }

    $proxyUrl = _ResolveProxy
    $updatable = [System.Collections.Generic.List[PSCustomObject]]::new()
    $errorCount = 0
    $unverifiedCount = 0
    foreach ($prop in $targets) {
        $appName = $prop.Name
        $app = $prop.Value

        $result = _CheckOne $appName $app $proxyUrl -Force:$Force
        if ($null -eq $result) {
            $errorCount++
            continue
        }
        if ($result.configChanged) { _SaveConfig $config }
        if (-not $result.verified) { $unverifiedCount++ }
        $release = $result.release
        $latestVersion = _ExtractConfiguredVersion $release.tag_name $app.release_version_regex
        if (-not $result.hasUpdate) { continue }

        $updatable.Add([PSCustomObject]@{
            appName = $appName
            app     = $app
            release = $release
            latest  = $latestVersion
        })
    }

    if ($errorCount -gt 0 -and $updatable.Count -eq 0) {
        Write-Host "$errorCount check(s) failed, update aborted" -ForegroundColor Red
        return
    }
    if ($updatable.Count -eq 0) {
        if ($unverifiedCount -gt 0) { Write-Host "No newer tracked releases found; $unverifiedCount installed version(s) could not be verified." -ForegroundColor Yellow }
        else { Write-Host "Up to date" -ForegroundColor Green }
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
        $newTypeNeeded = $false
        if ($app.current_asset) {
            $asset = @($release.assets | Where-Object { $_.name -eq $app.current_asset -and (_TestIsInstallerAsset $_.name) }) | Select-Object -First 1
            if (-not $asset) {
                $newTypeNeeded = $true
                Write-Host "$appName new type needed:" -ForegroundColor Yellow
            }
        }
        if (-not $asset) {
            $asset = _SelectAsset $release.assets $app.pattern -Interactive
        }
        if (-not $asset) {
            if ($newTypeNeeded) {
                # No Windows installer in this release - don't bump the
                # recorded version; it'll come up again once one lands.
                Write-Host "$appName $latestVersion ($($release.name)) has no Windows installer - skipping." -ForegroundColor Yellow
            }
            continue
        }

        try { $path = _SaveAsset $asset $app.install_dir $proxyUrl }
        catch { Write-Host "$appName download failed: $($_.Exception.Message)" -ForegroundColor Red; continue }
        if ($app.current_asset -and $app.current_asset -ne $asset.name) {
            $stalePath = Join-Path $app.install_dir $app.current_asset
            if (Test-Path $stalePath) {
                Remove-Item $stalePath -Force -ErrorAction SilentlyContinue
                Write-Host "Removed old installer: $($app.current_asset)" -ForegroundColor Gray
            }
        }
        if (-not (_InstallDownloadedAsset $path)) { continue }
        $keepPattern = $app.pattern_explicit -or
            ($null -eq $app.PSObject.Properties['pattern_explicit'] -and $app.pattern -and
             $app.pattern -ne (_NewAssetPattern $app.current_asset))
        $app.current_version = $latestVersion
        $app.current_asset = $asset.name
        if (-not $keepPattern) { $app.pattern = _NewAssetPattern $asset.name }
        $app.last_checked = (Get-Date).ToUniversalTime().ToString("o")
        _SaveConfig $config
    }
}

function _Proxy {
    $config = _GetConfig

    if (-not $Target -or $Target.Trim() -eq "") {
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
        # Bare host:port - prepend socks5://
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
    "configure" { _Configure }
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
        Write-Host "  configure   - Show/set an app's release, installer and version rules"
        Write-Host "  ls          - List tracked apps"
        Write-Host "  rm          - Remove tracked apps (fzf picker)"
        Write-Host "  check       - Check for updates (-Force skips cache)"
        Write-Host "  update      - Download and install available updates (fzf picker, name to limit, -All to skip, -Force to skip cache)"
        Write-Host "  backup      - Backup config to Documents\windows-config-backup\gitget"
        Write-Host "  restore     - Restore config from a file path"
        Write-Host "  proxy       - Set/show/clear SOCKS5 proxy (gitget proxy host:port)"
        Write-Host ""
    }
}
