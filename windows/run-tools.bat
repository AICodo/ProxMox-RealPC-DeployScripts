@echo off
:: Run all anti-detection scripts with admin privileges
:: Scripts sourced from: https://github.com/Scrut1ny/AutoVirt

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [!] Requesting Administrator privileges...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

echo ============================================
echo  Running Anti-Detection Scripts
echo ============================================
echo.

echo [1/3] Running QEMU Cleanup...
powershell -ExecutionPolicy Bypass -File "%~dp0qemu-cleanup.ps1"
if %errorlevel% neq 0 (
    echo [!] qemu-cleanup.ps1 failed with exit code %errorlevel%
) else (
    echo [+] QEMU Cleanup complete.
)
echo.

echo [2/3] Running Identifier Spoofer...
powershell -ExecutionPolicy Bypass -File "%~dp0identifier-spoofer.ps1"
if %errorlevel% neq 0 (
    echo [!] identifier-spoofer.ps1 failed with exit code %errorlevel%
) else (
    echo [+] Identifier Spoofer complete.
)
echo.

echo [3/3] Running EDID Spoofer...
powershell -ExecutionPolicy Bypass -File "%~dp0edid-spoofer.ps1"
if %errorlevel% neq 0 (
    echo [!] edid-spoofer.ps1 failed with exit code %errorlevel%
) else (
    echo [+] EDID Spoofer complete.
)
echo.

echo ============================================
echo  All scripts finished.
echo ============================================
pause
