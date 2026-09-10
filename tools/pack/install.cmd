@echo off
rem goo-4k: install (patches the Steam build of World of Goo in place, keeps backups)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
pause
