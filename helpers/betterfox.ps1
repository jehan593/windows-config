# ==============================================================================
# BETTERFOX USER.JS FETCH + HASH
# ==============================================================================
# Silent - pure functions over the repo's firefox data files. The upstream
# fetch is cached (ETag + body in the ps-cache dir): an unchanged upstream
# answers 304 instead of a full download, and a fetch failure falls back to
# the cached body so cup/upf keep working offline.
function _GetSha256([string]$Text)
{
    $sha = [System.Security.Cryptography.SHA256]::Create()
    [System.Convert]::ToHexString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text)))
}

# Shared by 'cup' (check) and 'upf' (apply) so both hash the same content.
function _GetBetterfoxUserJs
{
    $url           = "https://raw.githubusercontent.com/yokoffing/Betterfox/main/user.js"
    $removalsPath  = "$ConfigPath\data\firefox\user-removals.txt"
    $overridesPath = "$ConfigPath\data\firefox\overrides.txt"
    $cacheDir      = "$env:LOCALAPPDATA\windows-config-files\ps-cache"
    $bodyCache     = Join-Path $cacheDir "betterfox_user.js"
    $etagCache     = Join-Path $cacheDir "betterfox_etag.txt"

    $headers = @{}
    if (Test-Path $etagCache) { $headers['If-None-Match'] = (Get-Content $etagCache -Raw).Trim() }

    $raw = $null
    try
    {
        $response = Invoke-WebRequest -Uri $url -Headers $headers -UseBasicParsing -ErrorAction Stop
        $raw = $response.Content
        $etag = $response.Headers['ETag']
        if ($etag)
        {
            $null = New-Item -ItemType Directory -Path $cacheDir -Force -ErrorAction SilentlyContinue
            Set-Content -Path $etagCache -Value $etag -NoNewline -ErrorAction SilentlyContinue
            Set-Content -Path $bodyCache -Value $raw -Encoding UTF8 -ErrorAction SilentlyContinue
        }
    }
    catch
    {
        # A 304 (unchanged) or any fetch failure serves the last known body.
        if (Test-Path $bodyCache) { $raw = Get-Content $bodyCache -Raw }
        else { throw }
    }

    $lines = $raw -split "`n"

    $removals = Get-Content $removalsPath | Where-Object { $_.Trim() -ne "" }
    foreach ($key in $removals)
    {
        $escaped = [regex]::Escape($key.Trim())
        $lines   = $lines | Where-Object { $_ -notmatch "user_pref\(`"$escaped`"" }
    }

    $content = $lines -join "`n"

    $overrides = (Get-Content $overridesPath -Raw).Trim()
    if ($overrides)
    { $content = $content.TrimEnd() + "`n`n// overrides.txt`n" + $overrides + "`n" }

    return ($content -replace "`r`n", "`n").TrimEnd()
}

# Hash of the content that belongs in every profile. A profile is up to date
# when its own user.js hashes to this - no separate marker file needed.
function _GetBetterfoxHash
{
    return _GetSha256 (_GetBetterfoxUserJs)
}
