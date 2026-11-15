@echo off
REM ============================================================
REM  shuios - WSL2 one-click setup (ASCII only, see the .ps1 note)
REM
REM  Usage: right-click this file -> "Run as administrator"
REM  Log:   D:\shuios\.cache\wsl-install3.log
REM ============================================================
setlocal
set LOGDIR=D:\shuios\.cache
if not exist "%LOGDIR%" mkdir "%LOGDIR%"

echo.
echo === shuios WSL2 setup ===
echo.

echo [1/3] Enabling Microsoft-Windows-Subsystem-Linux ...
dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
echo     exit=%ERRORLEVEL%

echo [2/3] Enabling VirtualMachinePlatform ...
dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
echo     exit=%ERRORLEVEL%

echo [3/3] Installing WSL2 runtime (about 200 MB, please wait) ...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\shuios\tools\wsl-install3.ps1
echo     exit=%ERRORLEVEL%

echo.
echo Done. Log: %LOGDIR%\wsl-install3.log
echo If Windows asks for a reboot, reboot and run this file once more.
echo.
pause
