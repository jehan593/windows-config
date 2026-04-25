@echo off
setlocal enabledelayedexpansion

:: ----------------------------------------
:: Check for PowerShell 7
:: ----------------------------------------
where pwsh >nul 2>&1
if %errorlevel% neq 0 (
    echo PowerShell 7 not found. Installing...
    winget install --id Microsoft.PowerShell --source winget --silent --accept-package-agreements --accept-source-agreements
    set "PATH=!PATH!;%PROGRAMFILES%\PowerShell\7"
)

where pwsh >nul 2>&1
if %errorlevel% neq 0 (
    if not exist "%PROGRAMFILES%\PowerShell\7\pwsh.exe" (
        echo [!!] PowerShell 7 install failed. Please reopen this terminal and try again.
        pause
        exit /b 1
    )
    set "PWSH=%PROGRAMFILES%\PowerShell\7\pwsh.exe"
) else (
    set "PWSH=pwsh"
)

:: ----------------------------------------
:: Check for Windows Terminal
:: ----------------------------------------
where wt >nul 2>&1
if %errorlevel% neq 0 (
    echo Windows Terminal not found. Installing...
    winget install --id Microsoft.WindowsTerminal --source winget --silent --accept-package-agreements --accept-source-agreements
    if !errorlevel! neq 0 (
        echo [!!] Windows Terminal install failed. Continuing with default terminal...
    )
)

:: ----------------------------------------
:: Validate setup script exists
:: ----------------------------------------
if not exist "%~dp0setup-main.ps1" (
    echo [!!] setup-main.ps1 not found in %~dp0
    pause
    exit /b 1
)

:: ----------------------------------------
:: Launch setup
:: ----------------------------------------
echo Starting setup...
wt new-tab --title "Setup" "!PWSH!" -ExecutionPolicy Bypass -File "%~dp0setup-main.ps1"

:: If wt failed, fall back to direct PowerShell launch
if !errorlevel! neq 0 (
    echo Launching PowerShell directly...
    "!PWSH!" -ExecutionPolicy Bypass -File "%~dp0setup-main.ps1"
)
