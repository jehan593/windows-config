# ==============================================================================
# WINGET PACKAGE LIST
# ==============================================================================
function Get-WingetApps
{
    return @(
        "Starship.Starship", "junegunn.fzf", "Git.Git",
        "sharkdp.fd",
        "WireGuard.WireGuard", "ViRb3.wgcf", "gerardog.gsudo",
        "jurplel.qView", "mpv.net", "Neovim.Neovim",
        "Microsoft.WindowsTerminal", "BurntSushi.ripgrep.MSVC"
    )
}

# ==============================================================================
# POWERSHELL MODULE LIST
# ==============================================================================
function Get-PsModules
{
    return @("Microsoft.WinGet.Client", "Terminal-Icons")
}
