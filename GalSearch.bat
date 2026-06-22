@echo off
setlocal
title GalSearch

:: Launch PowerShell with proper UTF-8 encoding
start /min "" powershell.exe -NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -Command "& { [System.IO.File]::ReadAllText('%~dp0GalSearch.ps1', [System.Text.Encoding]::UTF8) | Invoke-Expression }"

endlocal
exit
