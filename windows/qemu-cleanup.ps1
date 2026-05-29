# qemu-cleanup.ps1 — Remove VM fingerprints from a Windows guest
#
# Structure mirrors Scrut1ny/AutoVirt's qemu-cleanup.ps1: download PSTools,
# build a here-string cleanup payload, run it as SYSTEM via PsExec64 so we can
# reach Enum, Services, and DriverStore keys that even an elevated user can't
# touch.
#
# Deliberate differences from AutoVirt:
#   * AutoVirt deletes EVERY subkey under Enum\SCSI ("Remove-AllSubKeys $scsiRoot").
#     This nukes the active SATA/AHCI boot disk's registry entries on most PVE
#     setups because Windows enumerates SATA disks through the SCSI miniport
#     driver. We instead pattern-filter Enum\SCSI with the same VM-signature
#     list as the rest of the Enum tree so legitimate disks survive.
#   * Pattern list expanded from 3 entries to 30+ (VirtIO/QEMU/Bochs/VBOX/VMware/
#     KVM/Red Hat/Spice/QXL/balloon/pvpanic/qemufwcfg + ACPI sig strings).
#   * Added cleanup layers: DriverStore FileRepository, hidden/ghost PnP devices
#     via pnputil, event logs (System/Application/Setup), Prefetch traces,
#     Task Scheduler entries, setupapi.dev.log, WER reports, and BIOS/CPU
#     registry leak validation with warnings.
#
# Set execution policy to bypass for the process
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force

$downloadUrl     = "https://download.sysinternals.com/files/PSTools.zip"
$tempDir         = "$env:TEMP\PSTools"
$zipPath         = "$tempDir.zip"
$psexecPath      = Join-Path $tempDir "PsExec64.exe"
$cleanupScriptPath = Join-Path $tempDir "cleanup.ps1"

