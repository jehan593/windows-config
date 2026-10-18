@echo off
setlocal enabledelayedexpansion

call :FindPwsh
if not defined PWSH (
    echo Error: PowerShell 7 not found. Run setup.bat first.
    pause
    exit /b 1
)

:: ----------------------------------------
:: Validate reset script exists
:: ----------------------------------------
if not exist "%~dp0_reset.ps1" (
    echo Error: _reset.ps1 not found
    pause
    exit /b 1
)

echo Starting reset...
"!PWSH!" -NoProfile -ExecutionPolicy Bypass -File "%~dp0_reset.ps1"

endlocal
goto :eof

:FindPwsh
set "PWSH="
where pwsh >nul 2>&1 && set "PWSH=pwsh"
if not defined PWSH if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
exit /b 0