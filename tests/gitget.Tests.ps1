# Offline regression suite: loads functions only; never dispatches the CLI,
# accesses the network, writes the real config, or starts real installers.
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '..\tools\gitget.ps1'
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    ForEach-Object { Invoke-Expression $_.Extent.Text }
$fetchReleases = ${function:_GetReleases}
$readCache = ${function:_ReadCache}
$detectInstalled = ${function:_GetInstalledVersion}
$selectAsset = ${function:_SelectAsset}
$versionFromMetadata = ${function:_GetVersionFromFileMetadata}
$testPath = ${function:Test-Path}
$script:passed = 0
function Assert($condition, $message) {
    if (-not $condition) { throw $message }
    $script:passed++
}
function AssertThrows($action, $message) {
    $threw = $false
    try { & $action | Out-Null } catch { $threw = $true }
    Assert $threw $message
}
function Release($tag, $asset, $prerelease = $false, $name = '') {
    [pscustomobject]@{ tag_name=$tag; name=$name; prerelease=$prerelease; assets=@([pscustomobject]@{name=$asset;size=1}) }
}
function App($family = '') {
    [pscustomobject]@{ repo='example/app'; tag_family=$family; current_version='1.0'; current_asset='old.exe'; pattern='*old.exe'; install_dir='unused'; last_checked=$null }
}
function _GetReleases { return $script:releases }
function _GetLatestRelease { throw 'Unexpected latest-release fallback' }

$script:releases = @((Release '26.04' '7z2604-x64.exe'), (Release '26.03' '7z2603-x64.exe'))
$app = App
$app.current_asset = '7z2603-x64.exe'; $app.pattern = '*7z2603*x64.exe'
Assert ((_GetTrackedRelease 'test' $app).tag_name -eq '26.04') 'Versioned filename pinned an old release'
$app.PSObject.Properties.Remove('tag_family')
Assert ((_GetTrackedRelease 'test' $app).tag_name -eq '26.04') 'Legacy family inference pinned an old release'
$script:releases = @((Release 'android-v5.0' 'android.exe'), (Release 'v4.0' 'new.exe' $true), (Release 'v3.0' 'source.zip'), (Release 'v2.0' 'renamed.msi'), (Release 'v1.0' 'old.exe'))
$app = App 'v'
Assert ((_GetTrackedRelease 'test' $app).tag_name -eq 'v2.0') 'Platform, prerelease, or installer filtering failed'
$app.PSObject.Properties.Remove('tag_family')
Assert ((_GetTrackedRelease 'test' $app).tag_name -eq 'v2.0') 'Legacy inference switched platform'
$app.current_asset = 'missing.exe'; $app.pattern = '*missing*'
AssertThrows { _GetTrackedRelease 'test' $app } 'Ambiguous legacy release lines were silently selected'
$app = App 'missing'
AssertThrows { _GetTrackedRelease 'test' $app } 'Missing release family switched channel'
$app | Add-Member tag_pattern 'v*'
Assert ((_GetTrackedRelease 'test' $app).tag_name -eq 'v2.0') 'Explicit tag filter did not override family'
$app | Add-Member include_prerelease $true
Assert ((_GetTrackedRelease 'test' $app).tag_name -eq 'v4.0') 'Prerelease opt-in failed'
$script:releases = @((Release 'v3.0' 'app.exe' $false 'v3.0 (Experimental)'), (Release 'v2.0' 'app.exe' $false 'v2.0 (Stable)'))
Assert ((_GetReleaseKey $script:releases[0]) -eq 'v [experimental]') 'Custom channel was lost'
Assert ((_GetTrackedRelease 'test' (App 'v [stable]')).tag_name -eq 'v2.0') 'Stable channel changed'
$app = App
$app | Add-Member release_name_pattern '*(Experimental)'
Assert ((_GetTrackedRelease 'test' $app).tag_name -eq 'v3.0') 'Custom release-name filter failed'

# Brave channels can all be marked non-prerelease and share numeric tag families.
$script:releases = @(
    (Release 'v1.99.24' 'BraveBrowserStandaloneNightlySilentSetup.exe' $false 'Nightly v1.99.24 (Chromium 155.0.8059.40)'),
    (Release 'v1.98.52' 'BraveBrowserStandaloneBetaSilentSetup.exe' $false 'Beta v1.98.52 (Chromium 155.0.8059.40)'),
    (Release 'v1.97.56' 'BraveBrowserStandaloneSilentSetup.exe' $false 'Release v1.97.56 (Chromium 155.0.8059.40)'),
    (Release 'v1.96.61' 'BraveBrowserStandaloneSilentSetup.exe' $false 'Release v1.96.61 (Chromium 154.0.8037.98)')
)
$app = App
$app.PSObject.Properties.Remove('tag_family')
$app.current_asset = 'BraveBrowserStandaloneSilentSetup.exe'
$app.pattern = '*BraveBrowserStandaloneSilentSetup.exe'
Assert ((_GetReleaseKey $script:releases[0]) -eq 'v [nightly]') 'Brave nightly channel was lost'
Assert ((_GetReleaseKey $script:releases[2]) -eq (_GetReleaseKey $script:releases[3])) 'Chromium metadata split the Brave stable line'
Assert ((_GetReleaseLines $script:releases).Count -eq 3) 'Brave channels were grouped together'
Assert ((_GetTrackedRelease 'brave-browser' $app).tag_name -eq 'v1.97.56') 'Legacy Brave entry switched to nightly'
$app = App 'v [release]'
Assert ((_GetTrackedRelease 'brave-browser' $app).tag_name -eq 'v1.97.56') 'Pinned Brave stable line switched channel'
$app = App 'v [nightly]'
Assert ((_GetTrackedRelease 'brave-browser' $app).tag_name -eq 'v1.99.24') 'Explicitly tracked Brave nightly line was lost'

