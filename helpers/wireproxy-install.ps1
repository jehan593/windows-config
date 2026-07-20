# ==============================================================================
# WIREPROXY BINARY INSTALL
# ==============================================================================
function Install-Wireproxy
{
    $wireproxyBinDir  = "$env:LOCALAPPDATA\windows-config-files\bin"
    $wireproxyTarUrl  = "https://github.com/windtf/wireproxy/releases/latest/download/wireproxy_windows_amd64.tar.gz"
    $wireproxyTarPath = Join-Path $env:TEMP "wireproxy.tar.gz"

    New-Item -ItemType Directory -Path $wireproxyBinDir -Force | Out-Null
    Invoke-WebRequest -Uri $wireproxyTarUrl -OutFile $wireproxyTarPath -UseBasicParsing
    tar -xzf $wireproxyTarPath -C $wireproxyBinDir wireproxy.exe
    Remove-Item $wireproxyTarPath -Force

    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($userPath -notlike "*$wireproxyBinDir*")
    {
        [Environment]::SetEnvironmentVariable("Path", "$userPath;$wireproxyBinDir", "User")
    }
    $env:Path += ";$wireproxyBinDir"

    return "$wireproxyBinDir\wireproxy.exe"
}
