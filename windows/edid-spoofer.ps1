<#
.SYNOPSIS
    Zero out monitor serial numbers from EDID and write EDID_OVERRIDE to
    the registry so anti-cheat cannot fingerprint your display.

.DESCRIPTION
    Many anti-cheat systems read the raw EDID (Extended Display
    Identification Data) from WMI to collect a unique monitor serial
    number and use it as a hardware fingerprint.

    This script:
      1. Reads each connected monitor's full EDID (base + extension blocks)
         via WMI (WmiMonitorDescriptorMethods).
      2. Zeroes out:
         - Bytes 12-15 (manufacturer-assigned ID serial number)
         - Any 18-byte Display Descriptor of type 0xFF (alphanumeric serial)
      3. Recomputes the base-block checksum (byte 127).
      4. Writes the modified blocks to the registry under each monitor's
         Device Parameters\EDID_OVERRIDE key.
      5. Optionally restarts the graphics driver so the override takes
         effect immediately without a reboot.

    Requires Administrator.

    Inspired by Scrut1ny/AutoVirt  (resources/scripts/Windows/edid-spoofer.ps1)
    — rewritten with clearer structure, backup support, per-block
      extension handling, and optional driver restart.

.PARAMETER NoDriverRestart
    Skip disabling/re-enabling the display adapter after writing the
    override.  The change will take effect on next reboot instead.

.PARAMETER BackupFirst
    Export each monitor's original EDID to
    $env:TEMP\edid-spoofer-backup\ as .bin files (default: $true).

.PARAMETER Restore
    Remove all EDID_OVERRIDE keys and restart the driver, reverting to
    the monitor's factory EDID.

.EXAMPLE
    .\edid-spoofer.ps1
    .\edid-spoofer.ps1 -NoDriverRestart
    .\edid-spoofer.ps1 -Restore
#>

[CmdletBinding()]
param(
    [switch] $NoDriverRestart,
    [bool]   $BackupFirst = $true,
    [switch] $Restore
)

# ── Guard ───────────────────────────────────────────────────────────────
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]$identity
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[!] This script must be run as Administrator." -ForegroundColor Red
    exit 1
}

function Write-Banner {
    $banner = @"

  ╔══════════════════════════════════════════╗
  ║         EDID Serial Spoofer              ║
  ║  ProxMox-RealPC-DeployScripts            ║
  ╚══════════════════════════════════════════╝

"@
    Write-Host $banner -ForegroundColor Cyan
}

function Restart-GraphicsDriver {
    if ($NoDriverRestart) {
        Write-Host "`n  [SKIP] Driver restart skipped (-NoDriverRestart). Reboot to apply." -ForegroundColor Yellow
        return
    }
    Write-Host "`n[*] Restarting display adapter(s) ..." -ForegroundColor White
    Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -eq 'OK' } |
        ForEach-Object {
            try {
                Disable-PnpDevice -InstanceId $_.InstanceId -Confirm:$false -ErrorAction Stop
                Start-Sleep -Milliseconds 500
                Enable-PnpDevice  -InstanceId $_.InstanceId -Confirm:$false -ErrorAction Stop
                Write-Host "  [OK ] $($_.FriendlyName)" -ForegroundColor Green
            } catch {
                Write-Host "  [ERR] $($_.FriendlyName) - $_" -ForegroundColor Yellow
            }
        }
}

Write-Banner

# ── Restore mode ────────────────────────────────────────────────────────
if ($Restore) {
    Write-Host "[*] Removing all EDID_OVERRIDE keys ..." -ForegroundColor White
    $wmiMonitors = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorDescriptorMethods -ErrorAction SilentlyContinue
    $removed = 0
    foreach ($mon in $wmiMonitors) {
        $pnpId   = $mon.InstanceName -replace "_0$", ""
        $regPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$pnpId\Device Parameters\EDID_OVERRIDE"
        if (Test-Path -LiteralPath $regPath) {
            Remove-Item -LiteralPath $regPath -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "  [DEL] $regPath" -ForegroundColor Green
            $removed++
        }
    }
    if ($removed -eq 0) { Write-Host "  No overrides found." -ForegroundColor DarkGray }
    Restart-GraphicsDriver
    Write-Host "`n  Factory EDID restored.`n" -ForegroundColor Cyan
    exit 0
}

# ── Spoof mode ──────────────────────────────────────────────────────────
$backupDir = Join-Path $env:TEMP "edid-spoofer-backup"
if ($BackupFirst -and -not (Test-Path $backupDir)) {
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
}

$wmiMonitors = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorDescriptorMethods -ErrorAction SilentlyContinue
if (-not $wmiMonitors) {
    Write-Host "[!] No monitors found via WMI." -ForegroundColor Red
    exit 1
}

