<#
.SYNOPSIS
    Remove QEMU / VirtIO / VM artefacts from the Windows registry.

.DESCRIPTION
    Scans the Enum, driver, and service registry trees for keys containing
    well-known QEMU, VirtIO, Red Hat, and Bochs vendor / device IDs and
    removes them so anti-cheat and detection tools cannot find traces of a
    virtual machine.

    Must be run as Administrator.  Operations that touch HKLM:\SYSTEM keys
    owned by TrustedInstaller are executed via PsExec64 running as SYSTEM.

    Inspired by Scrut1ny/AutoVirt  (resources/scripts/Windows/qemu-cleanup.ps1)
    — rewritten with broader coverage, structured logging, backup support,
      and safety checks.

.PARAMETER SkipPsExec
    Run cleanup directly in the current (elevated) session instead of
    downloading Sysinternals PsExec and launching a SYSTEM child.

.PARAMETER BackupFirst
    Export each matching registry subtree to .reg files under
    $env:TEMP\qemu-cleanup-backup before deletion (default: $true).

.PARAMETER WhatIf
    Preview what would be deleted without making changes.

.EXAMPLE
    .\qemu-cleanup.ps1
    .\qemu-cleanup.ps1 -SkipPsExec
    .\qemu-cleanup.ps1 -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$SkipPsExec,
    [bool]  $BackupFirst = $true
)

# ── Guard: must be admin ────────────────────────────────────────────────
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]$identity
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[!] This script must be run as Administrator." -ForegroundColor Red
    exit 1
}

# ── Signature strings to hunt for ──────────────────────────────────────
# PCI vendor / device / subsystem IDs tied to QEMU, Red Hat, and VirtIO
$Signatures = @(
    "VEN_1AF4"          # Red Hat / VirtIO vendor
    "DEV_1AF4"
    "DEV_1B36"          # QEMU PCI bridge / xhci
    "SUBSYS_11001AF4"   # VirtIO subsystem
    "VEN_1234"          # QEMU default VGA (bochs-display)
    "DEV_1111"          # QEMU VGA
    "VEN_8086&DEV_2934" # QEMU i82801 USB (common default)
    "VEN_8086&DEV_2918" # QEMU PIIX4 ISA bridge
    "QEMU"
    "BOCHS"
    "Red Hat"
    "VirtIO"
    "VBOX"              # catch any VirtualBox leftovers too
    "SUBSYS_0627"       # QEMU display adapter subsystem (scoped to SUBSYS)
)

# Registry roots to scan
$EnumRoots = @(
    "HKLM:\SYSTEM\CurrentControlSet\Enum"
    "HKLM:\SYSTEM\CurrentControlSet\Services"
    "HKLM:\SYSTEM\CurrentControlSet\Control\Class"
    "HKLM:\SYSTEM\CurrentControlSet\Control\Video"
)

# Additionally wipe matching SCSI sub-keys (QEMU virtio-scsi leaves traces)
$ScsiRoot = "HKLM:\SYSTEM\CurrentControlSet\Enum\SCSI"

# ── Helpers ─────────────────────────────────────────────────────────────
$Stats = @{ Scanned = 0; Deleted = 0; Failed = 0; Backed = 0 }

function Write-Banner {
    $banner = @"

  ╔══════════════════════════════════════════╗
  ║       QEMU / VM Registry Cleanup         ║
  ║  ProxMox-RealPC-DeployScripts            ║
  ╚══════════════════════════════════════════╝

"@
    Write-Host $banner -ForegroundColor Cyan
}

function Backup-Key {
    param([string]$KeyPath)
    if (-not $BackupFirst) { return }
    $backupDir = Join-Path $env:TEMP "qemu-cleanup-backup"
    if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
    # PSPath looks like "Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\..."
    # Convert to reg.exe format: "HKEY_LOCAL_MACHINE\..."
    $hive = $KeyPath -replace '^.*?::', ''
    # Build a safe filename (truncate to avoid MAX_PATH issues)
    $safeName = ($hive -replace '[:\\\/ ]', '_')
    if ($safeName.Length -gt 180) { $safeName = $safeName.Substring(0, 180) }
    $safeName += ".reg"
    $outFile  = Join-Path $backupDir $safeName
    try {
        & reg export $hive $outFile /y 2>$null | Out-Null
        $Stats.Backed++
    } catch { }
}

function Remove-MatchingKeys {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]   $Root,
        [string[]] $Patterns
    )
    if (-not (Test-Path $Root)) { return }
    $keys = Get-ChildItem -Path $Root -Recurse -ErrorAction SilentlyContinue
    foreach ($key in $keys) {
        $Stats.Scanned++
        $match = $Patterns | Where-Object { $key.PSPath -like "*$_*" }
        if ($match) {
            if ($PSCmdlet.ShouldProcess($key.PSPath, "Delete registry key")) {
                Backup-Key $key.PSPath
                try {
                    Remove-Item -Path $key.PSPath -Recurse -Force -ErrorAction Stop
                    Write-Host "  [DEL] $($key.PSPath)" -ForegroundColor Green
                    $Stats.Deleted++
                } catch {
                    Write-Host "  [ERR] $($key.PSPath) - $_" -ForegroundColor Yellow
                    $Stats.Failed++
                }
            } else {
                Write-Host "  [DRY] Would delete: $($key.PSPath)" -ForegroundColor DarkGray
            }
        }
    }
}