Assert (-not (_TestSameVersion '1.2.3' '2.3')) 'A meaningful leading version segment was discarded'
Assert (_TestSameVersion 'v26.03' '26.3.0') 'Numeric formatting or trailing zero compatibility failed'
Assert (_TestSameVersion 'auth-v4.4.25+1072' '4.4.25') 'Prefix/build normalization failed'
Assert ((_CompareVersions '1.10' '1.9') -gt 0) 'Numeric version ordering failed'
Assert ((_CompareVersions '1.0.0' '1.0.0-rc.2') -gt 0) 'Final release ranked below prerelease'
Assert ((_CompareVersions '1.0.0-rc.10' '1.0.0-rc.2') -gt 0) 'Numeric prerelease ordering failed'
Assert ((_CompareVersions '1.0.0-alpha' '1.0.0-beta') -lt 0) 'Text prerelease ordering failed'
Assert ((_CompareVersions '1.0.0-1' '1.0.0-alpha') -lt 0) 'Numeric prerelease identifier ordering failed'
Assert (-not (_TestIsNewer '15.0.21' '15.0.24')) 'Self-updated application was downgraded'
Assert ((_CompareVersions '2026-10-06' '2026-09-04') -gt 0) 'ISO date ordering failed'
AssertThrows { _TestIsNewer '1.0preview' '1.0custom' } 'Opaque versions were silently compared'
Assert (_TestIsNewer 'v1.0' $null) 'Uninstalled app cannot be installed'
Assert ((_ExtractConfiguredVersion '123.1.96.61' '^\d+\.(.+)$') -eq '1.96.61') 'Configured version extraction failed'
AssertThrows { _ExtractConfiguredVersion 'wrong' '^(\d+)$' } 'Invalid version extraction was silently accepted'
Assert (_TestDisplayNameMatch '7-Zip 26.03 (x64)' '7zip') 'Punctuation-insensitive full-name match failed'
Assert (_TestDisplayNameMatch 'Lenovo Legion Toolkit' 'LenovoLegionToolkit') 'Spaced full-name match failed'
Assert (-not (_TestDisplayNameMatch 'Other Toolkit' 'LenovoLegionToolkit')) 'Shared token matched an unrelated app'
Assert (-not (_TestDisplayNameMatch 'foobar' 'foo')) 'Partial app name matched'

$script:registry = @([pscustomobject]@{DisplayName='Linker version 1.0.4';DisplayVersion='1.0.4'})
function Get-ItemProperty { $script:registry }
$app = App
$app | Add-Member display_name_pattern 'Linker version *'
Assert ((_GetVersionFromRegistry $app 'test') -eq '1.0.4') 'Versioned display-name pattern failed'
$script:registry += [pscustomobject]@{DisplayName='Linker version 2.0';DisplayVersion='2.0'}
AssertThrows { _GetVersionFromRegistry $app 'test' } 'Ambiguous installed display names were accepted'
$app = App
$app | Add-Member display_name 'Linker version 1.0.4'
Assert ((_GetVersionFromRegistry $app 'test') -eq '1.0.4') 'Exact display name did not disambiguate'
$script:registry = @([pscustomobject]@{DisplayName='Other App';DisplayVersion='9.0'})
$app = App
$app.repo = 'example/UniqueProduct'
Assert ($null -eq (_GetVersionFromRegistry $app 'UniqueProduct')) 'Unrelated registry entry matched'

# Fixed-width winget output must exclude Id and Source columns from values.
function Get-Command { $true }
function _InvokeWithTimeout { @('Name                 Id                   Version    Source', '---------------------------------------------------------------', 'Example App          Example.App          1.2.3      winget') -join "`n" }
$app = App
$app | Add-Member display_name 'Example App'
Assert ((_GetVersionFromWinget $app 'test') -eq '1.2.3') 'Winget source column leaked into version'

# Explicit version commands are the only executables launched for detection.
function _FindInstalledExe { 'fake.exe' }
function _GetVersionFromFileMetadata { '1.2.3' }
function _GetVersionFromCommand { throw 'An unconfigured executable was launched' }
Assert ((& $detectInstalled 'test' (App)).source -eq 'file metadata') 'Automatic detection launched an executable'

$assets = @([pscustomobject]@{name='app-x64.exe'}, [pscustomobject]@{name='app-arm64.exe'}, [pscustomobject]@{name='source.zip'})
function _GetNativeArch { 'x64' }
Assert ((_SelectAsset $assets '*x64.exe').name -eq 'app-x64.exe') 'Architecture/pattern matching failed'
Assert ($null -eq (_SelectAsset $assets '*old.exe')) 'Pattern miss silently selected another asset'
Assert ($null -eq (_SelectAsset @([pscustomobject]@{name='source.zip'}) '*')) 'Archive offered as installer'
Assert ($null -eq (_SelectAsset @([pscustomobject]@{name='app-arm64.exe'}) '*')) 'Wrong architecture auto-selected'
Assert ($null -eq (_SelectAsset @([pscustomobject]@{name='a-x64.exe'},[pscustomobject]@{name='b-x64.exe'}) '*')) 'Ambiguous installer auto-selected'
function _SelectAssetFromList($Candidates, $RecommendedName, $Prompt) { $Candidates | Where-Object name -eq 'app-x64.exe' }
Assert ((_SelectAsset $assets '*old.exe' -Interactive).name -eq 'app-x64.exe') 'Renamed installer cannot be explicitly selected'

# Check failures must be isolated rather than returning Up to date.
$script:releases = @((Release 'v2.0' 'new.exe'))
function _GetInstalledVersion { @{version='1.0';source='registry'} }
$app = App 'v'
Assert ((_CheckOne 'test' $app).hasUpdate) 'Check did not detect an update'
$app | Add-Member installed_version_regex '^not-a-version$'
Assert ($null -eq (_CheckOne 'test' $app)) 'Invalid installed version did not produce an inconclusive check'

# The same problem for many apps is said once, not once per app.
$script:checkErrors = @(
    [pscustomobject]@{ app = 'one'; reason = 'boom' }
    [pscustomobject]@{ app = 'two'; reason = 'boom' }
    [pscustomobject]@{ app = 'three'; reason = 'other' }
)
$errorOutput = _WriteCheckErrors 6>&1 | Out-String
Assert ($errorOutput -match '2 check\(s\) failed: boom') 'Repeated check errors were not said once'
Assert ($errorOutput -match 'three error: other') 'A single check error lost the app name'
Assert (($errorOutput -split "`n" | Where-Object { $_.Trim() }).Count -eq 2) 'Check errors were said more than once'

# Installer outcomes never launch a process or delete files in this suite.
$script:exitCode = 1
function Start-Process {
    $proc = [pscustomobject]@{ ExitCode = $script:exitCode }
    $proc | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { }
    $proc
}
function Remove-Item { }
function Add-AppxPackage { if ($script:exitCode) { throw 'Mock install failure' } }
Assert (-not (_InstallDownloadedAsset 'fake.exe')) 'Failed EXE install reported success'
$script:exitCode = 0
Assert (_InstallDownloadedAsset 'fake.exe') 'Successful EXE install reported failure'
$script:exitCode = 3010
Assert (_InstallDownloadedAsset 'fake.msi') 'MSI reboot-required success reported failure'
$script:exitCode = 1
Assert (-not (_InstallDownloadedAsset 'fake.msix')) 'Failed MSIX install reported success'
$script:exitCode = 0

