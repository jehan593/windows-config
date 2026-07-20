# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A personal Windows configuration repo: idempotent PowerShell setup/reset scripts, dotfiles deployed via symlinks, declarative registry tweaks, and a set of PowerShell CLI tools (`wgm`, `wpm`, `regtwk`, `timer`) installed into the user's PowerShell profile. There is no build system, package.json, or test suite — this is infrastructure-as-PowerShell-script for one machine/user.

## Running things

There's nothing to build or test. To exercise the scripts themselves:

```
setup.bat     # installs winget packages/PS modules, symlinks home/* into $HOME, applies registry.json, installs font/theme, sets WINDOWS_CONFIG_PATH
reset.bat     # interactively undoes what setup.bat did (unlinks dotfiles, reverts registry values, removes wgm/wpm services, clears caches)
```

Both scripts self-elevate to Administrator (relaunching themselves via `wt`/`Start-Process -Verb RunAs`) and expect to run on Windows with `pwsh` (PowerShell 7) present — `setup.bat` will `winget install` PowerShell 7 first if missing. Because these mutate real machine state (installs packages, writes to `HKLM`, creates symlinks in `$HOME`, registers Windows services), do not run `_setup.ps1` / `_reset.ps1` / `setup.bat` / `reset.bat` unless the user explicitly asks — prefer reading/editing the scripts and letting the user run them.

`$env:WINDOWS_CONFIG_PATH` (set by setup, a machine-scope env var) is how every deployed tool/profile function finds this repo afterward — `tools/*.ps1` and the profile all dot-source helpers via `"$ConfigPath\helpers\..."` rather than relative paths.

## Architecture

**Entry points**: `setup.bat`/`reset.bat` are thin wrappers that locate/install `pwsh` and invoke `_setup.ps1`/`_reset.ps1`. All real logic lives in the numbered sections of those two PowerShell scripts (self-elevation → package managers → dotfile symlinks → registry values → fonts/theme/wallpapers → tool installs (wgm/wpm/wireproxy) → Windows Terminal config → env vars → execution policy). `_reset.ps1` mirrors `_setup.ps1` section-by-section in reverse, and is the canonical reference for "what setup did and how to undo it" — when editing one, check whether the other needs a matching change.

**`helpers/*.ps1`**: small, dot-sourced function libraries with no side effects on their own (dependency checks, config backup, WireGuard/Wireproxy service helpers, keep-awake via `SetThreadExecutionState`, self-elevation (`elevate.ps1`), registry value type-conversion (`registry-value.ps1`), fetching the wireproxy binary (`wireproxy-install.ps1`), the winget/PS-module manifest in `packages.ps1`). Both `_setup.ps1`/`_reset.ps1` and `tools/*.ps1` dot-source these — `packages.ps1`'s `Get-WingetApps`/`Get-PsModules` is the single source of truth for what gets installed and what reset tells the user to uninstall manually. `elevate.ps1`'s `Assert-Elevated` takes `$PSCommandPath` as an explicit parameter rather than reading it internally — inside a dot-sourced function `$PSCommandPath` resolves to the file that *defines* the function, not the caller, so it must be captured at the call site.

**`home/`**: mirrors the layout of `$HOME` exactly (e.g. `home\.config\starship.toml` → `$HOME\.config\starship.toml`). Setup walks this tree recursively and symlinks every file to the equivalent path under `$HOME`, backing up any pre-existing real file to `<path>.bak` first (restored by reset). Adding a new dotfile is just a matter of dropping it in the right place under `home/`.

**`registry/registry.json`**: declarative registry state, keyed by hive (`HKLM`/`HKCU`) then key path, each entry a list of `{name, type, value, default?}`. `type` is `DWord`, `String`, or `Json` (serialized via `ConvertTo-Json -Compress`). `default` is optional and semantically important: if present, reset restores the value to it; if absent, reset deletes the value entirely (and climbs up deleting now-empty parent keys, stopping at the hive root). `(Default)` as a `name` targets the key's unnamed default value, which needs `Set-Item` instead of `New-ItemProperty` (and `reg.exe delete /ve` to actually remove on reset, since `Remove-ItemProperty` can't target it). Adding a tweak means adding a JSON entry, not writing PowerShell.

