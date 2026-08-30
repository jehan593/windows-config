# ==============================================================================
# REPO LIST — cloned by _setup.ps1 into ~, removed by _reset.ps1, upgraded by
# the profile's uprep function.
# Format: "url|dest"
#   url  — git clone source (HTTPS)
#   dest — destination path relative to $HOME (leading ~/ expands to $HOME\)
#
# Add/remove lines here and setup/reset/uprep pick them up.
# ==============================================================================
function Get-RepoList
{
    return @(
        "https://github.com/jehan593/my-wallpapers|~/Pictures"
        "https://github.com/jehan593/notesnook-clipper|~/browser-extensions"
        "https://github.com/jehan593/chrome-newtab-dashboard|~/browser-extensions"
        "https://github.com/jehan593/webtime-tracker|~/browser-extensions"
    )
}

# Parses a "url|dest" repo-list entry into a synthetic object with the derived
# fields every consumer needs: Url, Name, Path (absolute), and DisplayPath
# (absolute path with $HOME collapsed to ~). Single source of truth for the
# url-split/dest-join/name-derive logic that setup, reset, cup and uprep used
# to each re-implement.
function Get-RepoEntry
{
    param([string]$Entry)

    $repoUrl, $repoDest = $Entry -split '\|', 2
    $repoDest    = Join-Path $HOME ($repoDest -replace '^~/', '')
    $repoName    = [System.IO.Path]::GetFileNameWithoutExtension($repoUrl)
    $repoPath    = Join-Path $repoDest $repoName
    $displayPath = $repoPath -replace [regex]::Escape($HOME), '~'

    return [pscustomobject]@{
        Url         = $repoUrl
        Name        = $repoName
        Path        = $repoPath
        Dest        = $repoDest
        DisplayPath = $displayPath
    }
}
