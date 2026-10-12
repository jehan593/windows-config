# GitGet

Run `gitget add owner/repo`, `gitget check`, or `gitget update` as before.
GitGet tracks GitHub release lines and Windows installers. Existing JSON config
entries remain supported. The script also runs directly with PowerShell 7;
`fzf` is required for installer and app pickers, but not for checks or config.

Release detection selects the newest eligible release in the tracked line with
an installer extension. Old filenames and filename patterns never pin it to an
old version. A missing or ambiguous release line produces an error instead of
silently switching products or channels. `.exe` files can be portable programs;
the installer picker remains the final choice when filenames change.

## Configure an unusual app without editing the script

`gitget configure app-name` displays the saved settings. Supply any of the
following options to change just those settings; other values are preserved.
The same options are available when adding an app.

| Option | Purpose |
| --- | --- |
| `-TagPattern 'desktop-v*'` | Select a release line by tag; overrides the inferred family. |
| `-ReleaseNamePattern '*(Custom channel)'` | Select releases by name; supports arbitrary channel names. |
| `-IncludePrerelease $true` | Opt into releases marked prerelease by GitHub. Use `$false` to disable. |
| `-ReleaseLimit 200` | Search more history when a repo publishes many independent products. Default: 40; maximum: 1000. Larger requests are paginated and cached. |
| `-Pattern '*windows*x64*.msi'` | Installer matching/recommendation; explicitly configured patterns survive updates. |
| `-DisplayName 'Example App'` | Exact Windows uninstall display name. |
| `-DisplayNamePattern 'Example App version *'` | Match a display name containing a changing version. Multiple matches produce an error. |
| `-VersionExe 'C:\Apps\Example\app.exe'` | Read installed executable metadata from an explicit path. A relative filename uses the saved directory. |
| `-VersionCommand '--version'` | Explicitly run the configured executable to obtain a version. Automatic checks do not try flags on unknown executables. |
| `-VersionRegex 'version: (\d+\.\d+\.\d+)'` | Extract a version from configured command output. |
| `-InstalledVersionRegex '^\d+\.(\d+\.\d+\.\d+)$'` | Extract the product version when installed metadata contains another leading component. No component is ignored globally. |
| `-ReleaseVersionRegex '^product-(\d+\.\d+\.\d+)'` | Extract a comparable version from an unusual release tag. |
| `-CurrentVersion '1.2.3'` | Set a recorded version when automatic detection is unavailable. |

String settings can be cleared by passing `''`. Clear `-DisplayName` when
switching to `-DisplayNamePattern`. Release tag/name filters are combined when
both are set. Stable releases remain the default even with an explicit filter.
Example:

```powershell
gitget configure example -TagPattern 'desktop-v*' -Pattern '*x64*.msi'
gitget configure example -DisplayNamePattern 'Example version *'
gitget configure example -InstalledVersionRegex '^\d+\.(\d+\.\d+\.\d+)$'
gitget configure example -TagPattern '' -ReleaseNamePattern ''
```

Numeric versions, SemVer prerelease ordering, build metadata, and ISO dates
(`yyyy-MM-dd`) are supported. Different opaque versions produce an inconclusive
check and instructions to configure extraction. Apps ahead of the tracked
release are not downgraded. When only a recorded version is available, the
summary states that the installed version could not be verified.

Updates save the new version only after the installer succeeds. Failed or
cancelled installs retain the old recorded version. MSI reboot-required success
codes are supported. Checks and configuration never install applications.

Config: `%LOCALAPPDATA%\windows-config-files\gitget\config.json`.
Use `gitget backup` before making manual config changes.

## Offline regression tests

```powershell
pwsh -NoProfile -File tests/gitget.Tests.ps1
```

The suite mocks network requests, installers, and saved config; it does not
install apps or change your actual config.
