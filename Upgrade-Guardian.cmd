@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Upgrade-Guardian.ps1"
set "guardianResult=%ERRORLEVEL%"
echo.
if not "%guardianResult%"=="0" echo Guardian upgrade did not finish. Read the result above before retrying.
pause
exit /b %guardianResult%
