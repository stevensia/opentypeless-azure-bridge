@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup.ps1" -Mode Apply -InstallDependencies
set "setupResult=%ERRORLEVEL%"
echo.
if not "%setupResult%"=="0" echo Setup did not finish. Read the error above, fix the prerequisite, and run again.
pause
exit /b %setupResult%