function Remove-ScsiVmKeys {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Root, [string[]]$Patterns)
    if (-not (Test-Path $Root)) { return }
    $keys = Get-ChildItem -Path $Root -Recurse -ErrorAction SilentlyContinue
    foreach ($key in $keys) {
        $Stats.Scanned++
        $match = $Patterns | Where-Object { $key.PSPath -like "*$_*" }
        if ($match) {
            if ($PSCmdlet.ShouldProcess($key.PSPath, "Delete SCSI key")) {
                Backup-Key $key.PSPath
                try {
                    Remove-Item -Path $key.PSPath -Recurse -Force -ErrorAction Stop
                    Write-Host "  [DEL] $($key.PSPath)" -ForegroundColor Green
                    $Stats.Deleted++
                } catch {
                    Write-Host "  [ERR] $($key.PSPath) - $_" -ForegroundColor Yellow
                    $Stats.Failed++
                }
            }
        }
    }
}

# ── Main logic (can run inline or via PsExec) ──────────────────────────
function Invoke-Cleanup {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    Write-Banner

    Write-Host "[*] Scanning registry for VM artefacts ..." -ForegroundColor White
    foreach ($root in $EnumRoots) {
        Write-Host "    Scanning $root" -ForegroundColor DarkCyan
        Remove-MatchingKeys -Root $root -Patterns $Signatures
    }

    Write-Host "`n[*] Scanning SCSI sub-keys ($ScsiRoot) for VM artefacts ..." -ForegroundColor White
    Remove-ScsiVmKeys -Root $ScsiRoot -Patterns $Signatures

    # Extra: remove cached VirtIO / QEMU driver packages from DriverStore
    $driverStore = "$env:SystemRoot\System32\DriverStore\FileRepository"
    if (Test-Path $driverStore) {
        Write-Host "`n[*] Scanning DriverStore for VirtIO leftovers ..." -ForegroundColor White
        Get-ChildItem -Path $driverStore -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'vio|virtio|qemu|red_hat|redhat|bochs' } |
            ForEach-Object {
                $Stats.Scanned++
                if ($PSCmdlet.ShouldProcess($_.FullName, "Delete driver folder")) {
                    try {
                        Remove-Item -Path $_.FullName -Recurse -Force -ErrorAction Stop
                        Write-Host "  [DEL] $($_.FullName)" -ForegroundColor Green
                        $Stats.Deleted++
                    } catch {
                        Write-Host "  [ERR] $($_.FullName) - $_" -ForegroundColor Yellow
                        $Stats.Failed++
                    }
                }
            }
    }

    # Summary
    Write-Host "`n────────────────────────────────────────────" -ForegroundColor Cyan
    Write-Host "  Scanned : $($Stats.Scanned)" -ForegroundColor White
    Write-Host "  Deleted : $($Stats.Deleted)" -ForegroundColor Green
    Write-Host "  Failed  : $($Stats.Failed)"  -ForegroundColor $(if ($Stats.Failed -gt 0) { 'Yellow' } else { 'White' })
    Write-Host "  Backed  : $($Stats.Backed)"  -ForegroundColor White
    if ($BackupFirst -and $Stats.Backed -gt 0) {
        Write-Host "  Backups : $env:TEMP\qemu-cleanup-backup" -ForegroundColor DarkGray
    }
    Write-Host "────────────────────────────────────────────`n" -ForegroundColor Cyan
}

# ── Dispatch ────────────────────────────────────────────────────────────
if ($SkipPsExec) {
    Invoke-Cleanup
} else {
    # Download PsExec64 to run as SYSTEM (TrustedInstaller-owned keys)
    $tempDir    = Join-Path $env:TEMP "PSTools"
    $zipPath    = "$tempDir.zip"
    $psexecPath = Join-Path $tempDir "PsExec64.exe"

    if (-not (Test-Path $psexecPath)) {
        Write-Host "[*] Downloading Sysinternals PsExec ..." -ForegroundColor Cyan
        if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir -Force | Out-Null }
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri "https://download.sysinternals.com/files/PSTools.zip" -OutFile $zipPath -UseBasicParsing
            Expand-Archive -Path $zipPath -DestinationPath $tempDir -Force
            Remove-Item -Path $zipPath -Force
        } catch {
            Write-Host "[!] Failed to download PsExec: $_" -ForegroundColor Red
            Write-Host "    Falling back to direct (elevated) mode." -ForegroundColor Yellow
            Invoke-Cleanup
            exit
        }
    }

    # Re-launch this same script as SYSTEM with -SkipPsExec so the
    # child runs inline instead of trying to download PsExec again.
    Write-Host "[*] Launching cleanup as SYSTEM via PsExec ..." -ForegroundColor Cyan
    $selfPath = $MyInvocation.MyCommand.Path
    Start-Process -FilePath $psexecPath `
        -ArgumentList "-accepteula -nobanner -s powershell.exe -ExecutionPolicy Bypass -File `"$selfPath`" -SkipPsExec" `
        -Wait -NoNewWindow
}
