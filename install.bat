@echo off
setlocal
title Gal Search MVP - Install Shortcuts
echo Installing Gal Search MVP shortcuts...
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
echo.
if %errorlevel% equ 0 (
    echo Shortcut created on your desktop. Double-click it to launch.
) else (
    echo An error occurred. Make sure GalSearch.ps1 is in the same folder.
)
echo.
pause
endlocal
