function _Confirm([string]$Prompt, [switch]$Y, [switch]$N)
{
    $r = Read-Host $Prompt
    if ($Y)
    {
        if ($r -match '^[Nn]$') { Write-Host " Skipped." -ForegroundColor Gray; return $false }
        return $true
    }
    if ($N)
    {
        if ($r -match '^[Yy]$') { return $true }
        Write-Host " Skipped." -ForegroundColor Gray
        return $false
    }
}