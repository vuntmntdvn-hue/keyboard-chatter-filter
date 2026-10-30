@echo off
rem Double-click to start the keyboard chatter filter now and at every login.
rem Options can be passed through, e.g.:  install.cmd -ThresholdMs 60 -Keys E,L
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
pause
