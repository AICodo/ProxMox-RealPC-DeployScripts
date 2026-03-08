# ========== Cryptography ==========

function Get-RandomGuid {
    return [guid]::NewGuid().ToString()
}

Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name 'MachineGuid' -Type String -Value "$(Get-RandomGuid)" -Force

# ==================================



# ========== Install Date & Time ==========

# Generate random date between 2011-01-01 and 2022-12-31
$randomDate = Get-Random -Minimum ([datetime]'2011-01-01').Ticks -Maximum (([datetime]'2022-12-31').Ticks) | ForEach-Object {[datetime]$_}

# Convert to Unix timestamp and LDAP/FILETIME
$unixTimestamp = [int]($randomDate.ToUniversalTime() - [datetime]'1970-01-01').TotalSeconds
$ldapFileTime = [int64](($unixTimestamp + 11644473600) * 1e7)

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
$adapter = (Get-NetAdapter | Where-Object {$_.Status -eq "Up"} | Select-Object -First 1).Name
Set-NetAdapter -Name "$adapter" -MacAddress "$newMac" -Confirm:$false

# ==================================


# NOTE: Reboot is handled by run-tools.bat after all scripts complete.