$monIdx = 0
foreach ($wmiMon in $wmiMonitors) {
    $monIdx++
    $pnpId = $wmiMon.InstanceName -replace "_0$", ""
    Write-Host "`n[Monitor $monIdx] $pnpId" -ForegroundColor White

    # ── 1. Read full EDID (base + extensions) ───────────────────────────
    try {
        $block0 = [byte[]](Invoke-CimMethod -InputObject $wmiMon `
                    -MethodName WmiGetMonitorRawEEdidV1Block `
                    -Arguments @{ BlockId = 0 }).BlockContent
        if (-not $block0 -or $block0.Length -lt 128) {
            Write-Host "  [SKIP] Cannot read base EDID block." -ForegroundColor DarkGray
            continue
        }
    } catch {
        Write-Host "  [SKIP] WMI read failed: $_" -ForegroundColor DarkGray
        continue
    }

    $edidBlocks = [System.Collections.Generic.List[byte[]]]::new()
    $edidBlocks.Add($block0)

    # Extension blocks (byte 126 = extension count)
    $extCount = $block0[126]
    for ($b = 1; $b -le $extCount; $b++) {
        try {
            $ext = [byte[]](Invoke-CimMethod -InputObject $wmiMon `
                        -MethodName WmiGetMonitorRawEEdidV1Block `
                        -Arguments @{ BlockId = $b }).BlockContent
            if ($ext) { $edidBlocks.Add($ext) }
        } catch { }
    }

    # ── 2. Backup original ──────────────────────────────────────────────
    if ($BackupFirst) {
        $safeName = ($pnpId -replace '[\\\/]', '_') + ".bin"
        $binPath  = Join-Path $backupDir $safeName
        # Concatenate all blocks into a single byte[] using MemoryStream
        # (plain += promotes to object[] which breaks WriteAllBytes)
        $ms = [System.IO.MemoryStream]::new()
        try {
            foreach ($blk in $edidBlocks) { $ms.Write($blk, 0, $blk.Length) }
            [IO.File]::WriteAllBytes($binPath, $ms.ToArray())
        } finally {
            $ms.Dispose()
        }
        Write-Host "  [BAK] $binPath" -ForegroundColor DarkGray
    }

    # ── 3. Patch base block ─────────────────────────────────────────────
    $target = $edidBlocks[0]

    # Bytes 12-15: manufacturer-assigned ID serial → zero
    $target[12] = $target[13] = $target[14] = $target[15] = 0
    Write-Host "  [ZAP] Bytes 12-15 (ID serial) zeroed" -ForegroundColor Green

    # 18-byte display descriptors at offsets 54, 72, 90, 108
    # Type 0xFF = Monitor Serial Number (ASCII)
    foreach ($off in 54, 72, 90, 108) {
        if ($off + 17 -ge $target.Length) { continue }
        if ($target[$off]   -eq 0x00 -and
            $target[$off+1] -eq 0x00 -and
            $target[$off+2] -eq 0x00 -and
            $target[$off+3] -eq 0xFF) {
            [Array]::Clear($target, $off, 18)
            Write-Host "  [ZAP] Descriptor at offset $off (0xFF serial) zeroed" -ForegroundColor Green
        }
    }

    # Recompute checksum (byte 127): (sum of bytes 0-127) mod 256 == 0
    $sum = 0
    for ($i = 0; $i -lt 127; $i++) { $sum += $target[$i] }
    $target[127] = (-$sum) -band 0xFF
    Write-Host "  [FIX] Checksum recomputed: 0x$('{0:X2}' -f $target[127])" -ForegroundColor DarkCyan

    $edidBlocks[0] = $target

    # ── 4. Write to registry ────────────────────────────────────────────
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$pnpId\Device Parameters"
    if (-not (Test-Path $regPath)) {
        Write-Host "  [SKIP] Registry path not found: $regPath" -ForegroundColor DarkGray
        continue
    }

    $overridePath = Join-Path $regPath "EDID_OVERRIDE"
    if (-not (Test-Path -LiteralPath $overridePath)) {
        New-Item -Path $overridePath -Force | Out-Null
    }

    for ($i = 0; $i -lt $edidBlocks.Count; $i++) {
        Set-ItemProperty -LiteralPath $overridePath -Name $i.ToString() `
                         -Value $edidBlocks[$i] -Type Binary -Force
    }
    Write-Host "  [SET] EDID_OVERRIDE written ($($edidBlocks.Count) block(s))" -ForegroundColor Green
}

# ── 5. Restart driver ──────────────────────────────────────────────────
Restart-GraphicsDriver

# ── Summary ─────────────────────────────────────────────────────────────
Write-Host "`n────────────────────────────────────────────" -ForegroundColor Cyan
Write-Host "  Processed $monIdx monitor(s)." -ForegroundColor Green
if ($BackupFirst) {
    Write-Host "  Backups: $backupDir" -ForegroundColor DarkGray
}
Write-Host "  Use -Restore to revert to factory EDID." -ForegroundColor DarkGray
Write-Host "────────────────────────────────────────────`n" -ForegroundColor Cyan