# Download and extract PSTools only if PsExec64.exe is missing.
# We don't pin a SHA256 (Sysinternals updates PsExec on its own cadence —
# pinning would create unbounded maintenance burden). Instead:
#   1. Force TLS 1.2 (Invoke-WebRequest's defaults vary by PS version).
#   2. After extraction, verify the Authenticode signature on PsExec64.exe is
#      valid AND issued to Microsoft. Refuse to run if either check fails.
#   3. Unblock-File to clear the Mark-of-the-Web so we don't trigger the
#      "downloaded from internet" prompt under PsExec.
if (-not (Test-Path $psexecPath)) {
    if (-not (Test-Path $tempDir)) {
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
    try {
        Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath -UseBasicParsing -ErrorAction Stop
    } catch {
        Write-Host "[X] Failed to download PSTools.zip: $_" -ForegroundColor Red
        Write-Host "    Manually download from $downloadUrl and extract to $tempDir, then re-run." -ForegroundColor Yellow
        exit 1
    }
    Expand-Archive -Path $zipPath -DestinationPath $tempDir -Force
    Remove-Item -Path $zipPath -Force
    Get-ChildItem $tempDir -Filter *.exe | ForEach-Object { Unblock-File $_.FullName -ErrorAction SilentlyContinue }
}

# Verify Authenticode signature on PsExec64.exe before we hand it SYSTEM rights.
$sig = Get-AuthenticodeSignature -FilePath $psexecPath -ErrorAction SilentlyContinue
if ($null -eq $sig -or $sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Microsoft Corporation') {
    Write-Host "[X] PsExec64.exe signature check failed (Status=$($sig.Status), Subject=$($sig.SignerCertificate.Subject))." -ForegroundColor Red
    Write-Host "    Refusing to run an unverified binary as SYSTEM. Delete $tempDir and try again, or run cleanup payload manually." -ForegroundColor Yellow
    exit 1
}

# Cleanup script as a string, executed as SYSTEM via PsExec
$cleanupScript = @'
$enumRoot      = "HKLM:\SYSTEM\CurrentControlSet\Enum"
$scsiRoot      = Join-Path $enumRoot "SCSI"
$servicesRoot  = "HKLM:\SYSTEM\CurrentControlSet\Services"
$classRoot     = "HKLM:\SYSTEM\CurrentControlSet\Control\Class"

# Expanded signature list covering QEMU, VirtIO, Bochs, VirtualBox, VMware (legacy),
# and Red Hat device/vendor IDs. v10.2.1 changed PCI-IDs for stdvga/vmware/virtio-gpu,
# but older artifacts may still exist from previous installs.
#
# v10.2.1 PCI-ID changes (these are the NEW patched values — NOT targeted here):
#   Standard VGA: no longer 0x1234 (patched to non-detectable value)
#   VMware compat: no longer 0x15ad (patched to non-detectable value)
#   VirtIO-GPU:    no longer 0x1af4 (patched to non-detectable value)
# We target the OLD stock QEMU IDs below to clean up artifacts from:
#   - Initial Windows PnP device enumeration during install
#   - Previous unpatched QEMU installs
#   - Cached driver store entries from VirtIO/QEMU guest tools
$searchStrings = @(
    "VEN_1AF4",        # Red Hat (VirtIO)
    "DEV_1B36",        # QEMU PCIe bridge / Spice display
    "SUBSYS_11001AF4", # VirtIO subsystem
    "VEN_1234",        # Bochs / QEMU Standard VGA (pre-v10.2.1)
    "DEV_0627",        # QEMU VGA subsystem
    "VEN_15AD",        # VMware (pre-v10.2.1 PCI-ID)
    "QEMU",            # QEMU strings in device descriptions
    "BOCHS",           # Bochs strings in device descriptions
    "VirtIO",          # VirtIO strings in device names
    "VBOX",            # VirtualBox artifacts
    "Red Hat",         # Red Hat vendor strings (VirtIO)
    "DEV_1050",        # VirtIO-GPU (legacy PCI-ID)
    "DEV_1053",        # VirtIO-GPU GL (legacy PCI-ID)
    "SUBSYS_00001AF4", # VirtIO subsystem variant
    "VEN_1D6B",        # Linux Foundation (vhost-user)
    "PCI\\VEN_1B36",   # QEMU XHCI / PCIe root (full path pattern)
    "S3 Corp",         # VMAware firmware string signature
    "FWCF",            # QEMU firmware config device signature
    "WAET",            # VMware ACPI WAET table signature
    "VS2005R2",        # Bochs VGA legacy version string
    "KVMKVMKVM",      # KVM hypervisor CPUID signature residue
    "DEV_1100",        # QEMU PCIe Host Bridge device ID
    "pvpanic",         # QEMU PV Panic device
    "qemufwcfg",       # QEMU fw_cfg device driver
    "QXL",             # QXL display adapter
    "Balloon",         # QEMU memory balloon device service
    "viogpu",          # VirtIO GPU display adapter
    "VMSVGA",          # VMware SVGA display adapter artifact
    "vmwgfx"           # VMware graphics driver artifact
)

function Remove-KeysMatching {
    param(
        [string]$Root,
        [string[]]$Patterns
    )
    # Build a single anchored regex from $Patterns. We require each pattern to
    # be flanked by a registry-path delimiter (backslash, ampersand, slash) or
    # by start/end-of-string, so substring collisions with legitimate vendor
    # strings can't accidentally trigger deletion.
    #     bad:  *DEV_1100*  matches a perfectly legit DEV_11005 (Intel chipset)
    #    good:  (?<=\\|&|/|^)DEV_1100(?=\\|&|/|$|\.)
    $escaped = $Patterns | ForEach-Object { [regex]::Escape($_) }
    $combined = '(?:(?<=[\\&/])|^)(?:' + ($escaped -join '|') + ')(?:(?=[\\&/.])|$)'
    $keys = Get-ChildItem -Path $Root -Recurse -ErrorAction SilentlyContinue
    foreach ($key in $keys) {
        if ($key.PSPath -match $combined) {
            try {
                Remove-Item -Path $key.PSPath -Recurse -Force -ErrorAction Stop
                Write-Host "Deleted (match): $($key.PSPath)"
            } catch {
                Write-Host "Failed (match): $($key.PSPath) - $_"
            }
        }
    }
}

# Scan the entire Enum tree for the target PCI/device signatures
if (Test-Path $enumRoot) {
    Remove-KeysMatching -Root $enumRoot -Patterns $searchStrings
}

# Also scan Services and Control\Class for VM driver entries
if (Test-Path $servicesRoot) {
    Remove-KeysMatching -Root $servicesRoot -Patterns $searchStrings
}
if (Test-Path $classRoot) {
    Remove-KeysMatching -Root $classRoot -Patterns $searchStrings
}

# Clean Enum\SCSI of VM-related entries only (preserve legitimate SATA/NVMe disk entries)
# Remove-AllSubKeys is too aggressive — it nukes the active boot disk's registry keys
# since Windows registers AHCI/SATA disks under Enum\SCSI via the SCSI miniport driver.
if (Test-Path $scsiRoot) {
    Remove-KeysMatching -Root $scsiRoot -Patterns $searchStrings
}

# Clean DriverStore FileRepository — remove VirtIO/QEMU driver packages
$driverStore = "$env:SystemRoot\System32\DriverStore\FileRepository"
if (Test-Path $driverStore) {
    $driverPatterns = @("vio*", "qemu*", "balloon*", "virtio*", "red_hat*", "netkvm*", "pvpanic*", "spice*", "qxl*", "viogpu*")
    foreach ($pattern in $driverPatterns) {
        Get-ChildItem -Path $driverStore -Directory -Filter $pattern -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                Remove-Item -Path $_.FullName -Recurse -Force -ErrorAction Stop
                Write-Host "Deleted (DriverStore): $($_.FullName)"
            } catch {
                Write-Host "Failed (DriverStore): $($_.FullName) - $_"
            }
        }
    }
}

