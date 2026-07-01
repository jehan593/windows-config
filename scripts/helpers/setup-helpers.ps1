function _PrintHeader
{
    param([string]$Title)
    Write-Host ""
    Write-Host ">>  $Title" -ForegroundColor Cyan
    Write-Host "-----------------------------------------------------" -ForegroundColor DarkGray
}

function _PrintFooter
{
    Write-Host "-----------------------------------------------------" -ForegroundColor DarkGray
    Write-Host ""
}

function _Ok   { param([string]$Msg) Write-Host ("[ok] {0}" -f $Msg) -ForegroundColor Green }
function _Warn { param([string]$Msg) Write-Host ("[--] {0}" -f $Msg) -ForegroundColor Yellow }
function _Info { param([string]$Msg) Write-Host ("[..] {0}" -f $Msg) -ForegroundColor Cyan }
function _Err  { param([string]$Msg) Write-Host ("[!!] {0}" -f $Msg) -ForegroundColor Red }

