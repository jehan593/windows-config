<#
.SYNOPSIS
    GitGet — track GitHub repos and install their Windows releases.

.DESCRIPTION
    Tracks GitHub repos and installs their Windows releases. Three kinds of
    payload are supported:
      installer - .exe/.msi/.msix/.msixbundle, executed like before.
      portable  - a bare .exe, copied into a managed bin directory.
      archive   - .zip/.tar.gz/.7z, unpacked into a managed bin directory.
    "gitget add" installs the payload unless the program is already on the
    machine (-NoInstall tracks it only). Adding an app that is already tracked
    installs it again when it is missing from the machine. Portable payloads get
    a recorded install state (version + sha256) so the installed version can be
    verified on later checks. Pure PowerShell, no extra dependencies (7-Zip is
    only needed for .7z assets).

.EXAMPLE
    gitget add sharkdp/bat
    gitget add alacritty/alacritty -Pattern "*x64*.msi"
    gitget add sharkdp/bat -CurrentVersion v0.24.0
    gitget add yt-dlp/yt-dlp -InstallType portable
    gitget check
    gitget update
    gitget ls
    gitget proxy 127.0.0.1:1080
    gitget proxy clear

.NOTES
    Config: $env:LOCALAPPDATA\windows-config-files\gitget\config.json
    Portable payloads: %LOCALAPPDATA%\windows-config-files\gitget\apps\<name>
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

    [ValidateSet('installer', 'portable', 'archive')]
    [string]$InstallType,       # how the payload is installed (for 'add'/'configure')

    [string]$BinDir,            # persistent install dir for portable/archive payloads (for 'add')

    [switch]$Purge,             # for 'rm': also delete the files of an installer payload (portable/archive payloads are always deleted)

    [switch]$All,               # for 'update': update all without fzf picker; for 'rm': remove every tracked app

    [switch]$Force,             # for 'check'/'update': ignore cache, always hit the API

    [switch]$Reinstall,         # for 'update'/'install'/'add': reinstall even when the installed copy cannot be verified

    [switch]$NoInstall          # for 'add': only track the app, do not install it
)

$ErrorActionPreference = "Stop"

$requiredCommands = @()
# fzf is only needed where a picker is actually shown.
$usesPicker = ($Command -in @('add', 'update')) -or ($Command -eq 'rm' -and -not $All -and -not $Target)
if ($usesPicker) { $requiredCommands += 'fzf' }
$missingDeps = @($requiredCommands | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
if ($Proxy -or $Command -eq "proxy") {
    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
        $missingDeps += "curl.exe"
    }
}
if ($missingDeps.Count -gt 0)
{
    Write-Host "Missing: $($missingDeps -join ', ')" -ForegroundColor Red
    Write-Host "Stopped." -ForegroundColor Red
    return
}

$AppDir         = Join-Path $env:LOCALAPPDATA "windows-config-files\gitget"
$ConfFilePath   = Join-Path $AppDir "config.json"
$DownloadsDir   = Join-Path $AppDir "downloads"
$AppsDir        = Join-Path $AppDir "apps"
# One shared bin dir all portable/archive programs live in. It is registered on
# the user PATH once (in front), so installs/updates/removals never rewrite it.
$SharedBinDir   = Join-Path $AppDir "bin"
$CacheDir        = Join-Path $AppDir "cache"
$CacheTtlMinutes = if ($env:GITGET_CACHE_TTL_MINUTES) { [int]$env:GITGET_CACHE_TTL_MINUTES } else { 10 }
$script:staleCacheWarned = $false

# Installers are executed; portable payloads are copied or unpacked into a
# managed directory and never run. The classifiers below are self-contained on
# purpose - the offline test suite loads function definitions only.
function _TestIsInstallerAsset($AssetName) {
    $ext = [System.IO.Path]::GetExtension($AssetName).ToLower()
    return @(".exe", ".msi", ".msix", ".msixbundle") -contains $ext
}

function _TestIsInstallerLike($FileName) {
    if (-not $FileName) { return $false }
    return $FileName -match '(?i)setup|installer|install|update|updater|stub'
}

function _TestLooksLikeInstaller($AssetName) {
    # Hint that an asset is an installer rather than a program: msi/msix
    # packages, installer-ish names, and "<app><version>-<arch>.exe"
    # (e.g. 7z2604-x64.exe) which are self-extracting installers. The
    # architecture token is removed first so "yt-dlp_x86.exe" stays a program.
    if (-not $AssetName) { return $false }
    $name = $AssetName.ToLower()
    $ext  = [System.IO.Path]::GetExtension($name)
    if ($ext -in @(".msi", ".msix", ".msixbundle")) { return $true }
    if (_TestIsInstallerLike $AssetName) { return $true }
    if ($ext -ne ".exe") { return $false }
    $withoutArch = $name -replace '(x86_64|x64|amd64|x86|win64|win32|32bit|aarch64|arm64)', ''
    if ($withoutArch -eq $name) { return $false }
    return ($withoutArch -match '\d{2,}')
}

function _TestIsArchiveAsset($AssetName) {
    if (-not $AssetName) { return $false }
    $name = $AssetName.ToLower()
    foreach ($compound in @(".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst")) {
        if ($name.EndsWith($compound)) { return $true }
    }
    $ext = [System.IO.Path]::GetExtension($name)
    return @(".zip", ".7z", ".rar", ".tar", ".gz", ".tgz", ".bz2", ".xz") -contains $ext
}

function _TestIsPortableAsset($AssetName) {
    # A bare Windows program: an .exe that does not look like an installer.
    if (-not $AssetName) { return $false }
    if ([System.IO.Path]::GetExtension($AssetName).ToLower() -ne ".exe") { return $false }
    return -not (_TestLooksLikeInstaller $AssetName)
}

function _TestIsSourceAsset($AssetName) {
    # Source archives and checksum files are never install payloads.
    if (-not $AssetName) { return $false }
    $name = $AssetName.ToLower()
    if ($name -match '(^|[._-])(source|src|sources)([._-]|$)') { return $true }
    return $name -match '(sha256|checksum|manifest|\.asc$|\.sig$|\.sbom$|\.json$|\.txt$|\.md$)'
}

function _TestIsWindowsAsset($AssetName) {
    # A release usually ships one build per platform (topgrade ships ten).
    # Only the Windows one can be installed, so the others are filtered out.
    if (-not $AssetName) { return $false }
    $name = $AssetName.ToLower()
    $ext  = [System.IO.Path]::GetExtension($name)
    if ($ext -in @(".exe", ".msi", ".msix", ".msixbundle")) { return $true }
    # Target triples of the other platforms.
    if ($name -match 'linux|darwin|macos|macosx|apple|freebsd|openbsd|netbsd|dragonfly|solaris|illumos|android|wasm|musl|mus1|alpine|centos|ubuntu|debian|fedora|suse|cygwin') { return $false }
    # Windows markers.
    if ($name -match 'windows|win32|win64|mingw|msvc|(^|[._-])win[0-9]*([._-]|$)') { return $true }
    # No platform in the name - it is a Windows build.
    return $true
}

function _TestIsAnyPayloadAsset($AssetName) {
    # Any payload gitget could install, whatever kind it is.
    if (_TestIsInstallerAsset $AssetName) { return $true }
    if ((_TestIsArchiveAsset $AssetName) -and (_TestIsWindowsAsset $AssetName) -and -not (_TestIsSourceAsset $AssetName)) { return $true }
    return $false
}

function _GetInstallType($App) {
    # Entries without install_type predate portable support - they install.
    if ($App -and $App.PSObject.Properties['install_type'] -and $App.install_type) { return $App.install_type }
    return 'installer'
}

