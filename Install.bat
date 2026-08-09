@echo off
title Install KeepSpicetifyOn
echo.
echo   Installing KeepSpicetifyOn...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -Command "Set-Location -LiteralPath '%~dp0'; Get-ChildItem -Recurse -Filter *.ps1 | Unblock-File -ErrorAction SilentlyContinue; & '.\install.ps1'"

echo.
echo   Press any key to close this window.
pause >nul
