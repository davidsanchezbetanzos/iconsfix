@echo off
REM Fix Steam Icons - Launcher
REM Bypasses PowerShell's execution policy for this single run only.

pushd "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\fix-steam-icons.en.ps1"
set _EXIT=%ERRORLEVEL%
popd

echo.
echo Script finished (exit code %_EXIT%).
pause
