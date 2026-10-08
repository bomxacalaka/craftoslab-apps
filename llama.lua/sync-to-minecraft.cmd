@echo off
pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0sync-to-minecraft.ps1" %*
exit /b %ERRORLEVEL%
