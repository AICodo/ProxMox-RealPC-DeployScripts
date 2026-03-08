<#
.SYNOPSIS
    Spoof Windows machine identifiers to defeat VM fingerprinting.

.DESCRIPTION
    Randomises or user-overrides the following identifiers that anti-cheat
    and detection software commonly fingerprint:

        1. MachineGuid          (HKLM:\SOFTWARE\Microsoft\Cryptography)
        2. InstallDate / Time   (HKLM:\...\Windows NT\CurrentVersion)
        3. Computer name        (DESKTOP-XXXXXXX)
        4. MAC address          (first active adapter)
        5. Windows Product ID   (HKLM:\...\Windows NT\CurrentVersion)
        6. HardwareGUID         (HKLM:\...\HardwareConfig)
        7. SQM / Telemetry ID   (HKLM:\SOFTWARE\Microsoft\SQMClient)
        8. Windows Update ID    (HKLM:\SOFTWARE\Microsoft\...WindowsUpdate)

    Requires Administrator.  A reboot is triggered at the end unless
    -NoReboot is specified.

    Inspired by Scrut1ny/AutoVirt  (resources/scripts/Windows/identifier-spoofer.ps1)
    - rewritten with wider coverage, parameterisation, backup/restore,
      and structured logging.

.PARAMETER ComputerName
    Override the random computer name.  Default: DESKTOP-<7 random chars>.

.PARAMETER MacAddress
    Override the random MAC.  Format: AABBCCDDEEFF (12 hex chars).

.PARAMETER NoReboot
    Do not restart the machine after applying changes.

.PARAMETER BackupFirst
    Export the current values to a .json restore file before changing them
    (default: $true).

.EXAMPLE
    .\identifier-spoofer.ps1
    .\identifier-spoofer.ps1 -ComputerName "DESKTOP-MYPC01" -NoReboot
    .\identifier-spoofer.ps1 -MacAddress "A4BB6D123456"
#>

[CmdletBinding()]
param(
    [string] $ComputerName,
    [string] $MacAddress,
    [switch] $NoReboot,
    [bool]   $BackupFirst = $true
)

# -- Guard ---------------------------------------------------------------
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]$identity
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[!] This script must be run as Administrator." -ForegroundColor Red
    exit 1
}

# -- Helpers -------------------------------------------------------------
function Get-RandomGuid   { [guid]::NewGuid().ToString() }
function Get-RandomHex($n){ -join (1..$n | ForEach-Object { '{0:X}' -f (Get-Random -Max 16) }) }
function Get-RandomAlphaNum($n) {
    $pool = [char[]](48..57 + 65..90)   # 0-9 A-Z
    -join (1..$n | ForEach-Object { $pool | Get-Random })
}

function Write-Banner {
    $banner = @"

  +==========================================+
  |     Windows Identifier Spoofer           |
  |  ProxMox-RealPC-DeployScripts            |
  +==========================================+

"@
    Write-Host $banner -ForegroundColor Cyan
}

# Backup store
$backupFile = Join-Path $env:TEMP "identifier-spoofer-backup.json"
$script:backup = @{}

function Save-Original {
    param([string]$Path, [string]$Name)
    try {
        $val = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name
        if ($null -ne $val) { $script:backup["$Path\$Name"] = $val }
    } catch { }
}

function Set-Reg {
    param(
        [string]$Path,
        [string]$Name,
        $Value,
        [string]$Type = "String"
    )
    if ($BackupFirst) { Save-Original -Path $Path -Name $Name }
    try {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force
        Write-Host "  [SET] $Name -> $Value" -ForegroundColor Green
    } catch {
        Write-Host "  [ERR] $Path\$Name - $_" -ForegroundColor Yellow
    }
}

# -- Begin ---------------------------------------------------------------
Write-Banner

$ntPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"

# -- 1. MachineGuid ------------------------------------------------------
Write-Host "[1/8] MachineGuid" -ForegroundColor White
$newGuid = Get-RandomGuid
Set-Reg -Path "HKLM:\SOFTWARE\Microsoft\Cryptography" -Name "MachineGuid" -Value $newGuid

# -- 2. InstallDate / InstallTime ----------------------------------------
Write-Host "[2/8] InstallDate / InstallTime" -ForegroundColor White
$dateParams = @{
    Year   = Get-Random -Min 2019 -Max 2026
    Month  = Get-Random -Min 1 -Max 13
    Day    = Get-Random -Min 1 -Max 29
    Hour   = Get-Random -Max 24
    Minute = Get-Random -Max 60
    Second = Get-Random -Max 60
}
$randomDate = Get-Date @dateParams
$unixTimestamp = [int]($randomDate.ToUniversalTime() - [datetime]'1970-01-01').TotalSeconds
$ldapFileTime  = [int64](($unixTimestamp + 11644473600) * [long]10000000)

Set-Reg -Path $ntPath -Name "InstallDate" -Value $unixTimestamp -Type "DWord"
Set-Reg -Path $ntPath -Name "InstallTime" -Value $ldapFileTime  -Type "QWord"

