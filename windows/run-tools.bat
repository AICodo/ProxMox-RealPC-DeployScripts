@echo off
:: Run all anti-detection scripts with admin privileges.
::
:: Originally based on https://github.com/Scrut1ny/AutoVirt — substantially
:: rewritten: broader pattern coverage, safe Enum\SCSI filtering, DriverStore/
:: PnP/log cleanup, realistic EDID serial generation, and the identifier
:: spoofer is net-new. See README "Windows Guest Tools" for details and the
:: Defender/EDR warning.

:: One-shot elevation. If we are re-launched as admin we receive the literal
:: argument "elevated" so we don't loop forever when elevation itself fails
:: (e.g. UAC was declined or this user is not in the Administrators group).
if /i "%~1"=="elevated" goto :admin_ok

net session >nul 2>&1
if %errorlevel% equ 0 goto :admin_ok

echo [!] Requesting Administrator privileges...
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList 'elevated' -Verb RunAs"
exit /b 0

:admin_ok
:: Re-check we actually got admin (in case "elevated" was passed but UAC denied).
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [X] Elevation failed. Right-click run-tools.bat and pick "Run as administrator".
    pause
    exit /b 1
)

echo ============================================
echo  Running Anti-Detection Scripts
echo ============================================
echo.

echo [1/3] Running QEMU Cleanup...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0qemu-cleanup.ps1"
if %errorlevel% neq 0 (
    echo [!] qemu-cleanup.ps1 failed with exit code %errorlevel%
) else (
    echo [+] QEMU Cleanup complete.
)
echo.

echo [2/3] Running Identifier Spoofer...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0identifier-spoofer.ps1"
if %errorlevel% neq 0 (
    echo [!] identifier-spoofer.ps1 failed with exit code %errorlevel%
) else (
    echo [+] Identifier Spoofer complete.
)
echo.

echo [3/3] Running EDID Spoofer...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0edid-spoofer.ps1"
if %errorlevel% neq 0 (
    echo [!] edid-spoofer.ps1 failed with exit code %errorlevel%
) else (
    echo [+] EDID Spoofer complete.
)
echo.

echo ============================================
echo  All scripts finished.
echo  Rebooting in 10 seconds. Press Ctrl+C to abort.
echo ============================================
timeout /t 10 /nobreak >nul
shutdown /r /t 0
