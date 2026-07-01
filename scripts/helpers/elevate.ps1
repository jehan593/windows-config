function _IsAdmin
{
    return (New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    )).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function _AssertGsudo
{
    if (Get-Command gsudo -ErrorAction SilentlyContinue) { return $true }
    Write-Warning "gsudo not found. Run: winget install gsudo"
    return $false
}