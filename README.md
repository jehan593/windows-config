# Windows Config

Personal Windows machine setup: idempotent install/reset scripts, dotfiles, declarative registry tweaks, and a handful of PowerShell CLI tools — all restorable to a clean state.

## What it does

- **Setup/reset** — installs winget packages and PowerShell modules, symlinks dotfiles into `$HOME`, applies registry tweaks, configures fonts/theme/wallpaper, and installs supporting tools. `reset.bat` undoes all of it.
- **Dotfiles** — Starship prompt, Neovim, mpv.net, Windows Terminal, topgrade, and the PowerShell profile, deployed via symlink so edits here take effect immediately.
- **Registry tweaks** — declared in `registry/registry.json`, applied on setup and reverted on reset.
- **CLI tools**, installed into the PowerShell profile:
  - `wgm` — WireGuard tunnel manager
  - `wpm` — Wireproxy SOCKS5 tunnel manager
  - `regtwk` — fzf menu for one-off registry tweaks
  - `timer` — full-screen countdown timer

## Requirements

- Windows 10/11
- [winget](https://learn.microsoft.com/windows/package-manager/winget/)
- PowerShell 7 (installed automatically by `setup.bat` if missing)

## Usage

```
git clone https://github.com/jehan593/windows-config.git
cd windows-config
setup.bat
```

To undo everything setup did:

```
reset.bat
```

Both scripts self-elevate and mutate real machine state (installed packages, `HKLM`/`HKCU` values, symlinks under `$HOME`, Windows services) — review before running on a machine you care about.