# Remove hidden/ghost PnP devices with VM signatures
$vmPnpPatterns = @('VEN_1AF4', 'VEN_1234', 'VEN_15AD', 'DEV_1B36', 'QEMU', 'VirtIO', 'BOCHS', 'VBOX', 'pvpanic', 'qemufwcfg', 'VMSVGA', 'vmwgfx')
try {
    $allDevices = Get-PnpDevice -ErrorAction SilentlyContinue
    foreach ($dev in $allDevices) {
        foreach ($pat in $vmPnpPatterns) {
            if ($dev.InstanceId -like "*$pat*") {
                try {
                    & pnputil /remove-device "$($dev.InstanceId)" 2>&1 | Out-Null
                    Write-Host "Removed PnP device: $($dev.InstanceId)"
                } catch {
                    Write-Host "Failed to remove PnP device: $($dev.InstanceId)"
                }
                break
            }
        }
    }
} catch {
    Write-Host "PnP device enumeration not available: $_"
}

# Clear event logs that may contain VM-related entries
foreach ($logName in @('System', 'Application', 'Setup')) {
    try { & wevtutil cl $logName 2>&1 | Out-Null; Write-Host "Cleared log: $logName" }
    catch { Write-Host "Failed to clear log: $logName" }
}

# Clean prefetch files for VM-related executables
$prefetchDir = "$env:SystemRoot\Prefetch"
if (Test-Path $prefetchDir) {
    foreach ($pfPattern in @('*QEMU*', '*VIRTIO*', '*BALLOON*', '*NETKVM*', '*VIOSTOR*', '*VIOSCSI*', '*SPICE*', '*VBOX*')) {
        Get-ChildItem -Path $prefetchDir -Filter $pfPattern -ErrorAction SilentlyContinue |
            ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue; Write-Host "Deleted prefetch: $($_.Name)" }
    }
}

# Clean Task Scheduler tasks that may reference VM tools.
# Get-ScheduledTask isn't shipped on every Windows SKU (some Server LTSC and
# debloated builds strip the ScheduledTasks PS module). Guard it so the rest
# of the payload (setupapi log scrub, WER cleanup) still runs.
if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
    $vmTaskPatterns = @('*QEMU*', '*VirtIO*', '*Spice*', '*qemu-ga*', '*balloon*')
    foreach ($pattern in $vmTaskPatterns) {
        Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like $pattern } | ForEach-Object {
            try { Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false -ErrorAction Stop; Write-Host "Removed task: $($_.TaskName)" }
            catch { Write-Host "Failed to remove task: $($_.TaskName)" }
        }
    }
} else {
    Write-Host "Get-ScheduledTask unavailable (debloated build) - skipping scheduled-task scrub"
}

