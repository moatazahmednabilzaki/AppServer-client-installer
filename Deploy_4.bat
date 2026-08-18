@echo off
setlocal
color 0A
title Oracle Forms 11g - Automated Deployment

:: Ensure it runs as Administrator
net session >nul 2>&1
if not "%errorLevel%"=="0" (
    echo =======================================================
    echo PLEASE RUN AS ADMINISTRATOR!
    echo Right-click this file and select "Run as administrator"
    echo =======================================================
    pause
    exit /b 5
)

set "PKGDIR=%~dp0"
set "SCRIPT=%~dp01-Automated_Fix.ps1"

if not exist "%SCRIPT%" (
    echo =======================================================
    echo ERROR: 1-Automated_Fix.ps1 was not found next to this file.
    rem Quoted: an unquoted %SCRIPT% breaks cmd if the folder name contains ^&
    echo Expected: "%SCRIPT%"
    echo Copy the COMPLETE package folder, then run Deploy.bat again.
    echo =======================================================
    pause
    exit /b 2
)

:: Clear the "downloaded from the internet" mark so PowerShell will run these files.
::
:: NOTE: the previous version also ran Add-MpPreference -ExclusionPath '%~dp0',
:: which added a PERMANENT Defender exclusion for whatever folder this package was
:: launched from (often Downloads or a USB stick) and never removed it. That has
:: been removed - Unblock-File alone is enough to clear the zone marker.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath $env:PKGDIR -File | Unblock-File -ErrorAction SilentlyContinue"

powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Maximized -File "%SCRIPT%"
set "RC=%errorlevel%"

if not "%RC%"=="0" (
    echo.
    echo =======================================================
    echo DEPLOYMENT REPORTED PROBLEMS - exit code %RC%
    echo Review the failure list above, or the log under:
    echo   C:\ProgramData\AppServerClientInstaller\Logs
    echo =======================================================
    pause
)

exit /b %RC%
