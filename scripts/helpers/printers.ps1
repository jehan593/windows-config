function _PrintHeader
{
    param([string]$Title, [switch]$Sub)
    Write-Host ""
    Write-Host "${Title}" -ForegroundColor $(if ($Sub) { 'DarkCyan' } else { 'Cyan' })
    if (-not $Sub) { 
        Write-Host "-----------------------------------------------------" -ForegroundColor DarkGray 
    }
}

function _PrintFooter
{
    Write-Host "-----------------------------------------------------`n" -ForegroundColor DarkGray
}

function _PrintRow
{
    param([string]$Label, [string]$Value, [string]$Color = "White")
    Write-Host ("  {0,-14} {1}" -f $Label, $Value) -ForegroundColor $Color
}