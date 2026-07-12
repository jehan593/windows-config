@echo off
setlocal enabledelayedexpansion

set "PWSH=pwsh"

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