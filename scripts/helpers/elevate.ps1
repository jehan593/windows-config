function _IsAdmin
{
    return (New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    )).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function _AssertGsudo
{
    if (Get-Command gsudo -ErrorAction SilentlyContinue) { return $true }
    
    Write-Host "Error: gsudo is missing." -ForegroundColor Red
    Write-Host "Please run: winget install gsudo" -ForegroundColor DarkGray
    return $false
}