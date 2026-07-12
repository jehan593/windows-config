@echo off
setlocal enabledelayedexpansion

:: ----------------------------------------
:: Check for PowerShell 7
:: ----------------------------------------
where pwsh >nul 2>&1
if %errorlevel% neq 0 (
    echo PowerShell 7 not found. Installing...
    winget install --id Microsoft.PowerShell --source winget --silent --accept-package-agreements --accept-source-agreements

    :: Post-install path resolution fallback since current PATH won't update dynamically
    if exist "%PROGRAMFILES%\PowerShell\7\pwsh.exe" (
        set "PWSH=%PROGRAMFILES%\PowerShell\7\pwsh.exe"
    ) else (
        echo Error: PowerShell 7 install failed or path not found.
        pause
        exit /b 1
    )
) else (
    set "PWSH=pwsh"
)

:: ----------------------------------------
:: Validate setup script exists
:: ----------------------------------------
if not exist "%~dp0_setup.ps1" (
    echo Error: _setup.ps1 not found
    pause
    exit /b 1
)

:: ----------------------------------------
:: Launch setup
:: ----------------------------------------
echo Starting setup...
"!PWSH!" -NoProfile -ExecutionPolicy Bypass -File "%~dp0_setup.ps1"

endlocal