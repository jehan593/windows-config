@echo off
setlocal enabledelayedexpansion

:: ----------------------------------------
:: Check for PowerShell 7
:: ----------------------------------------
where pwsh >nul 2>&1
if %errorlevel% neq 0 (
    echo PowerShell 7 not found. Installing...
    winget install --id Microsoft.PowerShell --source winget --silent --accept-package-agreements --accept-source-agreements
)

:: After install, PATH won't be updated in this session, so check the known install
:: path directly and fall back to it if needed. Only abort if neither is available.
where pwsh >nul 2>&1
if %errorlevel% equ 0 (
    set "PWSH=pwsh"
) else if exist "%PROGRAMFILES%\PowerShell\7\pwsh.exe" (
    set "PWSH=%PROGRAMFILES%\PowerShell\7\pwsh.exe"
) else (
    echo [!!] PowerShell 7 install failed. Please reopen this terminal and try again.
    pause
    exit /b 1
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
where wt >nul 2>&1
if %errorlevel% equ 0 (
    wt new-tab --title "Setup" "!PWSH!" -ExecutionPolicy Bypass -File "%~dp0setup-main.ps1"
) else (
    echo Windows Terminal not available. Launching PowerShell directly...
    "!PWSH!" -ExecutionPolicy Bypass -File "%~dp0setup-main.ps1"
)

endlocal