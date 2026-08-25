@echo off
setlocal
chcp 65001 >nul
title Sprawdzanie polskiego dyktowania

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-HandyDictation.ps1" -AuditOnly
set "AUDIT_EXIT=%ERRORLEVEL%"

echo.
pause
exit /b %AUDIT_EXIT%
