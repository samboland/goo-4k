@echo off
rem goo-4k: restore the stock files from goo4k-backup and remove the installed textures
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" -Uninstall %*
pause
