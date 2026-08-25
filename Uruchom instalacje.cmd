@echo off
setlocal
chcp 65001 >nul
title Instalacja polskiego dyktowania

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-HandyDictation.ps1"
set "INSTALL_EXIT=%ERRORLEVEL%"

echo.
if "%INSTALL_EXIT%"=="0" (
  echo Instalacja zakonczona pomyslnie.
) else (
  echo Instalacja nie powiodla sie. Kod bledu: %INSTALL_EXIT%
)
echo.
pause
exit /b %INSTALL_EXIT%
