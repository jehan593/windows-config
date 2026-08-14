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
