$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]$identity

if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[!] Script must be run as Administrator." -ForegroundColor Red
    exit 1
}

Write-Host "[*] EDID Spoofer: Randomizing monitor serial numbers..." -ForegroundColor Cyan

# Get monitors via WMI for full EDID data
$wmiMonitors = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorDescriptorMethods

foreach ($wmiMon in $wmiMonitors) {
    # --- 1. Fetch Full EDID (Base + Extensions) ---
	try {
		$block0 = [byte[]](Invoke-CimMethod -InputObject $wmiMon -MethodName WmiGetMonitorRawEEdidV1Block -Arguments @{ BlockId = 0 }).BlockContent
		if (-not $block0) { continue }
	} catch { continue }

    # Initialize block list
    $edidBlocks = @(,$block0)

	# Fetch extension block if flagged (Byte 126)
	$extCount = $block0[126]
	for ($b = 1; $b -le $extCount; $b++) {
		try {
			$edidBlocks += ,([byte[]](Invoke-CimMethod -InputObject $wmiMon -MethodName WmiGetMonitorRawEEdidV1Block -Arguments @{ BlockId = $b }).BlockContent)
		} catch { }
	}

    # --- 2. Modify Base Block ---
    $targetBlock = $edidBlocks[0]

	# EDID[12–15]: Manufacturer-assigned ID Serial Number randomized
	# Non-zero random serial is more realistic than zeroed (zero = "no serial assigned")
    $targetBlock[12] = Get-Random -Maximum 256
    $targetBlock[13] = Get-Random -Maximum 256
    $targetBlock[14] = Get-Random -Maximum 256
    $targetBlock[15] = Get-Random -Maximum 256
    # Ensure not all zero (zero = "no serial" which is suspicious for named monitors)
    if (($targetBlock[12] -bor $targetBlock[13] -bor $targetBlock[14] -bor $targetBlock[15]) -eq 0) { $targetBlock[12] = 1 }

	# EDID[54–125]: Display Descriptor Type 0xFF (Monitor Serial Number) zeroed (18-byte descriptors)
	foreach ($off in 54, 72, 90, 108) {
		if (
			$targetBlock[$off]     -eq 0x00 -and
			$targetBlock[$off + 1] -eq 0x00 -and
			$targetBlock[$off + 2] -eq 0x00 -and
			$targetBlock[$off + 3] -eq 0xFF
		) {
			# Randomize serial string in the 0xFF descriptor instead of blanking to 0x10 (dummy).
			# A blank/dummy descriptor says "no serial" — suspicious for real monitors.
			# Random 7-char alphanumeric serial is realistic and defeats cross-session fingerprinting.
			$chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
			$serial = -join ($chars.ToCharArray() | Get-Random -Count 7)
			# EDID 0xFF descriptor: [off+4]=reserved, [off+5..off+17]=13 bytes serial text
			# Format: serial chars + 0x0A terminator + 0x20 padding
			$targetBlock[$off + 4] = 0x00
			for ($j = 0; $j -lt 13; $j++) {
				if ($j -lt $serial.Length) { $targetBlock[$off + 5 + $j] = [byte][char]$serial[$j] }
				elseif ($j -eq $serial.Length) { $targetBlock[$off + 5 + $j] = 0x0A }
				else { $targetBlock[$off + 5 + $j] = 0x20 }
			}
		}
	}

	# EDID[127]: Checksum recomputed to satisfy (sum of bytes 0–127) % 256 = 0
	$sum = 0
	for ($i = 0; $i -lt 127; $i++) { $sum += $targetBlock[$i] }
	$targetBlock[127] = (-$sum) -band 0xFF

    # --- 3. Save to Registry ---
    $pnpId = $wmiMon.InstanceName -replace "_0$", ""
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$pnpId\Device Parameters"

    if (-not (Test-Path $regPath)) { continue }

    $overrideKeyPath = Join-Path -Path $regPath -ChildPath "EDID_OVERRIDE"

    if (-not (Test-Path -LiteralPath $overrideKeyPath)) {
        New-Item -Path $overrideKeyPath -Force | Out-Null
    }

    for ($i = 0; $i -lt $edidBlocks.Count; $i++) {
        Set-ItemProperty -LiteralPath $overrideKeyPath -Name $i.ToString() -Value $edidBlocks[$i] -Type Binary -Force
    }
}

Write-Host "[+] EDID override written for all detected monitors." -ForegroundColor Green

# --- 4. Restart Graphics Driver ---
Write-Host "[*] Restarting graphics driver to apply EDID changes..." -ForegroundColor Cyan
Get-PnpDevice -Class Display | Where-Object { $_.Status -eq 'OK' } |
ForEach-Object {
    try {
        Disable-PnpDevice -InstanceId $_.InstanceId -Confirm:$false -ErrorAction Stop
        Start-Sleep -Milliseconds 500
        Enable-PnpDevice  -InstanceId $_.InstanceId -Confirm:$false -ErrorAction Stop
    } catch {
        Write-Host "[!] Failed to restart display device $($_.InstanceId): $_" -ForegroundColor Yellow
    }
}
