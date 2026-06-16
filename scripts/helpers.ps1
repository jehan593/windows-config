function _PrintHeader
{
    param([string]$Icon, [string]$Title, [switch]$Sub)
    Write-Host ""
    Write-Host "${Icon}  ${Title}" -ForegroundColor $(if ($Sub) { 'DarkCyan' } else { 'Cyan' })
    if (-not $Sub) { Write-Host "─────────────────────────────────────────────────────" -ForegroundColor DarkBlue }
}

function _PrintFooter
{
    Write-Host "─────────────────────────────────────────────────────`n" -ForegroundColor DarkBlue
}

function _PrintRow
{
    param([string]$Icon, [string]$Label, [string]$Value, [string]$Color = "White")
    Write-Host ("{0} {1,-12} {2}" -f $Icon, $Label, $Value) -ForegroundColor $Color
}

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

function _Confirm([string]$Prompt)
{
    $r = Read-Host $Prompt
    if ($r -match '^[Nn]$') { Write-Host "󰅖 Aborted." -ForegroundColor Gray; return $false }
    return $true
}

function _WingetAction
{
    param([string]$Verb, [string[]]$Ids, [string[]]$ExtraArgs = @())
    foreach ($id in $Ids)
    {
        Write-Host "󰏔 ${Verb}: $id" -ForegroundColor Cyan
        winget $Verb --id $id --exact --interactive @ExtraArgs
        if ($LASTEXITCODE -eq 0) { Write-Host "󰄬 Done: $id" -ForegroundColor Green }
        else                     { Write-Host "󰅖 Failed: $id" -ForegroundColor Red }
        $argsStr = if ($ExtraArgs) { " " + ($ExtraArgs -join " ") } else { "" }
        _AddToHistory "winget $Verb --id $id --exact --interactive$argsStr"
    }
}

function _PrintUpdateList
{
    param([object]$Updates)
    $Updates | ForEach-Object {
        $size = if ($_.MaxDownloadSize -gt 0) { " ($([math]::Round($_.MaxDownloadSize / 1MB, 1)) MB)" } else { "" }
        Write-Host ("󰏔  {0}{1}" -f $_.Title, $size) -ForegroundColor Cyan
    }
}

function _AddToHistory([string]$Entry)
{
    Add-Content -Path (Get-PSReadLineOption).HistorySavePath -Value $Entry
    [Microsoft.PowerShell.PSConsoleReadLine]::AddToHistory($Entry)
}

function _GetWindowsUpdates
{
    $session  = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    return [PSCustomObject]@{
        Session = $session
        Results = $searcher.Search("IsInstalled=0 and IsHidden=0")
    }
}