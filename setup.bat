@echo off
setlocal

:: Check for PowerShell 7
where pwsh >nul 2>&1
if %errorlevel% neq 0 (
    echo PowerShell 7 not found. Installing...
    winget install --id Microsoft.PowerShell --source winget --silent --accept-package-agreements --accept-source-agreements
    set "PATH=%PATH%;%PROGRAMFILES%\PowerShell\7"
)

:: Check for Windows Terminal
where wt >nul 2>&1
if %errorlevel% neq 0 (
    echo Windows Terminal not found. Installing...
    winget install --id Microsoft.WindowsTerminal --source winget --silent --accept-package-agreements --accept-source-agreements
)

:: Launch setup script in Windows Terminal with PowerShell 7
wt new-tab --title "Setup" pwsh -ExecutionPolicy Bypass -File "%~dp0setup-main.ps1"
