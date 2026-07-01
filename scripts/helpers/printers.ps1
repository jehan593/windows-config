function _PrintHeader
{
    param([string]$Icon, [string]$Title, [switch]$Sub)
    Write-Host ""
    Write-Host "${Icon}  ${Title}" -ForegroundColor $(if ($Sub) { 'DarkCyan' } else { 'Cyan' })
    if (-not $Sub) { Write-Host "─────────────────────────────────────────────────────" -ForegroundColor DarkGray }
}

function _PrintFooter
{
    Write-Host "─────────────────────────────────────────────────────`n" -ForegroundColor DarkGray
}

function _PrintRow
{
    param([string]$Icon, [string]$Label, [string]$Value, [string]$Color = "White")
    Write-Host ("{0} {1,-12} {2}" -f $Icon, $Label, $Value) -ForegroundColor $Color
}

