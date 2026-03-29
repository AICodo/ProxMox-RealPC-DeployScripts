# ========== Cryptography ==========

function Get-RandomGuid {
    return [guid]::NewGuid().ToString()
}

Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name 'MachineGuid' -Type String -Value "$(Get-RandomGuid)" -Force

# ==================================



# ========== Install Date & Time ==========

# Generate random date between 2019-01-01 and 30 days before today
$randomDate = Get-Random -Minimum ([datetime]'2019-01-01').Ticks -Maximum (([datetime]::Now.AddDays(-30)).Ticks) | ForEach-Object {[datetime]$_}

# Convert to Unix timestamp and LDAP/FILETIME
$unixTimestamp = [int]($randomDate.ToUniversalTime() - [datetime]'1970-01-01').TotalSeconds
# Use integer arithmetic to avoid float64 precision loss on large timestamps
$ldapFileTime = [long]($unixTimestamp + 11644473600) * 10000000

# Update registry values with proper numeric types
$regPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
Set-ItemProperty -Path $regPath -Name "InstallDate" -Value ([int]$unixTimestamp) -Type DWord -Force
Set-ItemProperty -Path $regPath -Name "InstallTime" -Value ([long]$ldapFileTime) -Type QWord -Force

# Ensure time service is running and reconfigure
# Handle slim ISOs where w32time may be disabled or missing
$w32svc = Get-Service w32time -ErrorAction SilentlyContinue
if ($w32svc) {
    if ($w32svc.StartType -eq 'Disabled') {
        Set-Service w32time -StartupType Manual -ErrorAction SilentlyContinue
    }
    if ($w32svc.Status -ne 'Running') {
        Start-Service w32time -ErrorAction SilentlyContinue
    }
    w32tm /config /syncfromflags:manual /manualpeerlist:"0.pool.ntp.org,1.pool.ntp.org,2.pool.ntp.org,3.pool.ntp.org" /update 2>$null
    Restart-Service w32time -Force -ErrorAction SilentlyContinue
    w32tm /resync 2>$null
} else {
    Write-Host "[!] w32time service not found (common on slim ISOs) - skipping NTP sync" -ForegroundColor Yellow
}

# ==================================



# ========== Device/NetBIOS Names ==========

# [System.Environment]::MachineName

$RandomString = -join ([char[]](48..57 + 65..90) | Get-Random -Count 7)
Rename-Computer -NewName "DESKTOP-$RandomString" -Force *>$null

# ==================================



# ========== MAC Address ==========

# Use a realistic Intel OUI prefix (matches deploy script's e1000e NIC)
# Common Intel NIC OUI prefixes that won't trigger VM detection
$ouiPrefixes = @('D8FC93', '3C2AF4', 'A4BB6D', '8CDFB0', '48B02D', 'B4969B')
$oui = $ouiPrefixes | Get-Random
$suffix = ('{0:X}' -f (Get-Random -Maximum 0xFFFFFF)).PadLeft(6, '0')
$newMac = $oui + $suffix
$adapter = Get-NetAdapter | Where-Object {$_.Status -eq "Up"} | Select-Object -First 1
if ($adapter) {
    Set-NetAdapter -Name $adapter.Name -MacAddress "$newMac" -Confirm:$false
} else {
    Write-Host "[!] No active network adapter found - skipping MAC change" -ForegroundColor Yellow
}

# ==================================



# ========== ProductId ==========

$ntPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
$randomProductId = '{0:D5}-{1:D5}-{2:D5}-{3:D5}' -f (Get-Random -Max 99999), (Get-Random -Max 99999), (Get-Random -Max 99999), (Get-Random -Max 99999)
Set-ItemProperty -Path $ntPath -Name 'ProductId' -Type String -Value $randomProductId -Force

# ==================================



# ========== HardwareGUID ==========