**`tools/*.ps1`**: standalone CLI scripts, each exposed as a PowerShell function of the same name in the profile (`wgm`, `wpm`, `regtwk`, `timer` — see profile section 10 and `regtwk` in section 6) that forwards `@args` to `& "$ConfigPath\tools\<name>.ps1"`. Each does its own `_TestDependencies` check up front and no-ops with an error list if tools are missing, rather than partially running.
- `wgm.ps1` — WireGuard tunnel manager (fzf-picker driven). Has a built-in "warp" profile that self-generates via `wgcf` if missing; user profiles live under `%LOCALAPPDATA%\windows-config-files\wgm\configs`. Uses `wireguard /installtunnelservice` / `/uninstalltunnelservice` through `gsudo`.
- `wpm.ps1` — Wireproxy SOCKS5 tunnel manager, registers each tunnel as a Windows service (`<name>-wpm`) via `servy-cli`, with health-check/auto-restart params baked into the install command. Injects/rewrites the `[Socks5] BindAddress` line in the copied conf. The `wireproxy` binary itself comes from `helpers/wireproxy-install.ps1`'s `Install-Wireproxy` — downloads the prebuilt release tarball from `windtf/wireproxy` on GitHub (the `/releases/latest/download/` alias, so it always tracks the newest tag) straight to `%LOCALAPPDATA%\windows-config-files\bin` and adds that dir to the User `PATH`; no Go toolchain involved. `_setup.ps1` calls it on initial install; `wpm update` calls it again later to pick up newer releases, stopping/restarting any running `*-wpm` services around the call since Windows won't let the binary be overwritten while a service is running it.
- `regtwk.ps1` — fzf multi-select menu over a small fixed list of numbered registry tweaks (functions named `_Tweak_*`), each run elevated via `gsudo`. Adding a tweak means adding a `_Tweak_*` function and a matching entry in the `$tweaks` array/switch — separate from (and lower-level than) `registry/registry.json`, which is applied unconditionally by setup.
- `timer.ps1` — a full-screen countdown TUI (custom ASCII big-digit font, ANSI colors, alt-screen buffer, pause via spacebar) that calls `_EnableKeepAwake`/`_DisableKeepAwake` from `helpers/keep-awake.ps1` for its duration.

**`home\Documents\PowerShell\Microsoft.PowerShell_profile.ps1`**: the deployed PS profile. Notable patterns worth preserving when editing it:
- `Import-CachedCommand` caches `starship init powershell` / `zoxide init powershell` output to `%LOCALAPPDATA%\windows-config-files\ps-cache`, invalidated by comparing the source binary's `LastWriteTime` against the cache file's — avoids re-running `init` (slow) on every shell start.
- Non-essential setup (`Terminal-Icons`, `zoxide`, PSReadLine prediction options) is deferred into `$_deferredWork` and only runs on the *first* prompt render, not at profile load, to keep shell startup fast; the `prompt` function drains it once then clears the scriptblock.
- Functions here are the user-facing surface: package management (`inst`/`uinst`/`upp` — fzf pickers over winget, with a 7-day-cached `Find-WinGetPackage` search cache), update orchestration (`upall` fans out to `upp`/`upf`/`ups`/`upwp`/`upc`), and everyday shell ergonomics (`trash`, `sz`, `rr`/`gsudop` for privilege-escalating the last/given command, `Ctrl+h` PSReadLine history search via fzf).

**Registry data flow**: `registry/registry.json` is the only place registry tweaks are declared for `_setup.ps1`/`_reset.ps1`. `tools/regtwk.ps1` is a separate, manually-invoked catalog of one-off tweaks not part of the automatic setup/reset lifecycle.

## Conventions to follow when editing scripts

- Every destructive/mutating helper (`Set-Symlink`, `Set-RegistryValues`, `Remove-Symlink`, `Remove-RegistryValues`) wraps its work in try/catch and reports Green/Red/Yellow via `Write-Host`, never throws uncaught — preserve this so partial failures during setup/reset don't halt the whole script.
- `New-Item -Force` on an existing registry key wipes its values/subkeys, so code always checks `Test-Path` before creating — same for the analogous risk elsewhere.
- Anything requiring elevation beyond the top-level self-elevated script (e.g. inside profile functions run in a normal shell) goes through `gsudo`, often via a scriptblock with `-args` rather than closures, since `gsudo` runs in a separate process.
- Symlinked dotfiles and registry values that had a prior real value are always backed up (`.bak` file, or the `default` field) so reset can restore rather than merely delete.
