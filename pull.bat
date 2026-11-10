@echo off
rem Launcher for scripts\sync.ps1 pull
rem ASCII only on purpose: cmd reads .bat in the OEM codepage,
rem non-ASCII text here would come out garbled. Chinese output
rem is printed by the .ps1, which is UTF-8 with BOM.
setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\sync.ps1" pull %*
echo.
pause
