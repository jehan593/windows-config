# GitGet

Run `gitget add owner/repo`, `gitget check`, or `gitget update` as before.
GitGet tracks GitHub release lines and installs their Windows payloads.
Existing JSON config entries remain supported. The script also runs directly
with PowerShell 7; `fzf` is required for installer and app pickers, but not for
checks or config.

`gitget add` installs the payload right away, for every kind - installer,
portable and archive. It only tracks the app when the program is already
installed, and `gitget add owner/repo -NoInstall` never installs anything.

Adding an app that is already tracked installs it when it is missing from the
machine, so `gitget add owner/repo` is enough to get a program back after it
was deleted or never installed. The tracked release line, kind and asset
pattern are reused, the name prompt is skipped when the repo's own name is
already tracked, and an app that is still installed is left alone.
`gitget add owner/repo -Reinstall` overwrites an installed copy.

Release detection selects the newest eligible release in the tracked line with
a matching payload. Old filenames and filename patterns never pin it to an
old version. A missing or ambiguous release line produces an error instead of
silently switching products or channels. `.exe` files can be portable programs;
the installer picker remains the final choice when filenames change.

Release lists are cached for a short time. When the API cannot be reached -
the anonymous rate limit is the usual reason - the cached lists are used and
the run says so once. A problem that hits many apps is reported once, not once
per app. Set `$env:GITHUB_TOKEN` to raise the rate limit.

## Payload kinds

Every tracked app has a kind, stored as `install_type` in the config. Entries
without one keep the old installer behaviour.

| Kind | Payload | What gitget does |
| --- | --- | --- |
| `installer` | `.exe`, `.msi`, `.msix`, `.msixbundle` | Runs the installer and waits for it. The default. |
| `portable` | A bare `.exe` | Copies the program into the shared bin directory. |
| `archive` | `.zip`, `.tar.gz`, `.tgz`, `.tar`, `.7z` | Unpacks the archive into a staging dir and copies the program into the shared bin directory. |

`gitget add` offers the kinds the release actually ships and remembers the
choice. A plain `.exe` is ambiguous - it can be a portable program
(`yt-dlp.exe`) or an installer with an ordinary name (`Slack.exe`) - so both
kinds are offered and the likely one is listed first. `gitget add owner/repo
-InstallType portable` skips the picker. `gitget configure app
-InstallType archive` switches the kind later; the recorded install state is
dropped because it described the old kind.

When a release stops shipping the tracked kind, gitget switches to the kind it
ships now and stores it, so the question is asked at most once. The file name
of the old kind is dropped with it, because it means nothing for the new one.

Portable and archive programs land in the shared bin dir
`%LOCALAPPDATA%\windows-config-files\gitget\bin` (`-BinDir` picks a private
directory for one app instead) and that shared dir sits once near the front of
the user `PATH` - installs, updates and removals never rewrite it, so the PATH
cannot drift. Archives are unpacked into a per-app staging dir
(`...gitget\apps\<app name>`), a single top-level folder is lifted, and the
program placed into the shared bin dir is the one matching the app name, the
only program in the archive, or the largest program in it. `.dll` files sitting
next to the staged program go along so programs that load them still run.
`.7z` needs 7-Zip (`winget install 7zip`); every other archive uses built-in
tooling.

A release that ships one build per platform (topgrade ships ten) only offers
the Windows one: assets naming another platform (`linux`, `darwin`, `freebsd`,
`musl`, ...) are dropped, and assets built for another architecture are hidden
from the picker.

`gitget ls` shows the kind of every tracked app.

## Removing apps

`gitget rm` opens a picker over every tracked app. Pass a name to target one
without a picker, or `-All` to clear every tracked app:

```powershell
gitget rm myapp
gitget rm myapp -Purge
gitget rm -All
```

Portable and archive payloads were placed by gitget, so removing such an app
also removes its files: the program goes out of the shared bin dir (or the
per-app dir picked with `-BinDir`, together with its `PATH` entry) and the
download staging directory is deleted. The shared dir leaves the user `PATH`
when no tracked install lives in it anymore. An app that was installed by a setup
program keeps its files - uninstall it with the program itself - and `-Purge`
additionally deletes the leftovers of that installation.

`gitget rm -All` is what `reset` uses, so the tool stays the only thing that
knows where its payloads live.

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
| `-InstallType installer\|portable\|archive` | How the payload is installed. Changing it clears the recorded install state. |
| `-BinDir 'C:\Apps\bat'` | Private directory for this app's portable/archive payload instead of the shared bin dir. Set it when the app is tracked (or re-add after `rm`). Apps in the shared bin dir refuse a `-BinDir` change because moving would take every other install with it. |
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

## How the file is picked again on an update

The file of a tracked app is found by a pattern gitget derives from the file
name it installed last time: the version is cut out of the name, everything
else is kept (`gh_2.103.0_windows_amd64.msi` becomes
`*gh*windows*amd64.msi*`). The pattern is rebuilt on every install, so a new
version of the same file is found without asking. A pattern set with
`-Pattern` is never touched.

The picker only shows up when the release really renamed the file - there is
no name left to derive a pattern from. Picking the file then stores it, and
the next update is silent again.

A release can ship several files that match the pattern (a commercial build
next to the free one, a long-term-support build next to the current one).
The file that is the previous file with a new version is picked, so the extra
builds do not make gitget ask.

## Installed versions of portable apps

A portable program has no uninstall entry, so gitget records what it installed:
the version, the asset name, the program path and its SHA-256 hash. Checks use
the first source that answers:

1. The recorded state, but only when the hash on disk still matches.
2. The program's own answer - `-VersionCommand`/`-VersionRegex`, then the file
   metadata of the program.
3. The recorded version as a last resort, reported as unverified.

The result is never guessed. A payload that changed outside gitget and cannot
report a version is *inconclusive*: the check says so and the update is
skipped, because overwriting it could downgrade a self-updated program. Use
`gitget update -Reinstall` to overwrite it deliberately. A payload that was
deleted is *missing* and is installed again.

When a self-updating program reports its own version, the new hash and version
are recorded, so the next check is verified again.

Updates save the new version only after the installer succeeds. Failed or
cancelled installs retain the old recorded version. MSI reboot-required success
codes are supported. gitget waits for the installer process itself, not apps it
launches, so a ticked "run software" option does not block the update. Checks
and configuration never install applications. Portable and archive payloads are
replaced in place in the bin directory, and the state is recorded only after
the payload is in place.

Config: `%LOCALAPPDATA%\windows-config-files\gitget\config.json`.
Use `gitget backup` before making manual config changes.

## Offline regression tests

```powershell
pwsh -NoProfile -File tests/gitget.Tests.ps1
```

The suite mocks network requests, installers, and saved config; it does not
install apps or change your actual config. Portable and archive payloads are
covered too: the suite unpacks a real zip into a temp directory and checks the
recorded state, the changed-copy and missing-copy cases.