function _TestIsInstallableAsset($AssetName, $InstallType) {
    switch ($InstallType) {
        'portable' { return (_TestIsPortableAsset $AssetName) }
        'archive'  { return ((_TestIsArchiveAsset $AssetName) -and (_TestIsWindowsAsset $AssetName)) }
        default    { return (_TestIsInstallerAsset $AssetName) }
    }
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
        ReleaseLimit='release_limit'; InstallType='install_type'; BinDir='bin_dir'
    }
    $previousType = _GetInstallType $entry.Value
    $previousBinDir = $entry.Value.bin_dir
    $changed = $false
    foreach ($key in $settings.Keys) {
        if (-not $script:PSBoundParameters.ContainsKey($key)) { continue }
        $value = $script:PSBoundParameters[$key]
        if ($key -like '*Regex' -and $value) { $null = [regex]::new($value) }
        $entry.Value | Add-Member -NotePropertyName $settings[$key] -NotePropertyValue $value -Force
        if ($key -eq 'Pattern') { $entry.Value | Add-Member -NotePropertyName pattern_explicit -NotePropertyValue ([bool]$value) -Force }
        $changed = $true
    }
    if ($changed -and $script:PSBoundParameters.ContainsKey('InstallType') -and $previousType -ne $entry.Value.install_type) {
        # The payload kind changed - any recorded state describes the old kind.
        if ($entry.Value.PSObject.Properties['installed']) { $entry.Value.installed = $null }
    }
    if ($changed -and $script:PSBoundParameters.ContainsKey('BinDir') -and $previousBinDir -and
        $previousBinDir -ine $entry.Value.bin_dir -and $previousType -ne 'installer') {
        if ($previousBinDir.TrimEnd('\') -ieq $SharedBinDir.TrimEnd('\')) {
            # Moving would take the whole shared dir - other installs live there.
            $entry.Value | Add-Member -NotePropertyName bin_dir -NotePropertyValue $previousBinDir -Force
            Write-Host "'$Target' shares the gitget bin dir - to move it, run 'gitget rm $Target' and re-add with -BinDir." -ForegroundColor Yellow
        }
        else {
        # The payload dir changed - move what is there, or the config would
        # point at a place that holds nothing.
        $oldRegistered = if ($entry.Value.installed -and $entry.Value.installed.path) { Split-Path -Parent $entry.Value.installed.path } else { $previousBinDir }
        if (Test-Path $previousBinDir) {
            if (Test-Path $entry.Value.bin_dir) {
                Write-Host "'$Target' already has a payload at $($entry.Value.bin_dir) - nothing moved." -ForegroundColor Yellow
            }
            else {
                try {
                    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $entry.Value.bin_dir) -Force
                    Move-Item -LiteralPath $previousBinDir -Destination $entry.Value.bin_dir -ErrorAction Stop
                    Write-Host "Moved payload to $($entry.Value.bin_dir)" -ForegroundColor Green
                    if ($entry.Value.installed -and $entry.Value.installed.path) {
                        $entry.Value.installed.path = Join-Path $entry.Value.bin_dir (Split-Path -Leaf $entry.Value.installed.path)
                    }
                }
                catch {
                    Write-Host "Failed to move the payload to $($entry.Value.bin_dir): $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        }
        # The PATH entry follows the program, not the config.
        $newRegistered = if ($entry.Value.installed -and $entry.Value.installed.path) { Split-Path -Parent $entry.Value.installed.path } else { $entry.Value.bin_dir }
        _UnregisterBinDir $oldRegistered
        if ($newRegistered) { _RegisterBinDir $newRegistered }
        }
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

function _ReadCache($Repo, $Endpoint, [switch]$AllowStale) {
    $path = _GetCachePath $Repo $Endpoint
    if (-not (Test-Path $path)) { return $null }
    try {
        $raw = Get-Content $path -Raw | ConvertFrom-Json
    }
    catch { return $null }
    if ((-not $raw) -or (-not $raw.cached_at) -or ($raw.endpoint -ne $Endpoint)) { return $null }
    try {
        $age = [DateTimeOffset]::UtcNow - ([DateTimeOffset]$raw.cached_at).ToUniversalTime()
    }
    catch { return $null }
    # The old file is kept until a refresh worked - deleting it up front
    # leaves nothing when the API cannot be reached.
    if ($age.TotalMinutes -gt $CacheTtlMinutes -and -not $AllowStale) { return $null }
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

function _GetReleases($Repo, $Count = 40, $ProxyUrl, [switch]$Force) {
    if ($Count -gt 100) {
        $result = @()
        for ($page = 1; $result.Count -lt $Count; $page++) {
            $endpoint = "https://api.github.com/repos/$Repo/releases?per_page=100&page=$page"
            $batch = if (-not $Force) { _ReadCache $Repo $endpoint } else { $null }
            if ($null -eq $batch) {
                $fetched = _FetchReleases $endpoint $ProxyUrl $Repo $endpoint
                if (-not $fetched.stale) { _WriteCache $Repo $endpoint $fetched.data }
                $batch = @($fetched.data)
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
    $fetched = _FetchReleases $endpoint $ProxyUrl $Repo $endpoint
    if (-not $fetched.stale) { _WriteCache $Repo $endpoint $fetched.data }
    return @($fetched.data)
}

function _FetchReleases($Endpoint, $ProxyUrl, $Repo, $CacheEndpoint) {
    # Fetches a release list. When the API cannot be reached, the data that is
    # already cached is better than nothing.
    try {
        $data = @(@(_InvokeGitHubApi $Endpoint $ProxyUrl) | ForEach-Object { _ProjectRelease $_ })
        return [PSCustomObject]@{ data = $data; stale = $false }
    }
    catch {
        $stale = _ReadCache $Repo $CacheEndpoint -AllowStale
        if ($null -eq $stale) { throw }
        if (-not $script:staleCacheWarned) {
            $script:staleCacheWarned = $true
            Write-Host "GitHub API unavailable - using cached release data" -ForegroundColor Yellow
        }
        return [PSCustomObject]@{ data = @($stale); stale = $true }
    }
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
    $type = _GetInstallType $App
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
            @($_.assets | Where-Object { _TestIsInstallableAsset $_.name $type }).Count -gt 0
        }))
        if ($lines.Count -gt 1) { throw "Release line is ambiguous for $AppName. Use gitget configure $AppName -TagPattern <glob>." }
    }

    # Newest stable release in the tracked line that ships a payload we can
    # install. The kind of that payload is decided when the asset is picked,
    # so a release that ships another kind is still the release to track.
    foreach ($rel in $stable) {
        if (-not $explicitLine -and $hasFamily -and (_GetReleaseKey $rel) -ne $family) { continue }
        if (@($rel.assets | Where-Object { _TestIsAnyPayloadAsset $_.name }).Count -gt 0) { return $rel }
    }

    throw "No installable release found for the tracked release line of $($App.repo). Configure release filters or increase -ReleaseLimit with gitget configure $AppName."
}

function _GetReleaseLines($InstallableReleases) {
    # Group by tag family + channel, keeping each group's newest first.
    return @(@($InstallableReleases | ForEach-Object {
        [PSCustomObject]@{ rel = $_; key = _GetReleaseKey $_ }
    } | Group-Object key))
}

function _SelectReleaseLine($FamilyGroups) {
    Write-Host "Several release lines - pick one:"
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
    if ($App.version_exe -and $App.bin_dir) {
        $candidate = Join-Path $App.bin_dir $App.version_exe
        if (Test-Path $candidate) { return $candidate }
    }
    if ($App.version_exe) { return $null }
    # Portable payloads live in their own bin directory, installers in the
    # download staging directory.
    foreach ($dir in @($App.bin_dir, $App.install_dir)) {
        if (-not $dir -or -not (Test-Path $dir)) { continue }
        # Never probe the app's own downloaded installer (or any installer-like
        # exe) for a version - launching one would pop up its setup UI.
        $found = (Get-ChildItem -Path $dir -Filter *.exe -Recurse -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -ne $App.current_asset -and -not (_TestLooksLikeInstaller $_.Name) } |
                  Select-Object -First 1).FullName
        if ($found) { return $found }
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

function _GetInstalledVersionPortable($AppName, $App) {
    # Portable payloads have no installer, no uninstall entry and usually no
    # version metadata - so the state we recorded is the primary source and
    # the program's own answer is the fallback for copies we did not install.
    $state = $null
    if ($App.PSObject.Properties['installed'] -and $App.installed) { $state = $App.installed }
    $statePath = if ($state -and $state.path) { $state.path } else { $null }

    $exePath = $statePath
    if (-not $exePath) { $exePath = _FindInstalledExe $App }

    if ($state -and $state.version) {
        if (-not $statePath -or -not [System.IO.File]::Exists($statePath)) {
            return @{ version = $null; source = "missing" }
        }
        $hash = _GetFileSha256 $statePath
        if ($hash -and $state.sha256 -and $hash -eq $state.sha256) {
            return @{ version = $state.version; source = "state" }
        }
    }

    # The payload changed on disk (self-update or manual replacement): ask the
    # program itself.
    if ($App.version_command) {
        if (-not $exePath) { throw "Configured version executable not found: $($App.version_exe)" }
        $v = _GetVersionFromCommand $exePath @($App.version_command) $App.version_regex
        if ($v) { return @{ version = $v; source = "version command" } }
        throw "Configured version command did not return a version. Check VersionExe, VersionCommand and VersionRegex."
    }
    if ($exePath) {
        $v = _GetVersionFromFileMetadata $exePath
        if ($v) { return @{ version = $v; source = "file metadata" } }
    }
    if ($state -and $state.version) {
        # Changed and unreadable: we cannot prove what is installed, and
        # overwriting a possibly newer build would be a downgrade.
        return @{ version = $null; source = "modified" }
    }
    if ($App.current_version) { return @{ version = $App.current_version; source = "recorded (unverified)" } }
    return @{ version = $null; source = "unknown" }
}

function _GetInstalledVersion($AppName, $App) {
    if ((_GetInstallType $App) -ne 'installer') { return _GetInstalledVersionPortable $AppName $App }
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

function _GetInstalledState($AppName, $App) {
    # Whether the app is on the machine. A copy that changed outside gitget
    # still counts as installed - we just cannot verify its version.
    # Throws when the installed version cannot be determined at all.
    $detected = _GetInstalledVersion $AppName $App
    if (-not $detected) { return @{ installed = $false; version = $null } }
    $present = $detected.source -notin @('recorded (unverified)', 'unknown', 'missing')
    $installed = $present -and ($detected.version -or $detected.source -eq 'modified')
    return @{ installed = $installed; version = $detected.version }
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

function _SelectAssetFromList($Candidates, $RecommendedName, [string]$Prompt = 'installer') {
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

    if ($Prompt -eq 'installer') {
        Write-Host "Pick the installer (not a portable .exe):" -ForegroundColor Yellow
    }
    elseif ($Prompt -eq 'archive') {
        Write-Host "Pick the archive with the Windows program:" -ForegroundColor Yellow
    }

    $picked = @($names | fzf --prompt="$Prompt> " --no-sort)[0]
    if ($LASTEXITCODE -eq 0 -and $picked) {
        return $ordered[[array]::IndexOf($names, $picked)]
    }
    return $null
}

function _SelectAsset($Assets, $GlobPattern, [switch]$Interactive, [string]$InstallType = 'installer', [string]$PreviousName = '') {
    if (-not $Assets -or @($Assets).Count -eq 0) { return $null }

    if ($Interactive) {
        # Interactive pickers only offer payload types we can install;
        # automatic matching below reuses the already-stored pattern.
        $installers = @($Assets | Where-Object { _TestIsInstallableAsset $_.name $InstallType })
        if ($InstallType -eq 'archive') {
            $installers = @($installers | Where-Object { -not (_TestIsSourceAsset $_.name) })
        }
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

        # Assets built for another architecture cannot be used here - they are
        # noise in the list. Everything else stays selectable, because the
        # arch scoring is just a guess and can be wrong.
        $showable = @($scored | Where-Object { $_.score -gt 0 } | ForEach-Object { $_.asset })
        if (-not $showable.Count) { $showable = $installers }
        # Several files look alike - the one that is the previous file with a
        # new version is the one that is wanted.
        $sameFile = @(_NarrowToSameFile $showable $PreviousName)
        $identified = ($sameFile.Count -eq 1 -and $showable.Count -gt 1)
        $showable = $sameFile

        if ($showable.Count -gt 1 -or ($GlobPattern -and -not $matched -and -not $identified)) {
            $recommendedName = if ($final.Count -gt 0) { $final[0].name } else { $null }
            return _SelectAssetFromList $showable $recommendedName $InstallType
        }
        return $showable[0]
    }

    # A check must not silently select an unrelated asset on a pattern miss.
    $candidates = @($Assets | Where-Object { _TestIsInstallableAsset $_.name $InstallType })
    if ($InstallType -eq 'archive') {
        # Source archives and checksum files are never the payload.
        $candidates = @($candidates | Where-Object { -not (_TestIsSourceAsset $_.name) })
    }
    if (-not $candidates.Count) { return $null }
    if ($GlobPattern) {
        $matched = @($candidates | Where-Object { $_.name -like $GlobPattern })
        if ($matched) { $candidates = $matched }
        else {
            # The pattern is stale - the file that is the previous file with a
            # new version still counts.
            $sameFile = @(_NarrowToSameFile $candidates $PreviousName)
            if ($sameFile.Count -ne 1 -or $candidates.Count -lt 2) { return $null }
            $candidates = $sameFile
        }
    }

    $arch   = _GetNativeArch
    $scored = @($candidates |
        ForEach-Object { [PSCustomObject]@{ asset = $_; score = _GetArchScore $_.name $arch } } |
        Sort-Object @{Expression = "score"; Descending = $true }, @{Expression = { $_.asset.name }; Descending = $false })
    $topScore = $scored[0].score
    if ($topScore -eq 0) { return $null }
    $final = @($scored | Where-Object { $_.score -eq $topScore } | ForEach-Object { $_.asset })
    $final = @(_NarrowToSameFile $final $PreviousName)
    if ($final.Count -eq 1) { return $final[0] }
    return $null
}

function _SaveAsset($Asset, $DestDir, $ProxyUrl) {
    New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
    $destPath = Join-Path $DestDir $Asset.name

    # A failed install keeps its downloaded package. When a retry comes
    # around, a kept file that already has the full release asset size is
    # the same download finished - use it instead of pulling it again. A
    # truncated (interrupted) file has the wrong size and is replaced.
    if ([System.IO.File]::Exists($destPath)) {
        $localSize = (Get-Item -LiteralPath $destPath).Length
        if ($localSize -eq $Asset.size) {
            Write-Host "Already downloaded, reusing: $($Asset.name)"
            return $destPath
        }
    }

    $sizeMb = [math]::Round($Asset.size / 1MB, 1)
    Write-Host "Downloading $($Asset.name) ($sizeMb MB)"

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
    # Turn a concrete asset name into a reusable glob by dropping the version
    # part: bat-v0.26.1-x86_64-pc-windows-msvc.zip -> *bat*x86*64*pc*windows*msvc*zip*
    # The version is cut out of the name instead of dropping a whole word, so
    # names that glue the version to the rest keep their shape:
    # gh_2.103.0_windows_amd64.msi -> *gh*windows*amd64*msi*
    $stripped = $FileName -replace 'v?\d+\.\d+(\.\d+)*', '' -replace '\d{4,}', ''
    $tokens = @($stripped -split '[\s_-]+' | Where-Object { $_ })
    if ($tokens.Count -eq 0) { return "*" }
    return "*" + ($tokens -join "*") + "*"
}

function _GetFileShape($FileName) {
    # The name of a file without its version: the words that stay the same
    # when the file is rebuilt for a new version.
    # Bitwarden-Installer-2026.10.0.exe -> Bitwarden|Installer|.exe
    if (-not $FileName) { return '' }
    $stripped = $FileName -replace 'v?\d+\.\d+(\.\d+)*', '' -replace '\d{4,}', ''
    $tokens = @($stripped -split '[\s_-]+' | Where-Object { $_ })
    return ($tokens -join '|')
}

function _NarrowToSameFile($Candidates, $PreviousName) {
    # Among several files, the one that is the previous file with a new
    # version: Bitwarden-Installer-2027.11.1.exe over
    # commercial-Bitwarden-Installer-2027.11.1.exe.
    if (-not $PreviousName -or @($Candidates).Count -lt 2) { return $Candidates }
    $shape = _GetFileShape $PreviousName
    if (-not $shape) { return $Candidates }
    $same = @($Candidates | Where-Object { (_GetFileShape $_.name) -eq $shape })
    if ($same.Count -eq 1) { return $same }
    return $Candidates
}

function _NewAssetPatternLegacy($FileName) {
    # The pattern gitget used to derive. Kept so a pattern gitget derived can
    # be told apart from one the user set by hand.
    $kept = @($FileName -split '[\s-]+' | Where-Object { $_ } | Where-Object {
        $_ -notmatch '^v?\d+$' -and $_ -notmatch '^v?\d+(\.\d+)+$' -and $_ -notmatch '\d\.\d'
    })
    if ($kept.Count -eq 0) { return "*" }
    return "*" + ($kept -join "*")
}

function _IsAutoPattern($App) {
    # True when the stored pattern was derived by gitget, not set by the user.
    if (-not $App -or -not $App.pattern) { return $true }
    if ($App.PSObject.Properties['pattern_explicit']) { return (-not $App.pattern_explicit) }
    # Entry from before the flag existed: a pattern that is what gitget
    # derived is not a hand-written one.
    if ($App.current_asset) {
        if ($App.pattern -eq (_NewAssetPatternLegacy $App.current_asset)) { return $true }
        if ($App.pattern -eq (_NewAssetPattern $App.current_asset)) { return $true }
    }
    return $false
}

function _GetEffectivePattern($App) {
    # The pattern assets are matched with. A derived pattern is rebuilt from
    # the asset that was installed last time, so an update does not have to
    # ask again when the stored pattern no longer matches.
    if (-not (_IsAutoPattern $App)) { return $App.pattern }
    if ($App.current_asset) {
        $derived = _NewAssetPattern $App.current_asset
        if ($derived) { return $derived }
    }
    return $App.pattern
}

function _SquishMsiGuid([string]$Guid) {
    # Windows Installer's compressed GUID form, as used in the Installer
    # registry keys: the first three fields are stored little-endian (their
    # bytes reversed), Data4 keeps its byte order, and every byte has its
    # nibbles swapped. Verified against live Installer\Products keys.
    if (-not $Guid) { return $null }
    $hex = ([string]$Guid).Trim().Trim('{}').Replace('-', '')
    if ($hex -notmatch '^[0-9A-Fa-f]{32}$') { return $null }
    $bytes = @()
    for ($i = 0; $i -lt 16; $i++) { $bytes += $hex.Substring($i * 2, 2) }
    # Byte order: Data1-Data3 reversed, Data4 (the last 8 bytes) in order.
    $order = @(3, 2, 1, 0, 5, 4, 7, 6) + (8..15)
    $out = ''
    foreach ($idx in $order) { $out += "$($bytes[$idx][1])$($bytes[$idx][0])" }
    return $out
}

function _ReadMsiProperty($Path, $Name) {
    # A property read straight out of the MSI database. Nothing is executed.
    $installer = $null
    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $db = $installer.OpenDatabase([string]$Path, 0)
        $view = $db.OpenView("SELECT Value FROM Property WHERE Property = '$Name'")
        # A bare method call writes its return value to the pipeline - pin
        # Execute down or the function returns the value twice over.
        $null = $view.Execute()
        $record = $view.Fetch()
        if (-not $record) { return $null }
        return [string]$record.StringData(1)
    }
    catch { return $null }
    finally {
        if ($installer) { $null = [Runtime.InteropServices.Marshal]::ReleaseComObject($installer) }
    }
}

function _GetMsiInstallContext($Path) {
    # How the product line inside this package is installed right now:
    # 'machine' when a copy is installed for everyone, 'user' when only for
    # this account, $null when nothing of it is here. The ProductCode changes
    # between versions, so the connection runs through the UpgradeCode: 
    # Installer\UpgradeCodes\<cod> lists the compressed code of every related
    # installed copy, and its UserData subkey tells the context - S-1-5-18 is
    # the machine account, a user SID an account-scoped install. Reading this
    # needs no elevation and runs nothing.
    $code = _ReadMsiProperty $Path 'UpgradeCode'
    if (-not $code) { return $null }
    $squished = _SquishMsiGuid $code
    if (-not $squished) { return $null }
    foreach ($root in @(
        "HKLM:\SOFTWARE\Classes\Installer\UpgradeCodes\$squished"
        "HKLM:\SOFTWARE\Classes\WOW6432Node\Installer\UpgradeCodes\$squished"
    )) {
        $item = Get-Item -LiteralPath $root -ErrorAction SilentlyContinue
        if (-not $item) { continue }
        # The related installed copies are the values, named by their
        # compressed product code.
        $products = @($item.GetValueNames() | Where-Object { $_ -match '^[0-9A-Fa-f]{32}$' })
        foreach ($squishedProduct in $products) {
            if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products\$squishedProduct") {
                return 'machine'
            }
            if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\*\Products\$squishedProduct") {
                return 'user'
            }
        }
    }
    return $null
}

function _InstallDownloadedAsset($Path) {
    $leaf = Split-Path -Leaf $Path
    $ext  = [System.IO.Path]::GetExtension($Path).ToLower()

    switch ($ext) {
        ".msi" {
            Write-Host "Installing (msiexec): $leaf"
            try {
                # An install that changes the install context of the copy
                # already on the machine aborts with 1603 (event 10005). Pin
                # the context: products installed for everyone upgrade
                # per-machine (ALLUSERS=1, the elevated default), products
                # installed only for this account stay per-user
                # (ALLUSERS=2 + MSIINSTALLPERUSER=1 survives elevation).
                $context = _GetMsiInstallContext $Path
                $contextArgs = if ($context -eq 'user') { @("ALLUSERS=2", "MSIINSTALLPERUSER=1") } else { @("ALLUSERS=1") }
                # A verbose msiexec log next to the package: the reason a
                # failed install matters is in it, not only the exit code.
                $log = "$Path.log"
                $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList (@("/i", "`"$Path`"", "/passive", "/norestart", "/l*v", "`"$log`"") + $contextArgs) -Verb RunAs -PassThru
                $proc.WaitForExit()
                if ($proc.ExitCode -in @(0, 1641, 3010)) {
                    # The Installer service can still hold the package for a
                    # moment after it reports success - retry the delete rather
                    # than failing it.
                    $files = @($Path, $log)
                    $kept = { @($files | Where-Object { Test-Path -LiteralPath $_ }).Count -gt 0 }
                    Remove-Item -LiteralPath $files -Force -ErrorAction SilentlyContinue
                    $deadline = [DateTime]::UtcNow.AddSeconds(5)
                    while ((& $kept) -and ([DateTime]::UtcNow -lt $deadline)) {
                        Start-Sleep -Milliseconds 250
                        Remove-Item -LiteralPath $files -Force -ErrorAction SilentlyContinue
                    }
                    if (& $kept) {
                        Write-Host "Installed: $leaf (the package copy could not be deleted yet - a later update reuses or replaces it)" -ForegroundColor Green
                    }
                    else {
                        Write-Host "Installed: $leaf" -ForegroundColor Green
                    }
                    return $true
                }
                else {
                    Write-Host "msiexec failed (code $($proc.ExitCode)); kept at $Path - msiexec log: $log" -ForegroundColor Yellow
                }
            }
            catch {
                Write-Host "Install failed ($($_.Exception.Message)); kept at $Path" -ForegroundColor Red
            }
        }
        ".exe" {
            Write-Host "Running installer: $leaf"
            try {
                # Wait only for the installer itself. Start-Process -Wait also
                # waits for descendants, so an installer that launches the app
                # ("run software" checkbox) would block until the app closes.
                $proc = Start-Process -FilePath $Path -PassThru
                $proc.WaitForExit()
                if ($proc.ExitCode -eq 0) {
                    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
                    Write-Host "Installed: $leaf" -ForegroundColor Green
                    return $true
                }
                else {
                    Write-Host "Installer failed (code $($proc.ExitCode)); kept at $Path" -ForegroundColor Yellow
                }
            }
            catch {
                Write-Host "Installer failed ($($_.Exception.Message)); kept at $Path" -ForegroundColor Red
            }
        }
        { $_ -in ".msix", ".msixbundle" } {
            Write-Host "Installing (Add-AppxPackage): $leaf"
            try {
                Add-AppxPackage -Path $Path -ErrorAction Stop
                Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
                Write-Host "Installed: $leaf" -ForegroundColor Green
                return $true
            }
            catch {
                Write-Host "Add-AppxPackage failed ($($_.Exception.Message)); kept at $Path" -ForegroundColor Red
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
# Portable payloads and archives
# --------------------------------------------------------------------------

function _GetFileSha256($Path) {
    if (-not $Path -or -not [System.IO.File]::Exists($Path)) { return $null }
    try {
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLower()
    }
    catch { return $null }
}

function _RegisterBinDir($BinDir) {
    # Put a bin dir on the user PATH, in front of the other user entries, so a
    # stale copy further down the PATH (a leftover winget link, the legacy bin
    # dir) must not shadow it. Idempotent: a present entry is left alone, so
    # installs and updates do not rewrite the PATH.
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if (-not $userPath) { $userPath = "" }
    $known = @($userPath -split ';' | Where-Object { $_ })
    $kept = @($known | Where-Object { $_.TrimEnd('\') -ine $BinDir.TrimEnd('\') })
    # @() guards: string + array joins with spaces, which would corrupt PATH.
    $new = (@($BinDir) + $kept) -join ';'
    if ($new -ine $userPath) { [Environment]::SetEnvironmentVariable("Path", $new, "User") }

    $session = @($env:Path -split ';' | Where-Object { $_ })
    $keptSession = @($session | Where-Object { $_.TrimEnd('\') -ine $BinDir.TrimEnd('\') })
    $env:Path = ((@($BinDir) + $keptSession) -join ';')
}

function _PromotePayloadExe($Exe) {
    # Copy the staged payload program (and its adjacent .dll files) into the
    # shared bin dir and return the placed exe. An exe staged inside the shared
    # bin dir already is returned as-is.
    $stageDir = Split-Path -Parent $Exe
    if ($stageDir.TrimEnd('\') -ieq $SharedBinDir.TrimEnd('\')) { return $Exe }

    New-Item -ItemType Directory -Force -Path $SharedBinDir | Out-Null
    Get-ChildItem -LiteralPath $stageDir -Filter *.dll -File -ErrorAction SilentlyContinue |
        ForEach-Object { [void](_ReplaceLockedCopy $_.FullName (Join-Path $SharedBinDir $_.Name)) }
    $dest = Join-Path $SharedBinDir (Split-Path -Leaf $Exe)
    [void](_ReplaceLockedCopy $Exe $dest)
    return $dest
}

function _TestElevated {
    return [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function _GetPayloadProcesses($Dir) {
    # Running programs whose binary lives inside $Dir. Found through the
    # process image path, which is readable without elevation.
    $dirPath = $Dir.TrimEnd('\')
    return @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Path -and $_.Path.StartsWith("$dirPath\", [System.StringComparison]::OrdinalIgnoreCase)
    })
}

function _TestServiceProgramEquals($Service, $ProgramPath) {
    # A service's PathName is either "<exepath> <args>" or a quoted
    # '"<exepath>" <args>'; the program is the part before the arguments.
    if (-not $Service -or -not $Service.PathName) { return $false }
    $p = $Service.PathName
    if ($p.StartsWith('"')) {
        if ($p.Length -lt 2) { return $false }
        $end = $p.IndexOf('"', 1)
        if ($end -lt 0) { return $false }
        $p = $p.Substring(1, $end - 1)
    }
    else { $p = ($p -split ' ', 2)[0] }
    if (-not $p) { return $false }
    return ($p.TrimEnd('\') -ieq ([string]$ProgramPath).TrimEnd('\'))
}

function _GetPayloadServicesOfProcess($Proc) {
    # Services that a payload program's supervisor process manages. The
    # wrapped program itself is not the service program, so the service is
    # resolved via the supervisor: when the host is launched as
    # '"<hostpath>" "<servicename>"', its extra quoted argument names the
    # service. When the payload exe is the service program itself, every
    # service registered on it wraps this payload and is returned.
    if (-not $Proc) { return @() }
    $prog = $null
    if ($Proc.CommandLine) {
        if ($Proc.CommandLine -match '^\s*"([^"]+)"') { $prog = $Matches[1] }
        else { $prog = ($Proc.CommandLine -split ' ', 2)[0] }
    }
    if (-not $prog -and $Proc.ExecutablePath) { $prog = $Proc.ExecutablePath }
    if (-not $prog) { return @() }

    if ($Proc.CommandLine) {
        $rest = ($Proc.CommandLine -replace '^\s*"[^"]+"\s*', '')
        foreach ($tok in @([regex]::Matches($rest, '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value })) {
            $filter = "Name='" + ($tok -replace "'", "''") + "'"
            $svc = Get-CimInstance Win32_Service -Filter $filter -ErrorAction SilentlyContinue
            if ($svc -and (_TestServiceProgramEquals $svc $prog)) { return @($svc) }
        }
    }
    return @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
              Where-Object { _TestServiceProgramEquals $_ $prog })
}

function _GetPayloadServiceNames($Dir) {
    # Windows services that keep a running program with its binary inside
    # $Dir, found by climbing to the payload's supervisor process and looking
    # it up in the service database. The climb is process data; where the
    # supervisor runs elevated (a Servy style host), reading the chain needs
    # elevation, so then it reruns in a pwsh child via gsudo. Only evidence
    # from the payload dir itself is accepted, never the other way around.

    $procs = @(_GetPayloadProcesses $Dir)
    if (-not $procs.Count) { return @() }

    if (_TestElevated) {
        # Direction confirmed in-session. Climb from the payload program to
        # its supervisor, then read the supervisor's identity in the service
        # database. Guard bails so a reused PID never resolves to the wrong
        # service, and the hop limit bounds the walk.
        $names = @()
        $seen = @{}
        foreach ($proc in $procs) {
            $procId = $proc.Id
            for ($hop = 0; $hop -lt 6 -and $procId; $hop++) {
                if ($seen.ContainsKey($procId)) { break }
                $seen[$procId] = $true
                $hostProc = Get-CimInstance Win32_Process -Filter "ProcessId=$procId" -ErrorAction SilentlyContinue
                if (-not $hostProc) { break }
                $svcs = @(_GetPayloadServicesOfProcess $hostProc)
                if ($svcs.Count) { $names += @($svcs | ForEach-Object Name); break }
                $procId = $hostProc.ParentProcessId
            }
        }
        return @($names | Select-Object -Unique)
    }

    # Not elevated: reading a SYSTEM host's command line is not possible
    # here, so the climb reruns in an elevated pwsh child. Only "-wpm"-free
    # generic output lines come back, so console noise cannot become a
    # service name.
    if (Get-Command gsudo -ErrorAction SilentlyContinue) {
        $child = @(& gsudo {
            param($dir, $file)
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$parseErrors)
            if ($parseErrors.Count) { return }
            $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
                ForEach-Object { Invoke-Expression $_.Extent.Text }
            _GetPayloadServiceNames $dir | ForEach-Object { "svcname:$_" }
        } -args $Dir, $PSCommandPath 2>$null)
        return @(@($child | Where-Object { $_ -like 'svcname:*' }) | ForEach-Object { $_.Substring(8) })
    }

    # No gsudo: service-hosted programs stay undetectable here. Nothing stops
    # and the caller relies on the rename replacement instead.
    return @()
}

function _SetPayloadServices([ValidateSet("Stop", "Start")][string]$Verb, [string[]]$ServiceNames) {
    # Returns whether every service action succeeded. Only start/stop is
    # ever performed - never a config change, datatype write, or removal.
    if (-not $ServiceNames -or $ServiceNames.Count -eq 0) { return $true }
    if (_TestElevated) {
        $ok = $true
        foreach ($name in $ServiceNames) {
            try {
                if ($Verb -eq "Stop") { Stop-Service -Name $name -ErrorAction Stop }
                else { Start-Service -Name $name -ErrorAction Stop }
            }
            catch { $ok = $false }
        }
        return $ok
    }
    if (-not (Get-Command gsudo -ErrorAction SilentlyContinue)) { return $false }
    # gsudo sequence-flattens array args, so only scalars cross into the
    # scriptblock; NUL is here as an unchanged-on-path separator.
    $sep = [string][char]0
    & gsudo {
        param($verb, $packed)
        $ok = $true
        foreach ($name in $packed -split [string][char]0) {
            try {
                if ($verb -eq "Stop") { Stop-Service -Name $name -ErrorAction Stop }
                else { Start-Service -Name $name -ErrorAction Stop }
            }
            catch { $ok = $false }
        }
        if ($ok) { exit 0 } else { exit 1 }
    } -args $Verb, ([string]$ServiceNames -join $sep) | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function _RemoveParkedPayloadCopies($Dirs) {
    # Best effort: a parked copy is only deletable once whatever holds it (a
    # program running the old image) exited, so leftovers stay until the next
    # update or removal cleans them.
    foreach ($dir in @($Dirs | Where-Object { $_ -and (Test-Path -LiteralPath $_) })) {
        Get-ChildItem -LiteralPath $dir -Filter '*.ggold' -File -ErrorAction SilentlyContinue |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
    }
}

function _PausePayloadForUpdate($Dirs) {
    # Prepares payload dirs for a copy. Services started from copies inside
    # those dirs hold their files open and are asked to stop for the
    # duration; nothing is launched or terminated. Returns the paused state
    # for the caller (_ResumePausedPayload restarts only the stopped ones),
    # or $null when the dirs used no service, stopping itself failed - in
    # which case replacement still lands, through the rename in
    # _ReplaceLockedCopy.
    $dirs = @($Dirs | Where-Object { $_ -and (Test-Path -LiteralPath $_) } |
              ForEach-Object { $_.TrimEnd('\') } | Select-Object -Unique)
    if (-not $dirs.Count) { return $null }

    # Stale parked copies from earlier updates whose holder since exited.
    _RemoveParkedPayloadCopies $dirs

    $names = @()
    foreach ($dir in $dirs) { $names += @(_GetPayloadServiceNames $dir) }
    $names = @($names | Select-Object -Unique)
    if (-not $names.Count) { return $null }

    [void](_SetPayloadServices "Stop" $names)
    $actuallyStopped = @(Get-Service -Name $names -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -eq "Stopped" } | ForEach-Object { $_.Name })
    if ($actuallyStopped.Count -lt $names.Count) {
        Write-Host "Service refusals during the update: copies locked by a still running program are replaced through a rename" -ForegroundColor Yellow
    }
    else {
        Write-Host "Stopped Service(s): $($actuallyStopped -join ', ')" -ForegroundColor Gray
    }
    return [pscustomobject]@{ Names = $actuallyStopped; Dirs = $dirs }
}

function _ResumePausedPayload($Paused) {
    # Restores the state _PausePayloadForUpdate found: only the services it
    # stopped are started again, and nothing that never stopped is touched.
    if (-not $Paused) { return }
    if ($Paused.Names.Count) {
        if (_SetPayloadServices "Start" $Paused.Names) {
            Write-Host "Restarted $($Paused.Names -join ', ')" -ForegroundColor Gray
        }
        else {
            Write-Host "Start failed for $($Paused.Names -join ', ') - start by hand with 'wpm start all'" -ForegroundColor Yellow
        }
    }
    _RemoveParkedPayloadCopies $Paused.Dirs
}

function _ReplaceLockedCopy($Source, $DestPath) {
    # gitget's copy into the payload's final place. A program that is still
    # running holds its binary open: Copy-Item -Force cannot overwrite it,
    # but a running image can be renamed, so the old copy is parked under a
    # ".ggold" suffix and the update lands next to it. The program keeps
    # running on the parked copy; whoever ran it from there keeps the old
    # version until they restart. Returns nothing; throws when the copy
    # cannot land at all.
    try {
        Copy-Item -LiteralPath $Source -Destination $DestPath -Force -ErrorAction Stop
        return
    }
    catch {
        Move-Item -LiteralPath $DestPath -Destination "$DestPath.ggold" -Force -ErrorAction Stop
        Copy-Item -LiteralPath $Source -Destination $DestPath -Force -ErrorAction Stop
        Write-Host "Replaced locked copy (kept as $((Split-Path -Leaf $DestPath)).ggold - running program keeps the old version until it restarts)" -ForegroundColor Gray
    }
}

function _UnregisterBinDir($BinDir) {
    # Drop the payload directory from the PATH so a removed program is not
    # still callable through a stale entry.
    if (-not $BinDir) { return }

    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($userPath) {
        $known = @($userPath -split ';' | Where-Object { $_ })
        $kept = @($known | Where-Object { $_.TrimEnd('\') -ine $BinDir.TrimEnd('\') })
        if ($kept.Count -ne $known.Count) {
            [Environment]::SetEnvironmentVariable("Path", ($kept -join ';'), "User")
            Write-Host "Removed from PATH: $BinDir" -ForegroundColor Gray
        }
    }

    $session = @($env:Path -split ';' | Where-Object { $_ })
    $keptSession = @($session | Where-Object { $_.TrimEnd('\') -ine $BinDir.TrimEnd('\') })
    if ($keptSession.Count -ne $session.Count) {
        $env:Path = ($keptSession -join ';')
    }
}

function _Find7Zip {
    # 7-Zip is only searched when a .7z asset actually needs unpacking. The
    # installer does not add its directory to PATH, so fall back to the
    # standard install roots and the registry path it records.
    $sevenZip = Get-Command 7z.exe -ErrorAction SilentlyContinue
    if ($sevenZip) { return $sevenZip.Source }

    $candidates = @(
        "$env:ProgramFiles\7-Zip\7z.exe"
        "${env:ProgramFiles(x86)}\7-Zip\7z.exe"
        "$env:LOCALAPPDATA\Programs\7-Zip\7z.exe"
    )
    foreach ($regKey in @("HKLM:\SOFTWARE\7-Zip", "HKLM:\SOFTWARE\WOW6432Node\7-Zip")) {
        $installDir = (Get-ItemProperty $regKey -ErrorAction SilentlyContinue).Path64
        if (-not $installDir) { $installDir = (Get-ItemProperty $regKey -ErrorAction SilentlyContinue).Path }
        if ($installDir) { $candidates += (Join-Path $installDir "7z.exe") }
    }
    return @($candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1)
}

function _ExpandPayloadArchive($Path, $DestDir) {
    $name = (Split-Path -Leaf $Path).ToLower()
    New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
    if ($name -match '\.zip$') {
        Expand-Archive -LiteralPath $Path -DestinationPath $DestDir -Force
        return
    }
    if ($name -match '\.(tar\.gz|tar\.bz2|tar\.xz|tar\.zst|tgz|tbz2|txz|tar)$') {
        & tar.exe -xf $Path -C $DestDir
        if ($LASTEXITCODE -ne 0) { throw "tar extraction failed (exit code $LASTEXITCODE)" }
        return
    }
    if ($name -match '\.7z$') {
        $sevenZip = _Find7Zip
        if (-not $sevenZip) { throw "7-Zip is required to unpack .7z assets (winget install 7zip)" }
        & $sevenZip x -y "-o$DestDir" $Path | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "7-Zip extraction failed (exit code $LASTEXITCODE)" }
        return
    }
    throw "Unsupported archive type: $name"
}

function _FlattenPayloadDir($Dir) {
    # Most archives ship a single top-level folder; lift it so the payload
    # path stays the same between updates.
    $items = @(Get-ChildItem -LiteralPath $Dir -Force -ErrorAction SilentlyContinue)
    $dirs  = @($items | Where-Object { $_.PSIsContainer })
    $files = @($items | Where-Object { -not $_.PSIsContainer })
    if ($dirs.Count -eq 1 -and $files.Count -eq 0) {
        $inner = $dirs[0].FullName
        foreach ($child in @(Get-ChildItem -LiteralPath $inner -Force -ErrorAction SilentlyContinue)) {
            Move-Item -LiteralPath $child.FullName -Destination $Dir -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $inner -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function _FindPayloadExe($Dir, $AppName) {
    $exes = @(Get-ChildItem -LiteralPath $Dir -Filter *.exe -Recurse -File -ErrorAction SilentlyContinue |
              Where-Object { -not (_TestLooksLikeInstaller $_.Name) })
    if ($exes.Count -eq 0) { return $null }
    $needle = (($AppName -replace '[^a-zA-Z0-9]', '')).ToLower()
    if ($needle) {
        $named = @($exes | Where-Object { (($_.BaseName -replace '[^a-zA-Z0-9]', '')).ToLower() -eq $needle })
        if ($named.Count -eq 1) { return $named[0].FullName }
    }
    if ($exes.Count -eq 1) { return $exes[0].FullName }
    # Several programs in one archive: the largest one is the payload.
    return ($exes | Sort-Object Length -Descending | Select-Object -First 1).FullName
}

function _InstallPortablePayload($Path, $BinDir, $AppName) {
    # Places a portable payload in $BinDir and returns the installed program.
    New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
    $ext = [System.IO.Path]::GetExtension($Path).ToLower()
    if ($ext -eq ".exe") {
        $dest = Join-Path $BinDir (Split-Path -Leaf $Path)
        [void](_ReplaceLockedCopy $Path $dest)
        return $dest
    }
    _ExpandPayloadArchive $Path $BinDir
    _FlattenPayloadDir $BinDir
    $exe = _FindPayloadExe $BinDir $AppName
    if (-not $exe) { throw "No program found in the unpacked archive" }
    return $exe
}

function _SetInstallState($App, $Version, $AssetName, $ExePath) {
    # Record what we installed so later checks can verify it.
    $state = [PSCustomObject]@{
        version = $Version
        asset   = $AssetName
        path    = $ExePath
        sha256  = _GetFileSha256 $ExePath
        at      = (Get-Date).ToUniversalTime().ToString("o")
    }
    if ($App.PSObject.Properties['installed']) { $App.installed = $state }
    else { $App | Add-Member -NotePropertyName installed -NotePropertyValue $state }
}

function _InstallAppPayload($AppName, $App, $Asset, $LatestVersion, $ProxyUrl) {
    # Downloads the asset and installs it the way the app's kind requires.
    # Returns $true only when the payload is in place.
    $type = _GetInstallType $App

    # Drop the previous download so a rename does not leave two copies behind.
    if ($App.install_dir -and $App.current_asset -and $App.current_asset -ne $Asset.name) {
        $stalePath = Join-Path $App.install_dir $App.current_asset
        if (Test-Path $stalePath) {
            Remove-Item $stalePath -Force -ErrorAction SilentlyContinue
            Write-Host "Removed old download: $($App.current_asset)" -ForegroundColor Gray
        }
    }

    $path = $null
    try { $path = _SaveAsset $Asset $App.install_dir $ProxyUrl }
    catch { Write-Host "$AppName download failed: $($_.Exception.Message)" -ForegroundColor Red; return $false }

    if ($type -eq 'installer') {
        if (-not (_InstallDownloadedAsset $path)) { return $false }
    }
    else {
        # Archives are unpacked into a per-app staging dir and the program
        # lands in the shared bin dir. A -BinDir override keeps the program
        # (and the unpacked files) in its own dir instead.
        $override = $App.bin_dir -and $App.bin_dir.TrimEnd('\') -ine $SharedBinDir.TrimEnd('\')
        $stageDir = if ($override) { $App.bin_dir } else { Join-Path $AppsDir $AppName }
        $oldPath = if ($App.PSObject.Properties['installed'] -and $App.installed) { $App.installed.path } else { $null }
        $exe = $null
        # A service that runs the current payload keeps its copy open; copies
        # inside the payload dirs must land while such a service stays out of
        # the way. Whatever happens, the paused state is restored first.
        $paused = _PausePayloadForUpdate @($stageDir, $SharedBinDir)
        try {
            try { $exe = _InstallPortablePayload $path $stageDir $AppName }
            catch {
                Write-Host "$AppName install failed: $($_.Exception.Message)" -ForegroundColor Red
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
                return $false
            }
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            if (-not $override) { $exe = _PromotePayloadExe $exe }
            if ($oldPath -and $oldPath -ne $exe -and [System.IO.File]::Exists($oldPath)) {
                Remove-Item -LiteralPath $oldPath -Force -ErrorAction SilentlyContinue
            }
            if (-not $override) {
                Remove-Item -LiteralPath $stageDir -Recurse -Force -ErrorAction SilentlyContinue
            }
            _RegisterBinDir (Split-Path -Parent $exe)
            _SetInstallState $App $LatestVersion $Asset.name $exe
            Write-Host "Installed $AppName to $exe" -ForegroundColor Green
        }
        finally { _ResumePausedPayload $paused }
    }

    $autoPattern = _IsAutoPattern $App
    $App.current_version = $LatestVersion
    $App.current_asset = $Asset.name
    if ($autoPattern) {
        $App.pattern = _NewAssetPattern $Asset.name
        # Record that the pattern is derived, so it keeps being rebuilt.
        $App | Add-Member -NotePropertyName pattern_explicit -NotePropertyValue $false -Force
    }
    $App.last_checked = (Get-Date).ToUniversalTime().ToString("o")
    return $true
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
    Write-Host "Config backed up." -ForegroundColor Green
}

function _Restore {
    $path = $RestorePath
    if (-not $path) { $path = $Target }
    if (-not $path) {
        Write-Host "Provide a config file path." -ForegroundColor Red
        return
    }
    if (-not (Test-Path $path)) {
        Write-Host "File not found: $path" -ForegroundColor Red
        return
    }
    New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
    Copy-Item -LiteralPath $path -Destination $ConfFilePath -Force
    Write-Host "Restored config from: $path" -ForegroundColor Green
}

function _GetInstallKindCandidates($Releases) {
    # Kinds we could install from these releases, with example asset names.
    # A plain ".exe" is ambiguous: it can be a portable program (yt-dlp.exe)
    # or an installer with an ordinary name (Slack.exe). Both kinds are
    # offered for it, the more likely one first.
    $installerLike = @()
    $plainExe     = @()
    $archives     = @()
    foreach ($rel in $Releases) {
        foreach ($a in @($rel.assets)) {
            if (-not $a.name -or (_TestIsSourceAsset $a.name)) { continue }
            if (_TestIsArchiveAsset $a.name) {
                if (-not (_TestIsWindowsAsset $a.name)) { continue }
                if (-not ($archives -contains $a.name)) { $archives += $a.name }
                continue
            }
            if (-not (_TestIsInstallerAsset $a.name)) { continue }
            if (_TestLooksLikeInstaller $a.name) {
                if (-not ($installerLike -contains $a.name)) { $installerLike += $a.name }
            }
            else {
                if (-not ($plainExe -contains $a.name)) { $plainExe += $a.name }
            }
        }
    }

    $result = @()
    if ($installerLike.Count) {
        $result += [PSCustomObject]@{ kind = 'installer'; examples = $installerLike; recommended = $true }
    }
    elseif ($plainExe.Count) {
        $result += [PSCustomObject]@{ kind = 'installer'; examples = $plainExe; recommended = $false }
    }
    if ($plainExe.Count) {
        $result += [PSCustomObject]@{ kind = 'portable'; examples = $plainExe; recommended = (-not $installerLike.Count) }
    }
    if ($archives.Count) {
        $result += [PSCustomObject]@{ kind = 'archive'; examples = $archives; recommended = (-not $installerLike.Count -and -not $plainExe.Count) }
    }
    if (-not $result.Count) { return @() }

    # The recommended kind comes first so it is the default in the picker.
    $order = @{ 'installer' = 0; 'portable' = 1; 'archive' = 2 }
    return @($result | Sort-Object @{Expression = { if ($_.recommended) { 0 } else { 1 } } }, @{Expression = { $order[$_.kind] } })
}

function _SelectInstallKind($Candidates) {
    if (-not $Candidates -or @($Candidates).Count -eq 0) { return $null }
    if (@($Candidates).Count -eq 1) { return $Candidates[0].kind }
    $labels = @($Candidates | ForEach-Object {
        $what = switch ($_.kind) {
            'installer' { 'run as installer' }
            'portable'  { 'copy (portable program)' }
            'archive'   { 'unpack archive' }
        }
        "{0,-10} {1,-24} {2}" -f $_.kind, $what, (($_.examples | Select-Object -First 3) -join ', ')
    })
    Write-Host "Pick how to install it:" -ForegroundColor Yellow
    $picked = @($labels | fzf --prompt="kind> " --no-sort)[0]
    if ($LASTEXITCODE -eq 0 -and $picked) {
        $idx = [array]::IndexOf($labels, $picked)
        if ($idx -ge 0) { return $Candidates[$idx].kind }
    }
    return $null
}

function _ResolveInstallType($AppName, $App, $Release, $CurrentType, $Config) {
    # The tracked kind is not in this release any more. Pick the kind the
    # release ships now and remember it, so this is asked at most once.
    $candidates = @(_GetInstallKindCandidates @($Release) | Where-Object { $_.kind -ne $CurrentType })
    if ($candidates.Count -eq 0) { return $null }
    $kind = if ($candidates.Count -eq 1) { $candidates[0].kind } else { _SelectInstallKind $candidates }
    if (-not $kind) { return $null }
    $autoPattern = _IsAutoPattern $App
    $App | Add-Member -NotePropertyName install_type -NotePropertyValue $kind -Force
    if ($App.PSObject.Properties['installed']) { $App.installed = $null }
    # The old file name means nothing for the new kind - let the picker show
    # what the release ships.
    $App | Add-Member -NotePropertyName current_asset -NotePropertyValue $null -Force
    if ($autoPattern) { $App.pattern = '*' }
    # Record the release line, so it does not have to be guessed again.
    if (-not ($App.PSObject.Properties['tag_family'] -and $App.tag_family)) {
        $App | Add-Member -NotePropertyName tag_family -NotePropertyValue (_GetReleaseKey $Release) -Force
    }
    if ($Config) { _SaveConfig $Config }
    Write-Host "$($AppName): switched to $kind" -ForegroundColor Yellow
    return $kind
}

function _InstallTrackedApp($AppName, $App, $ProxyUrl, $Config) {
    # Installs the tracked release of an app that is not on the machine.
    # Returns $true when the payload is in place.
    try {
        $release = _GetTrackedRelease $AppName $App $ProxyUrl -Force:$Force
        $latestVersion = _ExtractConfiguredVersion $release.tag_name $App.release_version_regex
        $type = _GetInstallType $App
        if (@($release.assets | Where-Object { _TestIsInstallableAsset $_.name $type }).Count -eq 0) {
            $newType = _ResolveInstallType $AppName $App $release $type $Config
            if (-not $newType) {
                Write-Host ("$AppName`: no suitable payload found on $($release.tag_name)") -ForegroundColor Yellow
                return $false
            }
            $type = $newType
        }
        $assetObj = $null
        if ($App.current_asset) {
            $assetObj = @($release.assets | Where-Object { $_.name -eq $App.current_asset -and (_TestIsInstallableAsset $_.name $type) }) | Select-Object -First 1
        }
        if (-not $assetObj) {
            $assetObj = _SelectAsset $release.assets (_GetEffectivePattern $App) -Interactive -InstallType $type -PreviousName $App.current_asset
        }
        if (-not $assetObj) {
            Write-Host ("$AppName`: no suitable $type payload found on $($release.tag_name)") -ForegroundColor Yellow
            return $false
        }
        if (-not (_InstallAppPayload $AppName $App $assetObj $latestVersion $ProxyUrl)) { return $false }
        _SaveConfig $Config
        Write-Host "$AppName installed ($latestVersion)" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "$AppName install failed: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function _AddTrackedApp($AppName, $App, $ProxyUrl, $Config) {
    # The app is already tracked: install it when it is not on the machine.
    Write-Host "'$AppName' is already tracked." -ForegroundColor Yellow
    if ($NoInstall) {
        Write-Host "Tracked only - run 'gitget install $AppName'" -ForegroundColor Yellow
        return
    }
    if ($CurrentVersion) {
        # The user says the program is already on the machine.
        if (-not $App.current_version) {
            $App | Add-Member -NotePropertyName current_version -NotePropertyValue $CurrentVersion -Force
            _SaveConfig $Config
        }
        Write-Host "$AppName already installed ($CurrentVersion)" -ForegroundColor Green
        return
    }
    $state = $null
    try { $state = _GetInstalledState $AppName $App }
    catch {
        Write-Host "$($AppName): cannot tell whether it is installed - $($_.Exception.Message)" -ForegroundColor Yellow
        return
    }
    if ($state.installed -and -not $Reinstall) {
        $shown = if ($state.version) { $state.version } else { 'version unknown' }
        Write-Host "$AppName already installed ($shown)" -ForegroundColor Green
        return
    }
    if ($Reinstall) { Write-Host "Reinstalling $AppName..." -ForegroundColor Yellow }
    else { Write-Host "$AppName not installed - installing it now." -ForegroundColor Yellow }
    $null = _InstallTrackedApp $AppName $App $ProxyUrl $Config
}

function _Add {
    if (-not $Target) { Write-Host "Provide a repo, e.g. gitget add sharkdp/bat" -ForegroundColor Red; return }
    $repo = _ConvertToRepoSlug $Target
    if (-not $repo) {
        Write-Host "Use 'owner/repo' or a github.com URL." -ForegroundColor Red
        return
    }

    $proxyUrl = _ResolveProxy
    $config = _GetConfig

    $defaultName = ($repo -split '/')[1]
    if ($Name) {
        $appName = $Name
    }
    elseif (_GetAppEntry $config $defaultName) {
        # The repo's own name is already tracked - no need to ask.
        $appName = $defaultName
    }
    else {
        $resp = Read-Host "Name? [$defaultName]"
        $appName = if ($null -eq $resp -or $resp.Trim() -eq "") { $defaultName } else { $resp.Trim() }
    }

    $existing = _GetAppEntry $config $appName
    if ($existing) {
        # Already tracked - install it when it is not on the machine.
        if ($existing.Value.repo -and $existing.Value.repo -ne $repo) {
            Write-Host "'$appName' tracks $($existing.Value.repo) - installing that one" -ForegroundColor Yellow
        }
        _AddTrackedApp $appName $existing.Value $proxyUrl $config
        return
    }

    $releases = _GetReleases $repo $ReleaseLimit $proxyUrl
    $candidates = @(@($releases | Where-Object { -not $_.prerelease -or $IncludePrerelease }))
    if ($TagPattern) { $candidates = @($candidates | Where-Object { $_.tag_name -like $TagPattern }) }
    if ($ReleaseNamePattern) { $candidates = @($candidates | Where-Object { $_.name -like $ReleaseNamePattern }) }

    $kind = $InstallType
    if (-not $kind) {
        $kinds = _GetInstallKindCandidates $candidates
        if ($kinds.Count -eq 0) {
            Write-Host "No Windows payload found." -ForegroundColor Yellow
            return
        }
        $kind = _SelectInstallKind $kinds
        if (-not $kind) { Write-Host "Cancelled." -ForegroundColor Yellow; return }
    }

    $installable = @($candidates | Where-Object {
        @($_.assets | Where-Object { _TestIsInstallableAsset $_.name $kind }).Count -gt 0
    })
    $release = $null
    if ($installable.Count -gt 0) {
        $byFamily = @(_GetReleaseLines $installable)
        if ($byFamily.Count -gt 1) {
            $release = _SelectReleaseLine $byFamily
        } else {
            $release = $installable[0]
        }
    }
    if (-not $release) { Write-Host "No $kind release matches the requested filters." -ForegroundColor Yellow; return }
    $asset = _SelectAsset $release.assets $Pattern -Interactive -InstallType $kind

    if (-not $asset) {
        Write-Host "No $kind assets found on release $($release.tag_name)." -ForegroundColor Yellow
        if ($release.assets) {
            $release.assets | ForEach-Object { Write-Host "  $($_.name)" }
        }
        return
    }

    $installDir = if ($Dir) { $Dir } else { Join-Path $DownloadsDir $appName }
    $binDir = if ($BinDir) { $BinDir } elseif ($kind -ne 'installer') { $SharedBinDir } else { $null }

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
        install_type   = $kind
        bin_dir        = $binDir
        installed      = $null
    }
    $config.apps | Add-Member -NotePropertyName $appName -NotePropertyValue $entry -Force
    _SaveConfig $config

    Write-Host "$appName $($release.tag_name) ($($asset.name)) - $kind" -ForegroundColor Green

    if ($NoInstall) {
        Write-Host "Tracked only - run 'gitget install $appName'" -ForegroundColor Yellow
        return
    }

    # Install it right away, unless the program is already on the machine.
    if ($CurrentVersion) {
        Write-Host "$appName already installed ($CurrentVersion)" -ForegroundColor Green
        return
    }
    $state = $null
    try { $state = _GetInstalledState $appName $entry }
    catch { $state = @{ installed = $false; version = $null } }
    if ($state.installed) {
        Write-Host "$appName already installed ($($state.version))" -ForegroundColor Green
        return
    }

    $latest = _ExtractConfiguredVersion $release.tag_name $entry.release_version_regex
    if (_InstallAppPayload $appName $entry $asset $latest $proxyUrl) {
        _SaveConfig $config
    }
}

function _Remove {
    $config = _GetConfig
    $entries = $config.apps.PSObject.Properties
    if (-not $entries -or $entries.Count -eq 0) {
        Write-Host "Nothing tracked." -ForegroundColor Yellow
        return
    }

    $names = @($entries | ForEach-Object { $_.Name })
    if ($All) {
        # Everything that is tracked, without the picker.
        $selected = @($names)
    }
    elseif ($Target) {
        if ($names -notcontains $Target) {
            Write-Host "'$Target' is not tracked." -ForegroundColor Yellow
            return
        }
        $selected = @($Target)
    } else {
        $selected = @($names | fzf --multi --reverse --height=40% --header="Select to remove")
        if (-not $selected) { return }
    }

    foreach ($name in $selected) {
        $prop = _GetAppEntry $config $name
        $purged = $false
        if ($prop) {
            # Portable and archive payloads were placed by gitget, so gitget owns
            # their files - removing the app removes them. An installer payload
            # belongs to the program's own uninstaller and is left alone unless
            # -Purge asks for its leftovers to go too.
            $managed = (_GetInstallType $prop.Value) -ne 'installer'
            if ($managed -or $Purge) {
                _PurgeAppFiles $name $prop.Value
                $purged = $true
            }
            else {
                Write-Host "'$name' has its own installer - uninstall it there" -ForegroundColor Yellow
            }
        }
        $config.apps.PSObject.Properties.Remove($name)
        $suffix = if ($purged) { ' (files removed)' } else { '' }
        Write-Host "Removed '$name'$suffix" -ForegroundColor Green
    }
    # The shared bin dir goes off the PATH when no tracked install lives there.
    $stillUsing = @($config.apps.PSObject.Properties | Where-Object {
        _GetInstallType $_.Value -ne 'installer'
    } | Where-Object {
        $b = $_.Value
        ($b.bin_dir -and $b.bin_dir.TrimEnd('\') -ieq $SharedBinDir.TrimEnd('\')) -or
        ($b.PSObject.Properties['installed'] -and $b.installed -and $b.installed.path -and
         (Split-Path -Parent $b.installed.path).TrimEnd('\') -ieq $SharedBinDir.TrimEnd('\'))
    })
    if ($stillUsing.Count -eq 0) { _UnregisterBinDir $SharedBinDir }
    _SaveConfig $config
}

function _PurgeAppFiles($AppName, $App) {
    # Delete the program of a portable/archive app and, for a per-app payload
    # dir, the whole dir. The shared bin dir holds every program's exe, so only
    # this app's exe goes; the dir itself stays for the remaining apps.
    $binDir = $App.bin_dir
    if ($binDir -and (Test-Path $binDir) -and $binDir.TrimEnd('\') -ieq $SharedBinDir.TrimEnd('\')) {
        $exePath = if ($App.installed -and $App.installed.path) { $App.installed.path } else { $null }
        if ($exePath -and (Test-Path -LiteralPath $exePath) -and
            ((Split-Path -Parent $exePath).TrimEnd('\') -ieq $SharedBinDir.TrimEnd('\'))) {
            try {
                Remove-Item -LiteralPath $exePath -Force -ErrorAction Stop
                Write-Host "Deleted: $(Split-Path -Leaf $exePath)" -ForegroundColor Gray
            }
            catch { Write-Host "Failed to delete '$exePath': $($_.Exception.Message)" -ForegroundColor Red }
        }
        $binDir = $null   # the shared dir itself is not unregistered here
    }
    elseif ($binDir -and (Test-Path $binDir)) {
        try { Remove-Item $binDir -Recurse -Force -ErrorAction Stop; Write-Host "Deleted payload: $(Split-Path -Leaf $binDir)" -ForegroundColor Gray }
        catch { Write-Host "Failed to delete payload '$binDir': $($_.Exception.Message)" -ForegroundColor Red }
    }
    # The PATH entry points at the dir the program actually lives in, which is
    # the payload dir unless the payload nests it in a subfolder.
    $registeredDir = $null
    if ($App.installed -and $App.installed.path) { $registeredDir = Split-Path -Parent $App.installed.path }
    foreach ($dir in @($registeredDir, $binDir)) {
        if ($dir -and $dir.TrimEnd('\') -ine $SharedBinDir.TrimEnd('\')) { _UnregisterBinDir $dir }
    }
    if ($App.install_dir -and (Test-Path $App.install_dir)) {
        try { Remove-Item $App.install_dir -Recurse -Force -ErrorAction Stop; Write-Host "Deleted downloads: $(Split-Path -Leaf $App.install_dir)" -ForegroundColor Gray }
        catch { Write-Host "Failed to delete downloads '$($App.install_dir)': $($_.Exception.Message)" -ForegroundColor Red }
    }
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
        $kind = _GetInstallType $prop.Value
        $ver = $null
        try {
            $detected = _GetInstalledVersion $prop.Name $prop.Value
            if ($detected.source -eq 'modified') {
                $ver = '?'
            }
            elseif ($detected.source -notin @('recorded (unverified)', 'unknown', 'missing')) {
                $ver = _ExtractConfiguredVersion $detected.version $prop.Value.installed_version_regex
            }
        }
        catch { $ver = '?' }
        if (-not $ver) { $ver = '-' }
        Write-Host ("{0,-$maxLen}  {1,-9}  {2}" -f $prop.Name, $kind, $ver)
    }
}

function _WriteCheckErrors {
    # One line per problem, not one per app: 27 apps failing the same way say
    # it once.
    $errors = @($script:checkErrors)
    if ($errors.Count -eq 0) { return }
    $groups = $errors | Group-Object reason
    foreach ($group in $groups) {
        if ($group.Count -eq 1) {
            Write-Host "$($group.Group[0].app) error: $($group.Name)" -ForegroundColor Red
        }
        else {
            Write-Host "$($group.Count) check(s) failed: $($group.Name)" -ForegroundColor Red
        }
    }
}

function _CheckOne($appName, $app, $ProxyUrl, [switch]$Force) {
    try {
        $release = _GetTrackedRelease $appName $app $ProxyUrl -Force:$Force
        $latestVersion = _ExtractConfiguredVersion $release.tag_name $app.release_version_regex
        $detected = _GetInstalledVersion $appName $app
        $verified = $detected.source -notin @('recorded (unverified)', 'unknown', 'missing', 'modified')
        $current = $app.current_version
        if ($verified -and $detected.version) {
            $current = _ExtractConfiguredVersion $detected.version $app.installed_version_regex
        }
        $modified = ($detected.source -eq 'modified')
        $hasUpdate = $false
        if ($modified) {
            # The installed copy changed outside gitget and does not report a
            # version - we cannot prove an update is needed, and overwriting a
            # possibly newer build would be a downgrade.
            Write-Host "$appName changed outside gitget - skipped" -ForegroundColor Yellow
        }
        else {
            $hasUpdate = _TestIsNewer $latestVersion $current
        }
        $configChanged = $verified -and $current -and -not (_TestSameVersion $current $app.current_version)
        if ($configChanged) { $app.current_version = $current }
        if (-not $modified -and $detected.source -in @('version command', 'file metadata') -and
            $app.PSObject.Properties['installed'] -and $app.installed -and $app.installed.path) {
            # The payload was replaced outside gitget (self-update) - record
            # what is on disk now so the next check can verify it again.
            $newHash = _GetFileSha256 $app.installed.path
            if ($newHash -and $newHash -ne $app.installed.sha256) {
                $app.installed.sha256 = $newHash
                $app.installed.version = $current
                $app.installed.at = (Get-Date).ToUniversalTime().ToString("o")
                $configChanged = $true
            }
        }
        $asset = _SelectAsset $release.assets (_GetEffectivePattern $app) -InstallType (_GetInstallType $app) -PreviousName $app.current_asset
        if ($hasUpdate) { Write-Host $appName -ForegroundColor Yellow }
        return [PSCustomObject]@{
            release = $release; asset = $asset; hasUpdate = $hasUpdate
            configChanged = [bool]$configChanged; verified = $verified
            modified = $modified; detected = $detected
        }
    }
    catch {
        $script:checkErrors += [PSCustomObject]@{ app = $appName; reason = $_.Exception.Message }
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
    $modifiedCount = 0
    $configChanged = $false
    $script:checkErrors = @()
    foreach ($prop in $targets) {
        $result = _CheckOne $prop.Name $prop.Value $proxyUrl -Force:$Force
        if ($null -eq $result) { $errorCount++; continue }
        if ($result.hasUpdate) { $updateCount++ }
        if ($result.modified) { $modifiedCount++ }
        if (-not $result.verified) { $unverifiedCount++ }
        if ($result.configChanged) { $configChanged = $true }
    }
    if ($configChanged) { _SaveConfig $config }

    _WriteCheckErrors
    if ($modifiedCount -gt 0) {
        Write-Host "$modifiedCount copy/copies changed outside gitget - skipped" -ForegroundColor Yellow
    }
    if ($errorCount -gt 0 -and $updateCount -eq 0) {
        return
    }
    elseif ($updateCount -eq 0 -and $unverifiedCount -gt 0) {
        Write-Host "$unverifiedCount version(s) unverified" -ForegroundColor Yellow
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
    $modifiedCount = 0
    $script:checkErrors = @()
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
        $forced = $false
        if ($result.modified) {
            $modifiedCount++
            # The installed copy changed outside gitget and reports no version.
            # Only an explicit reinstall is allowed to overwrite it.
            $forced = [bool]$Reinstall
            if (-not $forced) { continue }
        }
        elseif ($result.detected.source -eq 'missing') {
            # The payload was deleted - put the tracked release back.
            $forced = $true
        }
        if (-not $result.hasUpdate -and -not $forced) { continue }

        $updatable.Add([PSCustomObject]@{
            appName = $appName
            app     = $app
            release = $release
            latest  = $latestVersion
        })
    }

    if ($modifiedCount -gt 0 -and -not $Reinstall) {
        Write-Host "$modifiedCount copy/copies changed outside gitget - skipped (use -Reinstall)" -ForegroundColor Yellow
    }
    _WriteCheckErrors
    if ($errorCount -gt 0 -and $updatable.Count -eq 0) {
        return
    }
    if ($updatable.Count -eq 0) {
        if ($unverifiedCount -gt 0) { Write-Host "$unverifiedCount version(s) unverified" -ForegroundColor Yellow }
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
        $type = _GetInstallType $app

        # The release can ship another kind of payload than the one that was
        # installed last time. Switch to what it ships and remember it.
        if (@($release.assets | Where-Object { _TestIsInstallableAsset $_.name $type }).Count -eq 0) {
            $newType = _ResolveInstallType $appName $app $release $type $config
            if (-not $newType) {
                # No usable payload in this release - don't bump the
                # recorded version; it'll come up again once one lands.
                Write-Host "$appName $latestVersion has no $type payload - skipped" -ForegroundColor Yellow
                continue
            }
            $type = $newType
        }

        $asset = $null
        if ($app.current_asset) {
            $asset = @($release.assets | Where-Object { $_.name -eq $app.current_asset -and (_TestIsInstallableAsset $_.name $type) }) | Select-Object -First 1
        }
        if (-not $asset) {
            $asset = _SelectAsset $release.assets (_GetEffectivePattern $app) -Interactive -InstallType $type -PreviousName $app.current_asset
        }
        if (-not $asset) {
            Write-Host "$appName $latestVersion has no $type payload - skipped" -ForegroundColor Yellow
            continue
        }

        if (-not (_InstallAppPayload $appName $app $asset $latestVersion $proxyUrl)) { continue }
        _SaveConfig $config
    }
}

function _Install {
    $config = _GetConfig
    $entries = $config.apps.PSObject.Properties
    if (-not $entries -or $entries.Count -eq 0) {
        Write-Host "Nothing tracked." -ForegroundColor Yellow
        return
    }

    if ($Target -and -not (_GetAppEntry $config $Target)) {
        Write-Host "'$Target' is not tracked." -ForegroundColor Yellow
        return
    }
    $targets = if ($Target) { $entries | Where-Object { $_.Name -eq $Target } } else { $entries }

    $proxyUrl = _ResolveProxy
    $notInstalled = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($prop in $targets) {
        $state = _GetInstalledState $prop.Name $prop.Value
        if ($Reinstall -or -not $state.installed) {
            $notInstalled.Add([PSCustomObject]@{ appName = $prop.Name; app = $prop.Value })
        }
    }

    if ($notInstalled.Count -eq 0) {
        Write-Host "All tracked apps appear to be installed." -ForegroundColor Green
        return
    }

    $toInstall = if ($All) {
        $notInstalled
    } else {
        $lines = @($notInstalled | ForEach-Object { $_.appName })
        $selected = @($lines | fzf --multi --reverse --height=40% --header="Tab: multi-select, esc: cancel" --prompt="install> ")
        if ($selected.Count -eq 0) { return }
        $picked = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($s in $selected) {
            $idx = [array]::IndexOf($lines, $s)
            if ($idx -ge 0) { $picked.Add($notInstalled[$idx]) }
        }
        $picked
    }

    foreach ($item in $toInstall) {
        Write-Host ""
        $null = _InstallTrackedApp $item.appName $item.app $proxyUrl $config
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
    "install" { _Install }
    "backup"  { _Backup }
    "restore" { _Restore }
    "proxy"   { _Proxy }
    default {
        Write-Host ">GitGet" -ForegroundColor Blue
        Write-Host "Usage: gitget <command>" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Commands:"
        Write-Host "  add         - Track a repo and install it (add owner/repo [-InstallType kind] [-NoInstall])"
        Write-Host "  configure   - Show/set an app's rules (configure name [options])"
        Write-Host "  ls          - List tracked apps"
        Write-Host "  rm          - Remove tracked apps (rm name | -All) [-Purge]"
        Write-Host "  check       - Check for updates (-Force skips cache)"
        Write-Host "  update      - Install available updates (update [name] [-All] [-Force] [-Reinstall])"
        Write-Host "  install     - Install apps that are missing (install [name] [-All])"
        Write-Host "  backup      - Back up the config"
        Write-Host "  restore     - Restore the config from a file"
        Write-Host "  proxy       - Set/show/clear the SOCKS5 proxy (proxy host:port)"
        Write-Host ""
    }
}
