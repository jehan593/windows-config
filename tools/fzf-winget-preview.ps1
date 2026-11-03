param([string]$Id)

# fzf preview resolver for the winget pickers (inst / uinst / upp).
#
# Pinned to the winget source: the msstore endpoint never answers on this
# network, and winget show would otherwise pay ~43 s of timeouts there.
# On top of that the winget CDN intermittently stalls a single call for a
# couple of dozen seconds, so results are cached for a day - a slow lookup
# can only happen once per package instead of on every hover.

$cacheDir  = Join-Path $env:LOCALAPPDATA 'windows-config-files\winget_show_cache'
$cacheFile = Join-Path $cacheDir (($Id -replace '[^A-Za-z0-9._-]', '_') + '.txt')

if (Test-Path $cacheFile)
{
    $lines = Get-Content $cacheFile
    $age   = (New-TimeSpan -Start ([datetime]$lines[0]) -End (Get-Date)).TotalHours
    if ($age -lt 24)
    {
        $lines | Select-Object -Skip 1
        return
    }
}

$out = winget show --id $Id -s winget --exact --accept-source-agreements --disable-interactivity 2>&1

if ($LASTEXITCODE -eq 0 -and $out)
{
    New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
    @(Get-Date -Format o) + @($out) | Set-Content $cacheFile
}
Write-Host ($out | Out-String)
