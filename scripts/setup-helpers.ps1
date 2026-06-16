function _PrintHeader
{
    param([string]$Title)
    Write-Host ""
    Write-Host ">>  $Title" -ForegroundColor Cyan
    Write-Host "-----------------------------------------------------" -ForegroundColor DarkBlue
}

function _PrintFooter
{
    Write-Host "-----------------------------------------------------" -ForegroundColor DarkBlue
    Write-Host ""
}

function _Ok   { param([string]$Msg) Write-Host ("[ok] {0}" -f $Msg) -ForegroundColor Green }
function _Warn { param([string]$Msg) Write-Host ("[--] {0}" -f $Msg) -ForegroundColor Yellow }
function _Info { param([string]$Msg) Write-Host ("[..] {0}" -f $Msg) -ForegroundColor Cyan }
function _Err  { param([string]$Msg) Write-Host ("[!!] {0}" -f $Msg) -ForegroundColor Red }

# Creates or re-links a symlink. Skips silently if already correct.
function Set-Symlink
{
    param([string]$Path, [string]$Target)
    if (-not (Test-Path $Target)) { _Warn "Target not found, skipping: $Target"; return }
    $dir = Split-Path $Path
    if (!(Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (Test-Path $Path -PathType Container)
    { _Warn "Directory already exists at symlink path: $Path (skipping)"; return }
    if (Test-Path $Path -PathType Leaf)
    {
        $existing = Get-Item $Path -Force
        if ($existing.LinkType -eq "SymbolicLink" -and $existing.Target -eq $Target)
        { _Warn "Already linked: $Path"; return }
        Remove-Item $Path -Force
    }
    New-Item -ItemType SymbolicLink -Path $Path -Value $Target -Force | Out-Null
    _Ok "Linked: $Path"
}