# Sync NTP so the clock does not look anomalous
try {
    Get-Service w32time -ErrorAction SilentlyContinue | Where-Object Status -ne Running | Start-Service
    & w32tm /config /syncfromflags:manual /manualpeerlist:"0.pool.ntp.org,1.pool.ntp.org,2.pool.ntp.org,3.pool.ntp.org" /update 2>$null | Out-Null
    Restart-Service w32time -Force -ErrorAction SilentlyContinue
    & w32tm /resync 2>$null | Out-Null
    Write-Host "  [OK ] NTP re-synced" -ForegroundColor DarkGray
} catch { }

# -- 3. Computer / NetBIOS name ------------------------------------------
Write-Host "[3/8] Computer Name" -ForegroundColor White
if (-not $ComputerName) { $ComputerName = "DESKTOP-" + (Get-RandomAlphaNum 7) }
try {
    Rename-Computer -NewName $ComputerName -Force -ErrorAction Stop *>$null
    Write-Host "  [SET] ComputerName -> $ComputerName" -ForegroundColor Green
} catch {
    Write-Host "  [ERR] Rename-Computer - $_" -ForegroundColor Yellow
}

# -- 4. MAC address ------------------------------------------------------
Write-Host "[4/8] MAC Address" -ForegroundColor White
$adapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1
if ($adapter) {
    if (-not $MacAddress) {
        # Generate a locally-administered unicast MAC (bit 1 of first octet = 1, bit 0 = 0)
        $firstByte  = (Get-Random -Max 256) -bor 0x02 -band 0xFE   # LA unicast
        $MacAddress = ('{0:X2}' -f $firstByte) + (Get-RandomHex 10)
    }
    try {
        Set-NetAdapter -Name $adapter.Name -MacAddress $MacAddress -Confirm:$false
        Write-Host "  [SET] $($adapter.Name) MAC -> $MacAddress" -ForegroundColor Green
    } catch {
        Write-Host "  [ERR] Set-NetAdapter - $_" -ForegroundColor Yellow
    }
} else {
    Write-Host "  [SKIP] No active adapter found" -ForegroundColor DarkGray
}

# -- 5. Windows ProductId ------------------------------------------------
Write-Host "[5/8] ProductId" -ForegroundColor White
# Format: XXXXX-XXX-XXXXXXX-XXXXX  (groups of 5-3-7-5 digits)
$newProdId = "{0}-{1}-{2}-{3}" -f (Get-RandomAlphaNum 5), (Get-RandomAlphaNum 3),
                                    (Get-RandomAlphaNum 7), (Get-RandomAlphaNum 5)
Set-Reg -Path $ntPath -Name "ProductId" -Value $newProdId
Set-Reg -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion" -Name "ProductId" -Value $newProdId

# -- 6. HardwareGUID (HardwareConfig) ------------------------------------
Write-Host "[6/8] HardwareGUID" -ForegroundColor White
$hwPath = "HKLM:\SYSTEM\CurrentControlSet\Control\IDConfigDB\Hardware Profiles\0001"
if (Test-Path $hwPath) {
    Set-Reg -Path $hwPath -Name "HwProfileGuid" -Value ("{$( Get-RandomGuid )}")
}
$hwCurrent = "HKLM:\SYSTEM\HardwareConfig"
if (Test-Path $hwCurrent) {
    Set-Reg -Path $hwCurrent -Name "LastConfig" -Value (Get-RandomGuid)
}

# -- 7. SQM / Telemetry MachineId ----------------------------------------
Write-Host "[7/8] SQM MachineId" -ForegroundColor White
$sqmPath = "HKLM:\SOFTWARE\Microsoft\SQMClient"
if (Test-Path $sqmPath) {
    Set-Reg -Path $sqmPath -Name "MachineId" -Value ("{$( Get-RandomGuid )}")
}

# -- 8. Windows Update SusClientId ---------------------------------------
Write-Host "[8/8] Windows Update SusClientId" -ForegroundColor White
$wuPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate"
if (Test-Path $wuPath) {
    Set-Reg -Path $wuPath -Name "SusClientId"             -Value (Get-RandomGuid)
    Set-Reg -Path $wuPath -Name "SusClientIdValidation"   -Value (Get-RandomGuid)
    Set-Reg -Path $wuPath -Name "AccountDomainSid"        -Value ""
    Set-Reg -Path $wuPath -Name "PingID"                  -Value ""
}

# -- Backup --------------------------------------------------------------
if ($BackupFirst -and $script:backup.Count -gt 0) {
    $script:backup | ConvertTo-Json -Depth 3 | Set-Content -Path $backupFile -Encoding UTF8
    Write-Host "`n  Backup saved: $backupFile" -ForegroundColor DarkGray
}

# -- Summary -------------------------------------------------------------
Write-Host "`n--------------------------------------------" -ForegroundColor Cyan
Write-Host "  All identifiers updated." -ForegroundColor Green
if (-not $NoReboot) {
    Write-Host "  Rebooting in 5 seconds ... (Ctrl+C to cancel)" -ForegroundColor Yellow
    Start-Sleep -Seconds 5
    shutdown /r /t 0
} else {
    Write-Host "  Reboot skipped (-NoReboot).  Restart manually for all changes to take effect." -ForegroundColor Yellow
}
Write-Host "--------------------------------------------`n" -ForegroundColor Cyan
