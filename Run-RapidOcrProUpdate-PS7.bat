@echo off
setlocal

set "APP_DIR=%~dp0"
set "APP_SCRIPT=%APP_DIR%RapidOcrProUpdate.ps1"
set "SPLASH_HTA=%APP_DIR%RapidOcrStartupSplash.hta"

if not exist "%APP_SCRIPT%" (
    echo RapidOcrProUpdate.ps1 was not found:
    echo "%APP_SCRIPT%"
    pause
    exit /b 1
)

where pwsh.exe >nul 2>nul
if %errorlevel%==0 (
    set "POWERSHELL_EXE=pwsh.exe"
) else (
    set "POWERSHELL_EXE=powershell.exe"
)

pushd "%APP_DIR%" >nul

if exist "%SPLASH_HTA%" (
    start "" mshta.exe "%SPLASH_HTA%"
)

start "RapidOcrProUpdate" /min "%POWERSHELL_EXE%" -NoProfile -ExecutionPolicy Bypass -STA -File "%APP_SCRIPT%"

popd >nul
exit /b 0