$hwConfigPath = "HKLM:\SYSTEM\HardwareConfig"
if (Test-Path $hwConfigPath) {
    $lastConfig = (Get-ItemProperty -Path $hwConfigPath -Name 'LastConfig' -ErrorAction SilentlyContinue).LastConfig
    if ($lastConfig) {
        # Update the LastConfig GUID
        $newHwGuid = "{$([guid]::NewGuid().ToString())}"
        Set-ItemProperty -Path $hwConfigPath -Name 'LastConfig' -Type String -Value $newHwGuid -Force
        # Rename the subkey if it exists (create new, copy, remove old)
        $oldKeyPath = Join-Path $hwConfigPath $lastConfig
        if (Test-Path $oldKeyPath) {
            $newKeyPath = Join-Path $hwConfigPath $newHwGuid
            if (-not (Test-Path $newKeyPath)) {
                Copy-Item -Path $oldKeyPath -Destination $newKeyPath -Recurse -Force -ErrorAction SilentlyContinue
            }
            Remove-Item -Path $oldKeyPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ==================================



# ========== SQM MachineId ==========

$sqmPath = "HKLM:\SOFTWARE\Microsoft\SQMClient"
if (Test-Path $sqmPath) {
    Set-ItemProperty -Path $sqmPath -Name 'MachineId' -Type String -Value "{$([guid]::NewGuid().ToString())}" -Force
}

# ==================================



# ========== Windows Update SusClientId ==========

$wuPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate"
if (Test-Path $wuPath) {
    Set-ItemProperty -Path $wuPath -Name 'SusClientId' -Type String -Value "$([guid]::NewGuid().ToString())" -Force
    Set-ItemProperty -Path $wuPath -Name 'SusClientIdValidation' -Type Binary -Value ([byte[]](0..19 | ForEach-Object { Get-Random -Maximum 256 })) -Force -ErrorAction SilentlyContinue
}

# ==================================



# ========== Build GUID ==========

$ntCurVer = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
Set-ItemProperty -Path $ntCurVer -Name 'BuildGUID' -Type String -Value "$([guid]::NewGuid().ToString())" -Force -ErrorAction SilentlyContinue

# ==================================



# ========== Diagnostics Tracking ==========

$diagTrackPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack"
if (Test-Path $diagTrackPath) {
    Set-ItemProperty -Path $diagTrackPath -Name 'MachineId' -Type String -Value "$([guid]::NewGuid().ToString())" -Force -ErrorAction SilentlyContinue
}

# ==================================



# ========== Hardware Profile ID ==========

$profilePath = "HKLM:\SYSTEM\CurrentControlSet\Control\IDConfigDB\Hardware Profiles\0001"
if (Test-Path $profilePath) {
    Set-ItemProperty -Path $profilePath -Name 'HwProfileGuid' -Type String -Value "{$([guid]::NewGuid().ToString())}" -Force -ErrorAction SilentlyContinue
}

# ==================================



# ========== Windows Update PingID ==========

$wuPingPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate"
if (Test-Path $wuPingPath) {
    Set-ItemProperty -Path $wuPingPath -Name 'PingID' -Type String -Value "$([guid]::NewGuid().ToString())" -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $wuPingPath -Name 'AccountDomainSid' -Type String -Value "S-1-5-21-$(Get-Random -Max 999999999)-$(Get-Random -Max 999999999)-$(Get-Random -Max 999999999)" -Force -ErrorAction SilentlyContinue
}

# ==================================



# ========== AdvertisingInfo ==========

$adInfoPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo"
if (Test-Path $adInfoPath) {
    Set-ItemProperty -Path $adInfoPath -Name 'Id' -Type String -Value "$([guid]::NewGuid().ToString())" -Force -ErrorAction SilentlyContinue
} else {
    New-Item -Path $adInfoPath -Force | Out-Null
    Set-ItemProperty -Path $adInfoPath -Name 'Id' -Type String -Value "$([guid]::NewGuid().ToString())" -Force
}

# ==================================


# ========== Network Profile Cleanup ==========

# Network profiles persist across reboots and contain GUIDs, timestamps, and MACs
# that can be used for cross-session fingerprinting by anti-cheat systems.
$nlProfiles = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\Profiles"
if (Test-Path $nlProfiles) {
    Get-ChildItem -Path $nlProfiles -ErrorAction SilentlyContinue | ForEach-Object {
        Set-ItemProperty -Path $_.PSPath -Name 'ProfileGuid' -Type String -Value "{$([guid]::NewGuid().ToString())}" -Force -ErrorAction SilentlyContinue
    }
}

# Network signatures contain MAC addresses and SSIDs that fingerprint the environment
$nlSignatures = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\Signatures"
if (Test-Path $nlSignatures) {
    Get-ChildItem -Path $nlSignatures -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Item -Path $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ==================================



# ========== SMBIOS Registry Validation ==========

# Verify HKLM:\HARDWARE\DESCRIPTION\System\BIOS doesn't contain VM strings.
# These values are populated at boot from SMBIOS tables — if the patched QEMU
# provides correct SMBIOS, they should be clean. Detection tools (VMAware,
# pafish, al-khaser) scan this path directly.
$biosRegPath = "HKLM:\HARDWARE\DESCRIPTION\System\BIOS"
$vmBiosStrings = @("QEMU", "BOCHS", "VBOX", "Virtual Machine", "VMware", "SeaBIOS", "OVMF", "innotek")
if (Test-Path $biosRegPath) {
    $biosProps = Get-ItemProperty -Path $biosRegPath -ErrorAction SilentlyContinue
    $leaked = $false
    foreach ($prop in $biosProps.PSObject.Properties) {
        if ($prop.Value -is [string]) {
            foreach ($vmStr in $vmBiosStrings) {
                if ($prop.Value -match [regex]::Escape($vmStr)) {
                    Write-Host "[!] BIOS leak: $($prop.Name) contains '$vmStr' - SMBIOS spoofing may not be active" -ForegroundColor Red
                    $leaked = $true
                }
            }
        }
    }
    if (-not $leaked) {
        Write-Host "[+] SMBIOS registry validation passed (no VM strings detected)" -ForegroundColor Green
    }
}

# ==================================



# ========== Telemetry Device ID ==========

# Microsoft.Windows.DeviceMetadataRetrievalClient uses this for device identification
$deviceMetaPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Metadata"
if (Test-Path $deviceMetaPath) {
    Set-ItemProperty -Path $deviceMetaPath -Name 'DeviceMetadataServiceURL' -Type String -Value "" -Force -ErrorAction SilentlyContinue
}

# ==================================


# NOTE: Reboot is handled by run-tools.bat after all scripts complete.

