# ==============================================================================
# REPO LIST — cloned into ~ by setup, removed by reset, upgraded by uprep.
# Format: "url|dest" (dest relative to $HOME, ~/ expands to $HOME\)
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

# Parses a "url|dest" entry into Url, Name, Path, and DisplayPath (~ collapsed).
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
