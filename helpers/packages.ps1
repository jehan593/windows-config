# ==============================================================================
# WINGET PACKAGE LIST
# ==============================================================================
function Get-WingetApps
{
    return @(
        "Starship.Starship", "junegunn.fzf", "Git.Git", "ajeetdsouza.zoxide",
        "sharkdp.fd", "aelassas.Servy",
        "WireGuard.WireGuard", "ViRb3.wgcf", "gerardog.gsudo",
        "jurplel.qView", "mpv.net", "Neovim.Neovim", "topgrade-rs.topgrade",
        "Microsoft.WindowsTerminal"
    )
}

# ==============================================================================
# POWERSHELL MODULE LIST
# ==============================================================================
function Get-PsModules
{
    return @("Microsoft.WinGet.Client", "Terminal-Icons")
}
