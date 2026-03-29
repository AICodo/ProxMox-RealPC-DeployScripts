# ========== Cryptography ==========

function Get-RandomGuid {
    return [guid]::NewGuid().ToString()
}

Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name 'MachineGuid' -Type String -Value "$(Get-RandomGuid)" -Force

# ==================================



# ========== Install Date & Time ==========

# Generate random date between 2017-01-01 and 2025-06-30
$randomDate = Get-Random -Minimum ([datetime]'2019-01-01').Ticks -Maximum (([datetime]'2026-02-01').Ticks) | ForEach-Object {[datetime]$_}

# Convert to Unix timestamp and LDAP/FILETIME
$unixTimestamp = [int]($randomDate.ToUniversalTime() - [datetime]'1970-01-01').TotalSeconds
# Use integer arithmetic to avoid float64 precision loss on large timestamps
$ldapFileTime = [long]($unixTimestamp + 11644473600) * 10000000

# Update registry values with proper numeric types
$regPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
Set-ItemProperty -Path $regPath -Name "InstallDate" -Value $unixTimestamp -Force
Set-ItemProperty -Path $regPath -Name "InstallTime" -Value $ldapFileTime -Force

# Ensure time service is running and reconfigure
Get-Service w32time | Where Status -ne Running | Start-Service
w32tm /config /syncfromflags:manual /manualpeerlist:"0.pool.ntp.org,1.pool.ntp.org,2.pool.ntp.org,3.pool.ntp.org" /update
Restart-Service w32time -Force; w32tm /resync

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


# NOTE: Reboot is handled by run-tools.bat after all scripts complete.

