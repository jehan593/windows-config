# ==============================================================================
# GITGET-MANAGED APPS — portable tools installed/updated/purged by gitget.
# Format: "name|repo|kind" (name is the local app name, repo is owner/repo,
# kind is the payload kind gitget installs it with: portable or archive)
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
    )
}

# Parses a "name|repo|kind" entry into Name, Repo and Kind.
function Get-GitgetAppEntry
{
    param([string]$Entry)

    $parts   = $Entry -split '\|'
    $appName = $parts[0]
    $appRepo = $parts[1]
    $appKind = if ($parts.Count -gt 2 -and $parts[2]) { $parts[2] } else { 'archive' }

    return [pscustomobject]@{
        Name = $appName
        Repo = $appRepo
        Kind = $appKind
    }
}
