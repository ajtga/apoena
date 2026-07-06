@echo off
REM start-apoena.cmd — Silent launcher for Apoena
REM Double-click this file to start Apoena without a visible console.
REM
REM Corporate note: If your machine enforces a script execution policy via
REM Group Policy and this launcher fails, run the following once as your user:
REM   powershell -Command "Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned"

start "Apoena" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0src\apoena.ps1"
