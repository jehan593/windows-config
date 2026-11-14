# ==============================================================================
# GITGET-MANAGED APPS — portable tools installed/updated/purged by gitget.
# Format: "name|repo|kind" (name is the local app name, repo is owner/repo,
# kind is the payload kind gitget installs it with: portable, archive or installer)
#
# A tool listed here must NOT also be in the winget list - two owners means
# two copies, and whichever one gets uninstalled leaves a broken link behind.
# ==============================================================================
function Get-GitgetApps
{
    return @(
        "wireproxy|windtf/wireproxy|archive"
        "zoxide|ajeetdsouza/zoxide|archive"
        "topgrade|topgrade-rs/topgrade|archive"
        "servy|aelassas/servy"
        "7-Zip-zstd|mcmilk/7-Zip-zstd|installer"
    )
}
