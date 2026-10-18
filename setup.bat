@echo off
setlocal enabledelayedexpansion

:: ----------------------------------------
:: Locate PowerShell 7
:: ----------------------------------------
call :FindPwsh

:: winget may install the MSIX (pwsh alias on PATH) or the MSI
:: (%ProgramFiles%\PowerShell\7). PATH in this process won't reflect a fresh
:: MSI install, so :FindPwsh checks both before and after installing.
if not defined PWSH (
    echo PowerShell 7 not found. Installing...
    where winget >nul 2>&1
    if errorlevel 1 (
        echo Error: winget not found. Install "App Installer" from the Microsoft Store first.
        pause
        exit /b 1
    )
    winget install --id Microsoft.PowerShell --source winget --silent --accept-package-agreements --accept-source-agreements
    call :FindPwsh
    if not defined PWSH (
        echo Error: PowerShell 7 install failed or pwsh not found.
        pause
        exit /b 1
    )
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
goto :eof

:FindPwsh
set "PWSH="
where pwsh >nul 2>&1 && set "PWSH=pwsh"
if not defined PWSH if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
exit /b 0
