@echo off
title ProxMox-RealPC Windows Guest Tools
color 0B

:: -- Self-elevate to Administrator if not already --
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting Administrator privileges ...
    set "ELEVATE_VBS=%TEMP%\elevate_%RANDOM%.vbs"
    echo Set UAC = CreateObject^("Shell.Application"^) > "%ELEVATE_VBS%"
    echo UAC.ShellExecute "%~f0", "", "%~dp0", "runas", 1 >> "%ELEVATE_VBS%"
    cscript //nologo "%ELEVATE_VBS%"
    del /q "%ELEVATE_VBS%" 2>nul
    exit /b
)

:menu
cls
echo.
echo   +==========================================+
echo   |   ProxMox-RealPC  Windows Guest Tools    |
echo   +==========================================+
echo.
echo   [1]  QEMU Cleanup        - Remove VM registry ^& driver traces
echo   [2]  Identifier Spoofer  - Randomise machine IDs / MAC / hostname
echo   [3]  EDID Spoofer        - Strip monitor serial numbers
echo.
echo   [A]  Run ALL (1 then 2 then 3)
echo   [Q]  Quit
echo.
set /p choice="  Select option: "

if "%choice%"=="1" goto run1
if "%choice%"=="2" goto run2
if "%choice%"=="3" goto run3
if /i "%choice%"=="A" goto runall
if /i "%choice%"=="Q" goto :eof
echo.
echo   Invalid choice. Try again.
timeout /t 2 >nul
goto menu

:run1
cls
echo.
echo   Running qemu-cleanup.ps1 ...
echo   --------------------------------------------
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0qemu-cleanup.ps1" -SkipPsExec
echo.
pause
goto menu

:run2
cls
echo.
echo   Running identifier-spoofer.ps1 ...
echo   --------------------------------------------
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0identifier-spoofer.ps1" -NoReboot
echo.
pause
goto menu

:run3
cls
echo.
echo   Running edid-spoofer.ps1 ...
echo   --------------------------------------------
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0edid-spoofer.ps1"
echo.
pause
goto menu

:runall
cls
echo.
echo   Running ALL tools sequentially ...
echo   ============================================
echo.
echo   [1/3] qemu-cleanup.ps1
echo   --------------------------------------------
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0qemu-cleanup.ps1" -SkipPsExec
echo.
echo   [2/3] identifier-spoofer.ps1
echo   --------------------------------------------
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0identifier-spoofer.ps1" -NoReboot
echo.
echo   [3/3] edid-spoofer.ps1
echo   --------------------------------------------
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0edid-spoofer.ps1"
echo.
echo   ============================================
echo   All done. A reboot is recommended.
echo.
pause
goto menu
