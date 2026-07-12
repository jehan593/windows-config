# ==============================================================================
# CONFIG BACKUP
# ==============================================================================
function Backup-Configs
{
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$BackupDir
    )

    if (-not (Test-Path $SourcePath)) { return $false }

    New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null

    $isDir = Test-Path -LiteralPath $SourcePath -PathType Container

    try
    {
        if ($isDir)
        { Copy-Item -Path "$SourcePath\*.conf" -Destination $BackupDir -Force -ErrorAction Stop }
        else
        { Copy-Item -LiteralPath $SourcePath -Destination $BackupDir -Force -ErrorAction Stop }
        return $true
    }
    catch
    {
        return $false
    }
}
