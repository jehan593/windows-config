@echo off
where pwsh >nul 2>&1
if %errorlevel% == 0 (
    pwsh -ExecutionPolicy Bypass -File "%~dp0setup-main.ps1"
) else (
    echo PowerShell 7 not found. Installing...
    winget install --id Microsoft.PowerShell --source winget --silent --accept-package-agreements --accept-source-agreements
    refreshenv >nul 2>&1
    set "PATH=%PATH%;%PROGRAMFILES%\PowerShell\7"
    pwsh -ExecutionPolicy Bypass -File "%~dp0setup-main.ps1"
)