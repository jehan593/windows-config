# Windows Config

My personal Windows setup — install everything, reset everything.

> **This project is fully vibe coded.**

## What's in here

- **`setup.bat`** — installs packages, symlinks dotfiles, applies registry tweaks, sets up fonts/themes
- **`reset.bat`** — undoes everything setup did
- **CLI tools** (installed into your PowerShell profile):
  - `wgm` — WireGuard tunnel manager
  - `wpm` — Wireproxy SOCKS5 tunnel manager
  - `gitget` — track GitHub repos and install their Windows releases
  - `regtwk` — quick registry tweaks via fzf
  - `timer` — full-screen countdown timer
- **Dotfiles** — Starship, Neovim, mpv.net, Windows Terminal, PowerShell profile
- **Registry tweaks** — declared in `registry/registry.json`, applied/reverted automatically

## Requirements

- Windows 10/11
- [winget](https://learn.microsoft.com/windows/package-manager/winget/)
- PowerShell 7 (auto-installed by `setup.bat` if missing)

## Usage

```bat
git clone https://github.com/jehan593/windows-config.git
cd windows-config
setup.bat
```

Undo with `reset.bat`.

Both scripts self-elevate and mutate real machine state — review before running.
