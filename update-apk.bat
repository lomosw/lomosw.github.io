@echo off
chcp 65001 >nul
title Lomorage APK Version Updater

REM Check if version argument is passed
if "%~1" == "" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0update-apk.ps1"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0update-apk.ps1" -Version "%~1"
)

pause
