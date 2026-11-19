# Windows Config

My personal Windows setup ΓÇö install everything, reset everything.

> **FYI:** This project is fully vibe coded for my personal use and taste. It's shared publicly in case it's useful to you. Feel free to fork it and adapt it to your needs.

## What's in here

- **`setup.bat`** ΓÇö installs packages, symlinks dotfiles, applies registry tweaks, sets up fonts/themes
- **`reset.bat`** ΓÇö undoes everything setup did
- **CLI tools** (installed into your PowerShell profile):
  - `wgm` ΓÇö WireGuard tunnel manager
  - `wpm` ΓÇö Wireproxy SOCKS5 tunnel manager
  - [`gitget`](tools/gitget.md) ΓÇö track GitHub repos and install their Windows releases
  - `regtwk` ΓÇö quick registry tweaks via fzf
  - `timer` ΓÇö full-screen countdown timer
- **Dotfiles** ΓÇö Starship, Neovim, mpv.net, Windows Terminal, PowerShell profile
- **Registry tweaks** ΓÇö declared in `registry/registry.json`, applied/reverted automatically

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

Both scripts self-elevate and mutate real machine state ΓÇö review before running.