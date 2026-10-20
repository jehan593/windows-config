# Offline regression suite: loads functions only; never dispatches the CLI,
# accesses the network, writes the real config, or starts real installers.
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '..\tools\gitget.ps1'
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    ForEach-Object { Invoke-Expression $_.Extent.Text }
$InstallerExtensions = @('.exe', '.msi', '.msix', '.msixbundle')
$fetchReleases = ${function:_GetReleases}
$detectInstalled = ${function:_GetInstalledVersion}
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
function _SelectAssetFromList($Candidates, $RecommendedName) { $Candidates | Where-Object name -eq 'app-x64.exe' }
Assert ((_SelectAsset $assets '*old.exe' -Interactive).name -eq 'app-x64.exe') 'Renamed installer cannot be explicitly selected'

# Check failures must be isolated rather than returning Up to date.
$script:releases = @((Release 'v2.0' 'new.exe'))
function _GetInstalledVersion { @{version='1.0';source='registry'} }
$app = App 'v'
Assert ((_CheckOne 'test' $app).hasUpdate) 'Check did not detect an update'
$app | Add-Member installed_version_regex '^not-a-version$'
Assert ($null -eq (_CheckOne 'test' $app)) 'Invalid installed version did not produce an inconclusive check'

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
_Update
Assert ($script:app.pattern -eq '*custom*x64.exe') 'Legacy custom installer pattern was overwritten'
$script:app | Add-Member pattern_explicit $true
$script:app.pattern = '*explicit*.msi'
$script:app.current_version = '1.0'
_Update
Assert ($script:app.pattern -eq '*explicit*.msi') 'Explicit installer pattern was overwritten'
$script:app.pattern = '*new.exe'

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
Write-Host "Passed $script:passed offline regression assertions." -ForegroundColor Green
