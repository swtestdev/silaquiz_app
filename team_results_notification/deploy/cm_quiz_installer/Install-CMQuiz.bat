@echo off
setlocal EnableExtensions
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-CMQuiz.ps1"
echo.
pause