# MSI installs pin the install context to the one the existing copy uses,
# and always ask msiexec for a verbose log next to the package.
$script:installArgs = @()
function Start-Process {
    $idx = [array]::IndexOf($args, '-ArgumentList')
    if ($idx -ge 0) { $script:installArgs = @($args[$idx + 1]) }
    $proc = [pscustomobject]@{ ExitCode = $script:exitCode }
    $proc | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { }
    $proc
}
function _GetMsiInstallContext { 'machine' }
Assert (_InstallDownloadedAsset 'fake.msi') 'Per-machine MSI install reported failure'
Assert ($script:installArgs -contains 'ALLUSERS=1') 'MSI did not pin the per-machine context'
Assert (($script:installArgs -contains '/l*v') -and (@($script:installArgs | Where-Object { $_ -match '^".*\.log"$' }).Count -gt 0)) 'MSI did not request a verbose log'
function _GetMsiInstallContext { 'user' }
Assert (_InstallDownloadedAsset 'fake.msi') 'Per-user MSI install reported failure'
Assert (($script:installArgs -contains 'ALLUSERS=2') -and ($script:installArgs -contains 'MSIINSTALLPERUSER=1')) 'A per-user MSI was not kept per-user'
Assert (-not ($script:installArgs -contains 'ALLUSERS=1')) 'A per-user MSI was forced per-machine'
function _GetMsiInstallContext { $null }
Assert (_InstallDownloadedAsset 'fake.msi') 'New-install MSI reported failure'
Assert ($script:installArgs -contains 'ALLUSERS=1') 'New MSI install did not use the per-machine default'
$script:exitCode = 3049
Assert (-not (_InstallDownloadedAsset 'fake.msi')) 'Failed MSI install reported success'

# The compressed form the Installer registry uses ties the UpgradeCode of a
# package to the installed copies; both forms below were taken from the hive.
Assert ((_SquishMsiGuid '{931A2CF0-2404-45EA-82F5-345735AE6A90}') -eq '0FC2A1394042AE54285F437553EAA609') 'Compressed product code form mismatch'
Assert ((_SquishMsiGuid '{90160000-008C-0000-1000-0000000FF1CE}') -eq '00006109C80000000100000000F01FEC') 'Compressed GUID byte order mismatch'
Assert (-not (_SquishMsiGuid 'not-a-guid')) 'A malformed GUID produced a compressed code'
Assert (-not (_SquishMsiGuid $null)) 'A missing GUID produced a compressed code'

# A retry reuses the kept download of a failed install when it is complete,
# replaces a truncated one, and downloads fresh when nothing is here.
$reuseDir = Join-Path $env:TEMP 'gitget-tests-reuse'
New-Item -ItemType Directory -Force -Path $reuseDir | Out-Null
$reuseName = 'app-1.0-x64.msi'
$reuseFile = Join-Path $reuseDir $reuseName
$reuseAsset = [pscustomobject]@{ name = $reuseName; size = 1000; browser_download_url = 'unused' }
function Invoke-WebRequest { $script:webRequestRan = $true }
$script:webRequestRan = $false
Remove-Item $reuseFile -Force -ErrorAction SilentlyContinue
Assert ((_SaveAsset $reuseAsset $reuseDir $null) -eq $reuseFile) 'Fresh download returned the wrong path'
Assert $script:webRequestRan 'No download started for a missing file'

$script:webRequestRan = $false
[IO.File]::WriteAllBytes($reuseFile, [byte[]]::new(1000))
Assert ((_SaveAsset $reuseAsset $reuseDir $null) -eq $reuseFile) 'Kept download was not reused'
Assert (-not $script:webRequestRan) 'A complete kept download was fetched again'

$script:webRequestRan = $false
[IO.File]::WriteAllBytes($reuseFile, [byte[]]::new(500))
Assert ((_SaveAsset $reuseAsset $reuseDir $null) -eq $reuseFile) 'Interrupted download was not replaced'
Assert $script:webRequestRan 'A truncated kept download was not replaced'
Remove-Item $reuseDir -Recurse -Force -ErrorAction SilentlyContinue

# Update must not save the new version after failed installation.
$script:app = App 'v'
$script:config = [pscustomobject]@{apps=[pscustomobject]@{test=$script:app}}
$script:saves = 0
function _GetConfig { $script:config }
function _SaveConfig { $script:saves++ }
function _ResolveProxy { $null }
function _SaveAsset { 'fake.exe' }
function Test-Path { $false }
function _SelectAsset { [pscustomobject]@{name='new.exe'} }
$Target = 'test'; $All = $true; $Force = $false
_Update
Assert ($script:app.current_version -eq '1.0' -and $script:saves -eq 0) 'Failed install advanced saved version'
$script:exitCode = 0
_Update
Assert ($script:app.current_version -eq 'v2.0' -and $script:saves -eq 1) 'Successful install did not save version'
$script:app.current_version = '1.0'
$script:app.pattern = '*custom*x64.exe'
$script:app.PSObject.Properties.Remove('pattern_explicit')
_Update
Assert ($script:app.pattern -eq '*custom*x64.exe') 'Legacy custom installer pattern was overwritten'
$script:app | Add-Member pattern_explicit $true
$script:app.pattern = '*explicit*.msi'
$script:app.current_version = '1.0'
_Update
Assert ($script:app.pattern -eq '*explicit*.msi') 'Explicit installer pattern was overwritten'
$script:app.pattern = '*new.exe'

# A payload that was deleted is put back even when the release is the same.
$script:app.current_version = 'v2.0'
$script:app.current_asset = 'new.exe'
$script:saves = 0
function _GetInstalledVersion { @{ version = $null; source = 'missing' } }
_Update
Assert ($script:saves -eq 1) 'A missing payload was not reinstalled'
function _GetInstalledVersion { @{version='1.0';source='registry'} }

# Configure only modifies explicitly supplied settings and validates regexes.
$script:PSBoundParameters.Clear()
$script:PSBoundParameters.Add('TagPattern', 'desktop-v*')
$script:PSBoundParameters.Add('InstalledVersionRegex', '^\d+\.(.+)$')
$script:PSBoundParameters.Add('IncludePrerelease', $false)
_Configure | Out-Null
Assert ($script:app.tag_pattern -eq 'desktop-v*' -and -not $script:app.include_prerelease) 'Configure did not save settings'
Assert ($script:app.pattern -eq '*new.exe') 'Configure changed unspecified settings'

# Configurable history limits page the API and reuse cache; no real network.
$script:apiCalls = 0
$script:cache = @{}
function _ReadCache($Repo, $Endpoint) { $script:cache[$Endpoint] }
function _WriteCache($Repo, $Endpoint, $Data) { $script:cache[$Endpoint] = $Data }
function _InvokeGitHubApi($Url) {
    $script:apiCalls++
    $page = [int]([regex]::Match($Url, 'page=(\d+)$').Groups[1].Value)
    $length = if ($page -lt 3) { 100 } else { 5 }
    1..$length | ForEach-Object { Release "v$page.$_" 'app.exe' }
}
$history = @(& $fetchReleases 'example/app' 205)
Assert ($history.Count -eq 205 -and $script:apiCalls -eq 3) 'Release history pagination failed'
$history = @(& $fetchReleases 'example/app' 205)
Assert ($history.Count -eq 205 -and $script:apiCalls -eq 3) 'Paged history cache was ignored'
$history = @(& $fetchReleases 'example/app' 205 -Force)
Assert ($history.Count -eq 205 -and $script:apiCalls -eq 6) 'Force did not bypass paged cache'