# Validate BIOS/SMBIOS registry entries for residual VM strings
# Detection tools (VMAware, pafish, al-khaser) scan this path directly rather than
# doing live SMBIOS queries — values are populated at boot from SMBIOS tables.
# If the patched QEMU provides correct SMBIOS, these should be clean. Log warnings
# for any that still contain VM-identifying strings.
$biosRegPath = "HKLM:\HARDWARE\DESCRIPTION\System\BIOS"
$vmBiosStrings = @("QEMU", "BOCHS", "VBOX", "Virtual", "VMware", "SeaBIOS", "OVMF", "KVM", "Red Hat", "innotek")
if (Test-Path $biosRegPath) {
    $biosProps = Get-ItemProperty -Path $biosRegPath -ErrorAction SilentlyContinue
    foreach ($prop in $biosProps.PSObject.Properties) {
        if ($prop.Value -is [string]) {
            foreach ($vmStr in $vmBiosStrings) {
                if ($prop.Value -match [regex]::Escape($vmStr)) {
                    Write-Host "WARNING: BIOS registry leak: $($prop.Name) = $($prop.Value) (contains '$vmStr')" -ForegroundColor Red
                }
            }
        }
    }
}

# Validate processor registry (CPUID brand string cache)
# Windows caches CPU brand string at HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0
# With cpu host + hypervisor=off, this should show the real host CPU.
$cpuRegPath = "HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0"
if (Test-Path $cpuRegPath) {
    $cpuName = (Get-ItemProperty -Path $cpuRegPath -Name "ProcessorNameString" -ErrorAction SilentlyContinue).ProcessorNameString
    if ($cpuName -and ($cpuName -match "QEMU|Virtual|KVM")) {
        Write-Host "WARNING: CPU registry leak: ProcessorNameString = $cpuName" -ForegroundColor Red
    }
}

# Clean setupapi logs — device installation traces that record VM hardware PnP events
# These logs can reveal that VirtIO/QEMU devices were enumerated during install
$setupApiLogs = @(
    "$env:SystemRoot\INF\setupapi.dev.log",
    "$env:SystemRoot\INF\setupapi.app.log",
    "$env:SystemRoot\INF\setupapi.dev.log.old",
    "$env:SystemRoot\INF\setupapi.app.log.old"
)
foreach ($log in $setupApiLogs) {
    if (Test-Path $log) {
        try {
            Remove-Item $log -Force -ErrorAction Stop
            Write-Host "Deleted setup log: $log"
        } catch {
            # Log may be locked by a service — truncate instead
            try { Set-Content -Path $log -Value "" -Force -ErrorAction Stop; Write-Host "Truncated setup log: $log" }
            catch { Write-Host "Failed to clean: $log" }
        }
    }
}

# Clean Windows Error Reporting (WER) reports that may reference VM hardware
$werDir = "$env:ProgramData\Microsoft\Windows\WER"
if (Test-Path $werDir) {
    Get-ChildItem -Path $werDir -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "QEMU|VirtIO|BOCHS|VBOX|balloon" } |
        ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue; Write-Host "Deleted WER report: $($_.Name)" }
}
'@

# Write the payload as BOM-less UTF-8. PS 5.1's `Set-Content -Encoding UTF8`
# writes a BOM which some PowerShell host versions choke on when invoked via
# `powershell -File ...` under PsExec64.
[System.IO.File]::WriteAllText($cleanupScriptPath, $cleanupScript, [System.Text.UTF8Encoding]::new($false))

Start-Process -FilePath $psexecPath -ArgumentList "-accepteula -nobanner -s powershell -ExecutionPolicy Bypass -File `"$cleanupScriptPath`"" -WindowStyle Hidden -Wait

# Uncomment if you want to remove the temp folder after execution
# Remove-Item -Path $tempDir -Recurse -Force
