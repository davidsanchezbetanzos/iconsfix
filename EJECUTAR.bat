@echo off
REM Lanzador del script Fix Steam Icons
REM Salta la politica de ejecucion de PowerShell solo para este proceso.

pushd "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\fix-steam-icons.ps1"
set _EXIT=%ERRORLEVEL%
popd

echo.
echo Script terminado (codigo %_EXIT%).
pause
