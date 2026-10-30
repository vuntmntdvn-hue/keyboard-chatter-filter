@echo off
rem Double-click to stop the keyboard chatter filter and remove it from startup.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" -Uninstall
pause