# An expired cache file is kept until a refresh worked, and a failing API
# falls back to it instead of losing the release data.
$CacheDir = Join-Path ([System.IO.Path]::GetTempPath()) ("gitget-cache-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
$cachePath = _GetCachePath 'example' 'endpoint'
Set-Content -Path $cachePath -Value '{"endpoint":"endpoint","cached_at":"2000-01-01T00:00:00.0000000Z","data":[1]}'
Set-Item function:Test-Path $testPath
Assert ($null -eq (& $readCache 'example' 'endpoint')) 'An expired cache was used as if it were fresh'
Assert ($null -ne (& $readCache 'example' 'endpoint' -AllowStale)) 'An expired cache could not be used'
Assert (Test-Path $cachePath) 'The expired cache file was deleted before a refresh worked'
function Test-Path { $false }
$script:cache = @{}
function _ReadCache($Repo, $Endpoint, [switch]$AllowStale) {
    if ($AllowStale) { return $script:cache[$Endpoint] }
    return $null
}
function _InvokeGitHubApi($Url) { throw 'GitHub API rate limit hit' }
$script:cache['https://api.github.com/repos/example/app/releases?per_page=40'] = @((Release 'v1.0' 'app.exe'))
$staleReleases = @(& $fetchReleases 'example/app' 40)
Assert ($staleReleases.Count -eq 1 -and $staleReleases[0].tag_name -eq 'v1.0') 'A failing API threw away the cached releases'
Assert ($script:cache['https://api.github.com/repos/example/app/releases?per_page=40'].Count -eq 1) 'Stale data was written back as fresh'
Microsoft.PowerShell.Management\Remove-Item -Path $CacheDir -Recurse -Force -ErrorAction SilentlyContinue

# --- portable payloads and archives ---------------------------------------
function ReleaseAssets($tag, $assets, $prerelease = $false) {
    [pscustomobject]@{ tag_name=$tag; name=$tag; prerelease=$prerelease; assets=@($assets | ForEach-Object { [pscustomobject]@{name=$_;size=1} }) }
}
Assert (_TestIsPortableAsset 'bat.exe') 'A bare program was not recognised'
Assert (_TestIsPortableAsset 'yt-dlp.exe') 'A bare program was not recognised'
Assert (-not (_TestIsPortableAsset '7z2604-x64.exe')) 'A self-extracting installer was taken for a program'
Assert (-not (_TestIsPortableAsset 'AppSetup.exe')) 'A setup executable was taken for a program'
Assert (_TestLooksLikeInstaller '7z2604-x64.exe') 'A versioned architecture build was not seen as an installer'
Assert (-not (_TestLooksLikeInstaller 'yt-dlp_x86.exe')) 'An architecture suffix was read as a version'
Assert (_TestIsArchiveAsset 'bat-v0.24.0.zip') 'A zip was not recognised as an archive'
Assert (_TestIsArchiveAsset 'v0.24.0.tar.gz') 'A tarball was not recognised as an archive'
Assert (-not (_TestIsArchiveAsset 'bat.exe')) 'A program was taken for an archive'
Assert (_TestIsSourceAsset 'bat-source.tar.gz') 'A source archive was not recognised'
Assert (_TestIsWindowsAsset 'topgrade-v17.14.1-x86_64-pc-windows-msvc.zip') 'A Windows build was not recognised'
Assert (_TestIsWindowsAsset 'node-v20.0.0-win-x64.zip') 'A Windows build was not recognised'
Assert (_TestIsWindowsAsset 'plain-build.zip') 'A build without a platform marker was rejected'
Assert (-not (_TestIsWindowsAsset 'topgrade-v17.14.1-x86_64-apple-darwin.tar.gz')) 'A macOS build was taken for a Windows one'
Assert (-not (_TestIsWindowsAsset 'topgrade-v17.14.1-x86_64-unknown-linux-gnu.tar.gz')) 'A Linux build was taken for a Windows one'
Assert (-not (_TestIsWindowsAsset 'topgrade-v17.14.1-aarch64-unknown-freebsd.tar.gz')) 'A FreeBSD build was taken for a Windows one'
Assert ((_GetInstallType (App)) -eq 'installer') 'Entries without a kind must stay installers'
$portableApp = App
$portableApp | Add-Member install_type 'portable'
Assert ((_GetInstallType $portableApp) -eq 'portable') 'The install kind was lost'

$kinds = @(_GetInstallKindCandidates @(ReleaseAssets 'v1.0' @('bat-v1.0-x86_64-pc-windows-msvc.zip', 'v1.0.tar.gz')) | ForEach-Object { $_.kind })
Assert (($kinds -join ',') -eq 'archive') "Kind discovery failed: $($kinds -join ',')"
# A plain .exe is ambiguous - both kinds are offered, the likely one first.
$kinds = @(_GetInstallKindCandidates @(ReleaseAssets '2026.10.21' @('yt-dlp.exe', 'yt-dlp_x86.exe')) | ForEach-Object { $_.kind })
Assert (($kinds -join ',') -eq 'portable,installer') "Kind discovery failed: $($kinds -join ',')"
# An installer-like program makes the installer kind the recommendation.
$kinds = @(_GetInstallKindCandidates @(ReleaseAssets '24.08' @('7z2408-x64.exe', '7z2408-x64.msi')) | ForEach-Object { $_.kind })
Assert (($kinds -join ',') -eq 'installer') "Kind discovery failed: $($kinds -join ',')"

# A release with one build per platform must only offer the Windows one.
$platforms = @(
    'topgrade-v17.14.1-x86_64-apple-darwin.tar.gz',
    'topgrade-v17.14.1-x86_64-unknown-openbsd.tar.gz',
    'topgrade-v17.14.1-x86_64-unknown-linux-mus1.tar.gz',
    'topgrade-v17.14.1-x86_64-unknown-linux-gnu.tar.gz',
    'topgrade-v17.14.1-x86_64-unknown-freebsd.tar.gz',
    'topgrade-v17.14.1-x86_64-pc-windows-msvc.zip',
    'topgrade-v17.14.1-armv7-unknown-linux-gnueabihf.tar.gz',
    'topgrade-v17.14.1-aarch64-apple-darwin.tar.gz'
)
$release = ReleaseAssets 'v17.14.1' $platforms
$kinds = @(_GetInstallKindCandidates @($release))
Assert (($kinds | ForEach-Object { $_.kind }) -join ',' -eq 'archive') 'The wrong kind was offered for a multi-platform release'
Assert (($kinds[0].examples -join ',') -eq 'topgrade-v17.14.1-x86_64-pc-windows-msvc.zip') 'A foreign platform was offered as an example'
Assert ((& $selectAsset $release.assets '' -InstallType 'archive').name -eq 'topgrade-v17.14.1-x86_64-pc-windows-msvc.zip') 'A foreign platform was selected'

$script:releases = @(ReleaseAssets 'v2.0' @('bat-v2.0-x86_64-pc-windows-msvc.zip'))
$app = App 'v'
$app | Add-Member install_type 'archive'
Assert ((_GetTrackedRelease 'bat' $app).tag_name -eq 'v2.0') 'An archive release was not tracked'
$app = App 'v'
# A release that ships another kind is still the release to track - the kind
# is switched and stored when the asset is picked.
Assert ((_GetTrackedRelease 'bat' $app).tag_name -eq 'v2.0') 'A zip-only release was not tracked'

$assets = @([pscustomobject]@{name='yt-dlp.exe'}, [pscustomobject]@{name='yt-dlp.zip'})
Assert ((& $selectAsset $assets '*' -InstallType 'portable').name -eq 'yt-dlp.exe') 'The portable kind selected the wrong asset'
Assert ($null -eq (& $selectAsset @([pscustomobject]@{name='yt-dlp.zip'}) '*' -InstallType 'portable')) 'The portable kind selected an archive'
Assert ((& $selectAsset $assets '*' -InstallType 'archive').name -eq 'yt-dlp.zip') 'The archive kind selected the wrong asset'

# --- the recorded state is the primary version source ----------------------
# The metadata probe is mocked earlier in this suite - restore the real one.
Set-Item function:_GetVersionFromFileMetadata $versionFromMetadata
$tmp = Join-Path $env:TEMP ("gitget-tests-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$prog = Join-Path $tmp 'prog.exe'
Set-Content -LiteralPath $prog -Value 'payload'
$hash = (Get-FileHash -LiteralPath $prog -Algorithm SHA256).Hash.ToLower()
$portable = [pscustomobject]@{ repo='example/app'; install_type='portable'; current_version='1.0'; current_asset='prog.exe'; pattern='*prog.exe'; install_dir=$tmp; bin_dir=$tmp }
$portable | Add-Member installed ([pscustomobject]@{ version='1.0'; asset='prog.exe'; path=$prog; sha256=$hash; at='now' })
$det = & $detectInstalled 'app' $portable
Assert ($det.source -eq 'state') 'The recorded state was not used'
Assert ($det.version -eq '1.0') 'The recorded version was not returned'

# A copy that changed on disk cannot be verified - it must not be reported as
# the recorded version either.
Set-Content -LiteralPath $prog -Value 'changed'
$det = & $detectInstalled 'app' $portable
Assert ($det.source -eq 'modified') 'A changed copy was not reported as unverifiable'
Assert ($null -eq $det.version) 'A changed copy still produced a version'

# A payload that is gone is not installed any more.
[System.IO.File]::Delete($prog)
$det = & $detectInstalled 'app' $portable
Assert ($det.source -eq 'missing') 'A removed payload was not reported as missing'

# --- payload install: unpack, flatten, record the state --------------------
# Test-Path is mocked earlier in this suite - restore the real cmdlet, the
# archive module needs it to prepare its destination.
Set-Item function:Test-Path $testPath
New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'src\pkg') | Out-Null
Set-Content -LiteralPath (Join-Path $tmp 'src\pkg\prog.exe') -Value 'payload'
$archive = Join-Path $tmp 'prog-1.0.zip'
Compress-Archive -Path (Join-Path $tmp 'src\*') -DestinationPath $archive -Force
$binDir = Join-Path $tmp 'bin'
$exe = _InstallPortablePayload $archive $binDir 'prog'
Assert ($exe -and (Test-Path -LiteralPath $exe)) 'The archive payload was not unpacked'
Assert (Test-Path -LiteralPath (Join-Path $binDir 'prog.exe')) 'The archive was not flattened'
$app = [pscustomobject]@{ repo='example/app'; install_type='archive'; current_version='1.0'; current_asset='old.zip'; pattern='*prog*.zip'; install_dir=(Join-Path $tmp 'downloads'); bin_dir=$binDir }
_SetInstallState $app '1.0' 'prog-1.0.zip' $exe
Assert ($app.installed.version -eq '1.0') 'The install state was not recorded'
Assert ($app.installed.sha256 -eq (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLower()) 'The install state has no usable hash'
[System.IO.Directory]::Delete($tmp, $true)

# --- a changed copy must never be overwritten by a check --------------------
$script:releases = @((Release 'v2.0' 'new.exe'))
function _GetInstalledVersion { @{ version = $null; source = 'modified' } }
$app = App 'v'
$app | Add-Member install_type 'portable'
$result = _CheckOne 'test' $app $null
Assert ($null -ne $result) 'A changed copy produced no check result'
Assert (-not $result.hasUpdate) 'A changed copy was reported as updatable'
Assert ($result.modified) 'A changed copy was not flagged as changed'

function _GetInstalledVersion { @{ version = '1.0'; source = 'state' } }
$app = App 'v'
$app | Add-Member install_type 'portable'
$result = _CheckOne 'test' $app $null
Assert ($result.hasUpdate) 'A newer release was not detected for a portable app'

# --- adding an app installs it unless it is already there ------------------
$DownloadsDir = Join-Path $env:TEMP 'gitget-tests-downloads'
$AppsDir = Join-Path $env:TEMP 'gitget-tests-apps'
$SharedBinDir = Join-Path $env:TEMP 'gitget-tests-shared-bin'
$Target = 'example/app'
$Name = 'testapp'
$InstallType = 'installer'
$CurrentVersion = $null
$NoInstall = $false
$BinDir = $null
$script:releases = @((Release 'v1.0' 'app-x64.exe'))

# The user PATH must not be touched by the suite.
function _RegisterBinDir { }

$script:config = [pscustomobject]@{apps=[pscustomobject]@{}}
$script:saves = 0
function _GetInstalledVersion { @{ version = $null; source = 'unknown' } }
_Add
Assert ($script:saves -eq 2) 'Add did not install the payload'
Assert ($script:config.apps.testapp.current_version -eq 'v1.0') 'Add did not record the installed version'

# An app that is already installed is only tracked.
$script:config = [pscustomobject]@{apps=[pscustomobject]@{}}
$script:saves = 0
function _GetInstalledVersion { @{ version = '1.2.3'; source = 'registry' } }
_Add
Assert ($script:saves -eq 1) 'Add installed an app that is already installed'
Assert ($null -eq $script:config.apps.testapp.current_version) 'Add recorded a version for an app it did not install'

# -NoInstall only tracks.
$script:config = [pscustomobject]@{apps=[pscustomobject]@{}}
$script:saves = 0
$NoInstall = $true
function _GetInstalledVersion { @{ version = $null; source = 'unknown' } }
_Add
Assert ($script:saves -eq 1) 'Add installed the payload although -NoInstall was given'

# A portable payload is staged per app and placed in the shared bin dir.
# The real Remove-Item runs here - the standing no-op mock would block cleanup.
Microsoft.PowerShell.Management\Remove-Item function:\Remove-Item -ErrorAction SilentlyContinue
$script:fakePayload = Join-Path $env:TEMP 'gitget-tests-payload.exe'
Set-Content -LiteralPath $script:fakePayload -Value 'payload'
function _SaveAsset { $script:fakePayload }
$script:config = [pscustomobject]@{apps=[pscustomobject]@{}}
$script:saves = 0
$NoInstall = $false
$InstallType = 'portable'
$script:releases = @((Release 'v1.0' 'app.exe'))
_Add
$state = $script:config.apps.testapp.installed
Assert ($state -and $state.version -eq 'v1.0') 'Add did not record the portable install state'
Assert ($state -and (Test-Path -LiteralPath $state.path)) 'Add did not place the portable program'
Assert ($state -and $state.path.StartsWith($SharedBinDir)) 'The portable program was not placed in the shared bin dir'
Assert (-not (Test-Path -LiteralPath (Join-Path $AppsDir 'testapp'))) 'Add left the staging dir behind'
[System.IO.File]::Delete($script:fakePayload)
function Remove-Item { }

# Adding an app that is already tracked installs it when it is missing.
$script:tracked = [pscustomobject]@{
    repo            = 'example/app'
    tag_family      = 'v'
    current_version = $null
    current_asset   = 'app-x64.exe'
    pattern         = '*app*x64.exe'
    install_dir     = (Join-Path $DownloadsDir 'testapp')
    bin_dir         = $null
    install_type    = 'installer'
    last_checked    = $null
}
$script:config = [pscustomobject]@{ apps = [pscustomobject]@{ testapp = $script:tracked } }
$script:saves = 0
$InstallType = 'installer'
$CurrentVersion = $null
$Reinstall = $false
$script:releases = @((Release 'v1.0' 'app-x64.exe'))
function _GetInstalledVersion { @{ version = $null; source = 'missing' } }
_Add
Assert ($script:saves -eq 1) 'Add did not install an already tracked app that is missing'
Assert ($script:tracked.current_version -eq 'v1.0') 'Add did not record the installed version of a tracked app'

# An already tracked app that is installed is left alone.
$script:saves = 0
function _GetInstalledVersion { @{ version = '1.2.3'; source = 'registry' } }
_Add
Assert ($script:saves -eq 0) 'Add installed an already tracked app that is already installed'

# -NoInstall does not install an already tracked app either.
$script:saves = 0
$NoInstall = $true
function _GetInstalledVersion { @{ version = $null; source = 'missing' } }
_Add
Assert ($script:saves -eq 0) 'Add installed an already tracked app although -NoInstall was given'
$NoInstall = $false

# --- single-candidate selection never prompts ------------------------------
# Restore the real pickers - mocks earlier in the suite shadow them.
Set-Item function:_SelectAsset $selectAsset
# fzf must never be reached for these unambiguous cases.
function fzf { throw 'fzf must not run for a single-candidate selection' }

# One kind, one Windows archive asset -> chosen without a prompt.
$script:releases = @((Release 'v3.0' 'app-v3.0-x86_64-pc-windows-msvc.zip'))
$kinds = _GetInstallKindCandidates $script:releases
Assert (($kinds | ForEach-Object { $_.kind }) -join ',' -eq 'archive') 'A single archive kind was not discovered'
Assert ((_SelectInstallKind $kinds) -eq 'archive') 'A single kind prompted instead of being chosen'
Assert ((& $selectAsset $script:releases[0].assets '' -InstallType 'archive').name -eq 'app-v3.0-x86_64-pc-windows-msvc.zip') 'A single archive asset was not selected'

# A plain add records the archive kind, release and asset.
$script:config = [pscustomobject]@{ apps = [pscustomobject]@{} }
$script:saves = 0
$Target = 'example/app'
$Name = 'autoapp'
$InstallType = $null
$Pattern = $null
$CurrentVersion = $null
$NoInstall = $false
function _GetInstalledVersion { @{ version = $null; source = 'unknown' } }
function _InstallAppPayload { $true }
_Add
Assert ($script:config.apps.autoapp.install_type -eq 'archive') 'Add did not choose the archive kind'
Assert ($script:config.apps.autoapp.current_asset -eq 'app-v3.0-x86_64-pc-windows-msvc.zip') 'Add picked the wrong asset'
Assert ($script:saves -eq 2) 'Add did not install and save'
$InstallType = 'installer'

# --- rm removes tracking, and the files of a managed payload ----------------
# Remove the standing mocks so the real filesystem cmdlets run again.
Microsoft.PowerShell.Management\Remove-Item function:\Remove-Item -ErrorAction SilentlyContinue
Set-Item function:Test-Path $testPath
# The suite must not touch the real user PATH.
$script:unregistered = @()
function _UnregisterBinDir { $script:unregistered += $args[0] }
$All = $false
$purgeRoot = Join-Path $env:TEMP ('gitget-purge-' + [guid]::NewGuid().ToString('N'))
$purgeBin  = Join-Path $purgeRoot 'apps\testapp'
$purgeDl   = Join-Path $purgeRoot 'downloads\testapp'
function New-PurgeFiles {
    New-Item -ItemType Directory -Force -Path $purgeBin, $purgeDl | Out-Null
    Set-Content -LiteralPath (Join-Path $purgeBin 'testapp.exe') -Value 'x'
    Set-Content -LiteralPath (Join-Path $purgeDl 'testapp.zip') -Value 'x'
}
New-PurgeFiles

$script:config = [pscustomobject]@{ apps = [pscustomobject]@{
    testapp = [pscustomobject]@{ repo='example/app'; install_type='portable'; bin_dir=$purgeBin; install_dir=$purgeDl }
    keepapp = [pscustomobject]@{ repo='example/other'; install_type='installer'; bin_dir=$null; install_dir=$null }
} }
$script:saves = 0
$script:unregistered = @()
$Target = 'testapp'
$Purge  = $true
_Remove
Assert ($null -eq $script:config.apps.PSObject.Properties['testapp']) 'rm did not untrack the targeted app'
Assert ($null -ne $script:config.apps.PSObject.Properties['keepapp']) 'rm removed an app it was not asked to'
Assert (-not (Test-Path -LiteralPath $purgeBin)) 'rm -Purge left the payload directory behind'
Assert (-not (Test-Path -LiteralPath $purgeDl)) 'rm -Purge left the download directory behind'
Assert ($script:saves -eq 1) 'rm did not persist the config'
Assert ($script:unregistered -contains $purgeBin) 'rm did not drop the payload directory from the PATH'

# A portable payload belongs to gitget - removing the app removes its files.
New-PurgeFiles
$script:config = [pscustomobject]@{ apps = [pscustomobject]@{
    testapp = [pscustomobject]@{ repo='example/app'; install_type='portable'; bin_dir=$purgeBin; install_dir=$purgeDl }
} }
$script:saves = 0
$Purge = $false
_Remove
Assert ($null -eq $script:config.apps.PSObject.Properties['testapp']) 'rm did not untrack the app'
Assert (-not (Test-Path -LiteralPath $purgeBin)) 'rm left the payload files of a portable app behind'
Assert (-not (Test-Path -LiteralPath $purgeDl)) 'rm left the download files of a portable app behind'

# An installed program stays - only its leftovers go with -Purge.
New-PurgeFiles
$script:config = [pscustomobject]@{ apps = [pscustomobject]@{
    setupapp = [pscustomobject]@{ repo='example/setup'; install_type='installer'; bin_dir=$null; install_dir=$purgeDl }
} }
$script:saves = 0
$Target = 'setupapp'
_Remove
Assert ($null -eq $script:config.apps.PSObject.Properties['setupapp']) 'rm did not untrack the installed app'
Assert (Test-Path -LiteralPath $purgeDl) 'rm deleted the files of an installed program'
New-PurgeFiles
$script:config = [pscustomobject]@{ apps = [pscustomobject]@{
    setupapp = [pscustomobject]@{ repo='example/setup'; install_type='installer'; bin_dir=$null; install_dir=$purgeDl }
} }
$script:saves = 0
$Purge = $true
_Remove
Assert (-not (Test-Path -LiteralPath $purgeDl)) 'rm -Purge left the leftovers of an installed program behind'

# rm -All clears every tracked app without the picker - this is what reset uses.
New-PurgeFiles
$script:config = [pscustomobject]@{ apps = [pscustomobject]@{
    testapp = [pscustomobject]@{ repo='example/app'; install_type='portable'; bin_dir=$purgeBin; install_dir=$purgeDl
        installed = [pscustomobject]@{ path = (Join-Path $purgeBin 'bin\testapp.exe'); version='1.0' } }
    setupapp = [pscustomobject]@{ repo='example/setup'; install_type='installer'; bin_dir=$null; install_dir=$null }
} }
$script:saves = 0
$script:unregistered = @()
$Target = $null
$All = $true
_Remove
Assert ($null -eq $script:config.apps.PSObject.Properties['testapp']) 'rm -All left a managed app tracked'
Assert ($null -eq $script:config.apps.PSObject.Properties['setupapp']) 'rm -All left an installed app tracked'
Assert (-not (Test-Path -LiteralPath $purgeBin)) 'rm -All left the payload directory behind'
Assert ($script:saves -eq 1) 'rm -All did not persist the config'
Assert ($script:unregistered -contains (Join-Path $purgeBin 'bin')) 'rm -All did not drop the directory of the program from the PATH'
$All = $false

$Target = $null
[System.IO.Directory]::Delete($purgeRoot, $true)

# --- configure -BinDir moves the payload and re-registers the PATH ------------
$moveRoot = Join-Path $env:TEMP ('gitget-move-' + [guid]::NewGuid().ToString('N'))
$oldBin  = Join-Path $moveRoot 'apps\demo'
$newBin  = Join-Path $moveRoot 'elsewhere\demo'
New-Item -ItemType Directory -Path $oldBin -Force | Out-Null
Set-Content -LiteralPath (Join-Path $oldBin 'demo.exe') -Value 'x'

$script:config = [pscustomobject]@{ apps = [pscustomobject]@{ demo = [pscustomobject]@{
    repo='example/demo'; install_type='portable'; bin_dir=$oldBin
    installed = [pscustomobject]@{ path = (Join-Path $oldBin 'demo.exe'); version='1.0' }
} } }
$script:saves = 0
$script:registered = @()
$script:unregistered = @()
function _RegisterBinDir { $script:registered += $args[0] }
$Target = 'demo'
$script:PSBoundParameters.Clear()
$script:PSBoundParameters.Add('BinDir', $newBin)
_Configure | Out-Null
Assert (Test-Path -LiteralPath (Join-Path $newBin 'demo.exe')) 'configure -BinDir did not move the payload'
Assert (-not (Test-Path -LiteralPath $oldBin)) 'configure -BinDir left the old payload dir behind'
Assert ($script:config.apps.demo.installed.path -eq (Join-Path $newBin 'demo.exe')) 'configure -BinDir did not update the recorded program path'
Assert ($script:unregistered -contains $oldBin) 'configure -BinDir did not drop the old PATH entry'
Assert ($script:registered -contains $newBin) 'configure -BinDir did not register the new PATH entry'
$script:PSBoundParameters.Clear()
[System.IO.Directory]::Delete($moveRoot, $true)

# --- the picked asset and kind are remembered -------------------------------
# A derived pattern has to match the next release of the same program, or an
# update asks for the file again on every version.
Assert ((_NewAssetPattern 'gh_2.103.0_windows_amd64.msi') -eq '*gh*windows*amd64.msi*') 'Version glued to the name was not cut out'
Assert ((_NewAssetPattern 'qbittorrent_5.3.0_x64_setup.exe') -eq '*qbittorrent*x64*setup.exe*') 'Underscored name lost its shape'
Assert ((_NewAssetPattern '7z2605-x64.exe') -eq '*7z*x64.exe*') 'Build number was not cut out'
Assert ((_NewAssetPattern 'Bitwarden-Installer-2026.10.0.exe') -eq '*Bitwarden*Installer*.exe*') 'Trailing version broke the pattern'
Assert ((_NewAssetPattern 'bat-v0.26.1-x86_64-pc-windows-msvc.zip') -eq '*bat*x86*64*pc*windows*msvc.zip*') 'Archive name lost its shape'
Assert ((_NewAssetPattern 'keepawakeSetup.exe') -eq '*keepawakeSetup.exe*') 'Name without a version was changed'
Assert ('gh_2.104.0_windows_amd64.msi' -like (_NewAssetPattern 'gh_2.103.0_windows_amd64.msi')) 'Derived pattern does not match the next version'
Assert ('Bitwarden-Installer-2026.11.0.exe' -like (_NewAssetPattern 'Bitwarden-Installer-2026.10.0.exe')) 'Derived pattern does not match the next version'
Assert ('7z2606-x64.exe' -like (_NewAssetPattern '7z2605-x64.exe')) 'Derived pattern does not match the next version'

# A pattern gitget derived is replaced; one the user set is kept.
$autoApp = [pscustomobject]@{ current_asset = 'gh_2.103.0_windows_amd64.msi'; pattern = '*' }
Assert (_IsAutoPattern $autoApp) 'A derived pattern was not recognized'
Assert ((_GetEffectivePattern $autoApp) -eq '*gh*windows*amd64.msi*') 'A stale derived pattern was not rebuilt'
$flaggedApp = [pscustomobject]@{ current_asset = 'gh_2.103.0_windows_amd64.msi'; pattern = '*gh*windows*amd64.msi*'; pattern_explicit = $false }
Assert (_IsAutoPattern $flaggedApp) 'A pattern marked as derived was not recognized'
Assert ((_GetEffectivePattern $flaggedApp) -eq '*gh*windows*amd64.msi*') 'A derived pattern was not reused'
$explicitApp = [pscustomobject]@{ current_asset = 'gh_2.103.0_windows_amd64.msi'; pattern = '*gh*amd64*'; pattern_explicit = $true }
Assert (-not (_IsAutoPattern $explicitApp)) 'A pattern set by the user was treated as derived'
Assert ((_GetEffectivePattern $explicitApp) -eq '*gh*amd64*') 'A pattern set by the user was overwritten'
$legacyApp = [pscustomobject]@{ current_asset = 'Bitwarden-Installer-2026.10.0.exe'; pattern = '*Bitwarden*Installer' }
Assert (_IsAutoPattern $legacyApp) 'An old derived pattern was not recognized'
Assert ((_GetEffectivePattern $legacyApp) -eq '*Bitwarden*Installer*.exe*') 'An old derived pattern was not rebuilt'
$handApp = [pscustomobject]@{ current_asset = 'Bitwarden-Installer-2026.10.0.exe'; pattern = '*Bitwarden*' }
Assert (-not (_IsAutoPattern $handApp)) 'A hand-written pattern was treated as derived'
Assert ((_GetEffectivePattern $handApp) -eq '*Bitwarden*') 'A hand-written pattern was overwritten'

# A release can ship several files that match the pattern - the one that is
# the previous file with a new version is the one that is wanted, and it is
# picked without asking.
Set-Item function:_SelectAsset $selectAsset
Assert ((_GetFileShape 'Bitwarden-Installer-2026.10.0.exe') -eq 'Bitwarden|Installer|.exe') 'The shape of a file name was not computed'
Assert ((_GetFileShape 'qbittorrent_5.3.0_x64_setup.exe') -eq 'qbittorrent|x64|setup.exe') 'The shape of an underscored name was not computed'
$bwAssets = @(
    [pscustomobject]@{ name = 'Bitwarden-Installer-2027.11.1.exe'; size = 1 }
    [pscustomobject]@{ name = 'commercial-Bitwarden-Installer-2027.11.1.exe'; size = 1 }
)
$bwPicked = _SelectAsset $bwAssets (_NewAssetPattern 'Bitwarden-Installer-2026.10.0.exe') -Interactive -InstallType 'installer' -PreviousName 'Bitwarden-Installer-2026.10.0.exe'
Assert ($null -ne $bwPicked -and $bwPicked.name -eq 'Bitwarden-Installer-2027.11.1.exe') 'A file that is not the previous file was picked without asking'
$qbAssets = @(
    [pscustomobject]@{ name = 'qbittorrent_6.4.1_x64_setup.exe'; size = 1 }
    [pscustomobject]@{ name = 'qbittorrent_6.4.1_lt12_x64_setup.exe'; size = 1 }
)
$qbPicked = _SelectAsset $qbAssets (_NewAssetPattern 'qbittorrent_5.3.0_x64_setup.exe') -Interactive -InstallType 'installer' -PreviousName 'qbittorrent_5.3.0_x64_setup.exe'
Assert ($null -ne $qbPicked -and $qbPicked.name -eq 'qbittorrent_6.4.1_x64_setup.exe') 'A build with another name was picked without asking'
$checkPicked = _SelectAsset $bwAssets (_NewAssetPattern 'Bitwarden-Installer-2026.10.0.exe') -InstallType 'installer' -PreviousName 'Bitwarden-Installer-2026.10.0.exe'
Assert ($null -ne $checkPicked -and $checkPicked.name -eq 'Bitwarden-Installer-2027.11.1.exe') 'A check could not tell which file is the same one'
$otherPicked = _SelectAsset $qbAssets (_NewAssetPattern 'qbittorrent_5.3.0_x64_setup.exe') -InstallType 'installer'
Assert ($null -eq $otherPicked) 'Ambiguous files were silently chosen without the previous file'

# A release that drops the tracked kind switches to the kind it ships and
# remembers it, so the question is not asked again.
$switchApp = [pscustomobject]@{ current_asset = 'app.zip'; pattern = '*app*zip*'; install_type = 'archive' }
$archiveRelease = [pscustomobject]@{ tag_name = 'v2.0'; assets = @(
    [pscustomobject]@{ name = 'app-setup.exe'; size = 1 }
) }
$kind = _ResolveInstallType 'testapp' $switchApp $archiveRelease 'archive' $null
Assert ($kind -eq 'installer') 'The tracked kind was not switched to the one the release ships'
Assert ($switchApp.install_type -eq 'installer') 'The new kind was not stored'
Assert (-not $switchApp.PSObject.Properties['installed']) 'The install state of the old kind was kept'

# An update must not ask for the file again: the pattern is rebuilt from the
# asset that was installed last time.
$script:selectedPattern = $null
function _SelectAsset { $script:selectedPattern = $args[1]; [pscustomobject]@{ name = 'gh_2.104.0_windows_amd64.msi' } }
function _InstallAppPayload { $true }
$updateApp = [pscustomobject]@{ repo='example/app'; tag_family='v'; current_version='1.0'
    current_asset='gh_2.103.0_windows_amd64.msi'; pattern='*'; install_dir='unused'; last_checked=$null; install_type='installer' }
$script:config = [pscustomobject]@{apps=[pscustomobject]@{testapp=$updateApp}}
$script:saves = 0
$script:releases = @((Release 'v2.0' 'gh_2.104.0_windows_amd64.msi'))
$Target = 'testapp'; $All = $true
_Update
Assert ($script:selectedPattern -eq '*gh*windows*amd64.msi*') 'The update did not use the rebuilt pattern'

# A release that ships another kind switches to it and stores the choice.
$script:selectedPattern = $null
$switchUpdate = [pscustomobject]@{ repo='example/app'; tag_family='v'; current_version='1.0'
    current_asset='app-setup.exe'; pattern='*app*setup.exe*'; install_dir='unused'; last_checked=$null; install_type='installer' }
$script:config = [pscustomobject]@{apps=[pscustomobject]@{testapp=$switchUpdate}}
$script:saves = 0
$script:releases = @((Release 'v2.0' 'app-v2.0.zip'))
_Update
Assert ($switchUpdate.install_type -eq 'archive') 'The update did not switch to the kind the release ships'
Assert ($script:selectedPattern -eq '*') 'The update kept the file name of the old kind'

Write-Host "Passed $script:passed offline regression assertions." -ForegroundColor Green
