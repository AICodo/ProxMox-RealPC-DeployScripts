# ProxMox-RealPC-DeployScripts

Automated deployment scripts for installing [pve-emu-realpc](https://github.com/AICodo/pve-emu-realpc) anti-VM-detection packages on Proxmox VE and creating fully cloaked Windows VMs that pass common virtualization checks.

---

## Table of Contents

- [Background](#background)
- [What These Scripts Do](#what-these-scripts-do)
- [Anti-Detection Layers](#anti-detection-layers)
- [Requirements](#requirements)
- [Quick Start](#quick-start)
- [Script 1 — Host Setup (`pve-realpc-setup.sh`)](#script-1--host-setup)
- [Script 2 — VM Deployment (`pve-realpc-deploy-vm.sh`)](#script-2--vm-deployment)
- [Windows Guest Tools (`windows/`)](#windows-guest-tools)
- [Post-Install Checklist (Inside the Guest)](#post-install-checklist-inside-the-guest)
- [Testing & Validation](#testing--validation)
- [Restoring Stock Packages](#restoring-stock-packages)
- [Upstream Sources & Credits](#upstream-sources--credits)
- [Related Repos & Resources](#related-repos--resources)
- [FAQ / Troubleshooting](#faq--troubleshooting)

---

## Background

Many applications and anti-cheat systems detect virtual machines by inspecting:

| Detection Vector | What They Look For |
|---|---|
| **String matching** | `"QEMU"`, `"BOCHS"`, `"KVMKVMKVM"` in firmware/device data |
| **SMBIOS tables** | Default virtual hardware profiles (Type 0/1/2/3/4/17) |
| **CPUID hypervisor bit** | `hypervisor` flag in CPUID leaf 1 |
| **ACPI tables** | Missing hardware — no fans, no thermal zones, no embedded controller |
| **Hardware devices** | VirtIO devices, virtual NICs, QEMU display adapters |
| **KVM signature** | `KVMKVMKVM` CPUID leaf 0x40000000 |

The [pve-emu-realpc](https://github.com/AICodo/pve-emu-realpc) project (forked from [zhaodice/qemu-anti-detection](https://github.com/zhaodice/qemu-anti-detection)) produces patched QEMU, OVMF, and KVM kernel module packages that address **all** of these vectors. The upstream anti-detection technique details are documented at the [pve-anti-detection DeepWiki](https://deepwiki.com/lixiaoliu666/pve-anti-detection).

**These scripts** automate the entire setup so you don't have to manually download packages, run `dpkg`, copy files, or hand-craft VM config arguments.

---

## What These Scripts Do

| Script | Purpose |
|---|---|
| `pve-realpc-setup.sh` | **One-time host preparation.** Downloads release assets from both PVE and Debian GitHub releases, backs up stock packages, installs patched QEMU + OVMF + KVM module, overlays patched ROM/BIOS files (removes VM strings from SeaBIOS/VGA/EFI), deploys ACPI tables, optionally configures Intel iGPU passthrough, sets a realistic MAC prefix, and pins packages against `apt upgrade`. |
| `pve-realpc-deploy-vm.sh` | **Per-VM creation.** Creates a fully configured Proxmox VM with OVMF/Q35, SATA disk, e1000 NIC, full SMBIOS spoofing (8 types), custom ACPI tables, hidden hypervisor, TSC pinning, CPU power-management passthrough, and more — all via a single command. |

---

## Anti-Detection Layers

The patched packages implement five layers of anti-detection, as described in the [upstream documentation](https://deepwiki.com/lixiaoliu666/pve-anti-detection):

### Layer 1 — String Obfuscation (sedPatch)
110+ `sed` replacements across 80+ QEMU source files:
- `QEMU` → `DELL`, `BOCHS` → `INTEL`, `RHT` → `DEL`
- `KVMKVMKVM` → null bytes (hides KVM CPUID signature)
- `VMware` → `GenuineIntel`

### Layer 2 — SMBIOS Hardware Spoofing
Custom `smbios.c` generates realistic hardware identity tables:
- **Type 0** — BIOS: American Megatrends International LLC.
- **Type 1** — System: Maxsun MS-Terminator B760M
- **Type 2** — Baseboard: Maxsun motherboard
- **Type 4** — Processor: Intel 12th Gen
- **Type 17** — Memory: Kingston DDR3

### Layer 3 — Firmware Customization
- Custom boot splash image (`bootsplash.jpg`) replaces QEMU default
- Patched OVMF (UEFI) firmware package (`pve-edk2-firmware-ovmf`)

### Layer 4 — ACPI Table Virtualization
Injected `.aml` tables add hardware that real PCs have but VMs normally lack:

| File | Provides |
|---|---|
| `ssdt.aml` | 6 fan devices + 8 thermal zones |
| `ssdt-ec.aml` | Embedded Controller (`EC__`) device |
| `hpet.aml` | High Precision Event Timer device |
| `ssdt-battery.aml` | Virtual battery (laptop mode / NVIDIA error 43 fix) |

### Layer 5 — Runtime VM Configuration
Applied by `pve-realpc-deploy-vm.sh` (matches upstream recommended args exactly):
- `-cpu host` with `hypervisor=off` (NO `kvm=off` — the patched binary hides KVM internally)
- `e1000` NIC with physical vendor MAC OUI (`D8:FC:93`)
- SATA disk with randomized serial (no VirtIO)
- Custom ACPI tables (`ssdt.aml`, `ssdt-ec.aml`, `hpet.aml`)
- Full SMBIOS spoofing (types 0,1,2,3,4,8,9,17)
- Balloon disabled
- **NO** `-smp` override (PVE's `cores:` handles topology — adding `-smp` causes thread count mismatch)
- **NO** timing args (patched binary handles TSC/HPET/PIT/RTC/NVRAM internally)
- **NO** extra CPU feature flags (patched binary handles CPUID hiding internally)
- **NO** `pre-enrolled-keys` (patched OVMF handles EFI variable sanitization internally)

> **Why so minimal?** The upstream author states: *"In QEMU 10, all args parameters are now handled internally except for what's shown above (others are hidden/customized)."* Adding extra flags like `kvm=off`, `-overcommit cpu-pm=on`, `-rtc`, `-smp`, `+invtsc`, `tsc-frequency=` etc. **conflicts** with the binary's built-in behavior and **causes** detection failures for timing anomalies, NVRAM, system timers, and thread count.

### Strong Build (Enhanced)
The **Strong** build (`_Strong.deb` packages + patched `kvm.ko`) adds CPU sensor passthrough — temperature, MHz, voltage, and power consumption are visible inside the Windows guest via CPU-Z, HWiNFO, HWMonitor. Supports both Intel and AMD CPUs.

---

## Requirements

- **Proxmox VE 8 or 9** (scripts target PVE 9 by default; PVE 8 releases also available upstream)
- **Root access** on the PVE host
- **Internet access** (to download release assets from GitHub)
- A **Windows ISO** uploaded to your PVE ISO storage (stock or slim/debloated — the deploy script lets you choose)
- **Intel or AMD** x86_64 CPU

---

## Quick Start

```bash
# 1. SSH into your Proxmox host as root

# 2. Download the scripts
git clone https://github.com/YOUR_USER/ProxMox-RealPC-DeployScripts.git
cd ProxMox-RealPC-DeployScripts

# 3. Run host setup (downloads ~100 MB, installs packages, ~2 min)
bash pve-realpc-setup.sh

# 4. Deploy a VM with all anti-detection measures
bash pve-realpc-deploy-vm.sh

# 5. Start the VM and install Windows
qm start <VMID>
```

---

## Script 1 — Host Setup

### `pve-realpc-setup.sh`

Automates all host-level preparation in 12 steps:

| Step | Action |
|---|---|
| 1 | Set MAC address prefix (`D8:FC:93` — Dell/Intel OUI) in `/etc/pve/datacenter.cfg` |
| 2 | Download PVE release assets from [AICodo/pve-emu-realpc `v20260306-213905-pve9`](https://github.com/AICodo/pve-emu-realpc/releases/tag/v20260306-213905-pve9) with SHA-256 verification |
| 3 | Download Debian release assets (patched ROM/BIOS files only) from [`v20260307-191041-debian`](https://github.com/AICodo/pve-emu-realpc/releases/tag/v20260307-191041-debian) |
| 4 | Back up stock QEMU binary, OVMF firmware, and KVM module to `/root/pve-realpc/backup/` |
| 5 | Install base anti-detection `.deb` packages (`pve-qemu-kvm`, `pve-edk2-firmware-ovmf`) |
| 6 | Extract and install **Strong** build packages (enhanced CPU sensor passthrough) |
| 7 | Overlay patched Debian ROM/BIOS/VGA files — replaces stock SeaBIOS/EFI/VGA ROMs that still contain `QEMU`/`Bochs`/`SeaBIOS` strings (PVE binary is preserved) |
| 8 | Install patched KVM kernel module (auto-detects Intel vs AMD); **auto-downgrades kernel** if version mismatches |
| 9 | Place ACPI table files (`ssdt.aml`, `ssdt-ec.aml`, `ssdt-battery.aml`, `hpet.aml`) into `/root/` |
| 10 | *(Optional)* Intel Ultra iGPU passthrough setup — downloads ROM, enables IOMMU, blacklists `i915`/`snd_hda_intel` (requires `--igpu`) |
| 11 | Pin packages via APT preferences + `dpkg hold` to prevent `apt upgrade` from overwriting |
| 12 | Verify installation — checks binary size, ROM files, ACPI tables, KVM module, and spot-checks ROMs for leftover VM strings |

### Usage

```bash
# Full run (download + install + pin)
bash pve-realpc-setup.sh

# Skip downloads (use previously downloaded files in /root/pve-realpc/)
bash pve-realpc-setup.sh --skip-download

# Skip APT pinning
bash pve-realpc-setup.sh --skip-pin

# Skip automatic kernel downgrade (install module into current kernel even if mismatched)
bash pve-realpc-setup.sh --skip-kernel-downgrade

# Enable Intel Ultra iGPU passthrough (downloads ROM, configures IOMMU + VFIO)
bash pve-realpc-setup.sh --igpu

# Show help
bash pve-realpc-setup.sh --help
```

### Automatic Kernel Downgrade

The patched `kvm.ko` module is built against a specific kernel version. If your running kernel doesn't match, Step 8 will automatically:

1. **Search APT** for the correct `proxmox-kernel-*` (PVE 9) or `pve-kernel-*` (PVE 8) package
2. **Install** the matching kernel package
3. **Pin it** as the default boot entry via GRUB and `/etc/default/pve-kernel`
4. **Install the patched `kvm.ko`** into the new kernel's module tree
5. **Prompt you to reboot** — after reboot, `uname -r` should match the module's target version

If the matching kernel is not available in your APT repositories, the script will print manual fix instructions and fall back to installing into the current kernel.

To skip this behavior and force installation into whatever kernel is currently running, use `--skip-kernel-downgrade`.

### What Gets Installed

| Component | Path | Description |
|---|---|---|
| Patched QEMU | `/usr/bin/qemu-system-x86_64` | ~29.7 MB (Strong build with PVE integration + sensor passthrough) |
| Patched OVMF | `/usr/share/pve-edk2-firmware/` | UEFI firmware with anti-detection |
| Patched ROM/BIOS | `/usr/share/kvm/` + `/usr/share/qemu/` | SeaBIOS, VGA, and EFI ROMs with VM strings removed (from Debian release) |
| Patched KVM module | `/lib/modules/$(uname -r)/kernel/arch/x86/kvm/kvm.ko` | Hides KVM signatures |
| ACPI tables | `/root/ssdt.aml`, `/root/ssdt-ec.aml`, `/root/hpet.aml`, `/root/ssdt-battery.aml` | Virtual hardware tables |
| iGPU ROM *(optional)* | `/usr/share/kvm/ultra-1-2-qemu10.rom` | Intel Ultra iGPU passthrough ROM (with `--igpu`) |
| Backups | `/root/pve-realpc/backup/` | Stock binaries + ROMs for rollback |
| APT pin | `/etc/apt/preferences.d/pve-realpc-hold` | Prevents overwrite on upgrade |

### Release Assets Downloaded

**PVE release** — tag [`v20260306-213905-pve9`](https://github.com/AICodo/pve-emu-realpc/releases/tag/v20260306-213905-pve9):

| File | Purpose |
|---|---|
| `pve-qemu-kvm_10.1.2-7_amd64.deb` | Base anti-detection QEMU |
| `pve-edk2-firmware-ovmf_4.2025.05-2_all.deb` | Base anti-detection OVMF |
| `pve-qemu-kvm_10.1.2-7_amd64_Strong_intel_amd.tgz` | Strong build (QEMU + OVMF + KVM modules) |
| `ssdt.aml` / `ssdt-ec.aml` / `ssdt-battery.aml` / `hpet.aml` | ACPI tables |
| `qemu-autoGenPatch.patch` | Full diff of all source modifications (reference only) |

**Debian release** — tag [`v20260307-191041-debian`](https://github.com/AICodo/pve-emu-realpc/releases/tag/v20260307-191041-debian) (patched ROM/BIOS files only):

| File | Purpose |
|---|---|
| `bios-256k.bin` / `bios.bin` / `bios-microvm.bin` | Patched SeaBIOS ROMs — `QEMU`/`Bochs`/`SeaBIOS` strings replaced |
| `efi-e1000.rom` / `efi-e1000e.rom` / `efi-virtio.rom` | Patched EFI network boot ROMs |
| `vgabios-qxl.bin` / `vgabios-stdvga.bin` | Patched VGA BIOS ROMs |
| `ssdt.aml` / `ssdt-ec.aml` / `ssdt-battery.aml` / `hpet.aml` | ACPI tables (identical to PVE release — used as fallback) |

> **Why two releases?** Both use the same `sedPatch` anti-detection source patches (~110 sed replacements). However, the PVE deb ships **stock unpatched ROM binaries** — the `sedPatch` modifies SeaBIOS source but Proxmox's build system doesn't recompile the prebuilt ROM blobs. The Debian release provides separately compiled ROMs with all VM-identifying strings scrubbed. The PVE QEMU binary is preferred (PVE integration + Strong sensor passthrough + larger patch set), so we take only the ROM files from the Debian release.

---

## Script 2 — VM Deployment

### `pve-realpc-deploy-vm.sh`

Creates a single Proxmox VM with every anti-detection measure pre-configured.

### Usage

```bash
# Interactive / all defaults (auto-detects VMID, ISO, CPU version)
# If multiple ISOs exist, shows an interactive picker with [SLIM]/[STOCK] tags
bash pve-realpc-deploy-vm.sh

# Custom VM
bash pve-realpc-deploy-vm.sh --vmid 200 --name win10-stealth --cores 8 --memory 16384

# Use a slim/debloated Windows ISO (auto-filtered by filename patterns)
bash pve-realpc-deploy-vm.sh --iso-type slim

# Use stock Windows ISO
bash pve-realpc-deploy-vm.sh --iso-type stock

# Explicit ISO filename
bash pve-realpc-deploy-vm.sh --iso tiny11_24H2.iso

# Laptop mode (virtual battery — useful for NVIDIA error 43 fix)
bash pve-realpc-deploy-vm.sh --type laptop --vga none

# Full 24-core CPU with explicit affinity pinning
bash pve-realpc-deploy-vm.sh --cores 24 --affinity 0-23

# Add TPM 2.0 (optional — upstream doesn't include it)
bash pve-realpc-deploy-vm.sh --tpm

# Show all options
bash pve-realpc-deploy-vm.sh --help
```

### All CLI Options

| Flag | Default | Description |
|---|---|---|
| `--vmid NUM` | next available | VM ID |
| `--name NAME` | `win10` | VM name |
| `--cores NUM` | `8` | CPU cores (goes directly to PVE `cores:`) |
| `--memory MB` | `16384` | RAM in MB (realistic: `4096`, `8192`, `16384`) |
| `--disk-size SIZE` | `256G` | System disk size |
| `--disk-storage NAME` | `local-lvm` | Storage pool for disks |
| `--iso-storage NAME` | `local` | Storage pool containing ISOs |
| `--iso FILENAME` | auto-detect | Explicit ISO filename |
| `--iso-type slim\|stock` | interactive | Auto-filter ISOs by type (see patterns below) |
| `--bridge NAME` | `vmbr0` | Network bridge |
| `--type desktop\|laptop` | `desktop` | Desktop = `ssdt.aml`; Laptop = `ssdt-battery.aml` |
| `--vga TYPE` | `std` | VGA: `std`, `none` (GPU passthrough), `virtio` |
| `--ostype TYPE` | `l26` | `l26` hides "win" from PCI config |
| `--tpm` | off | Add TPM 2.0 device (upstream doesn't include it) |
| `--affinity RANGE` | none | CPU pinning range (only set if explicitly passed) |
| `--board-mfg NAME` | `Maxsun` | Motherboard manufacturer |
| `--board-product NAME` | `MS-Terminator B760M` | Motherboard product name |
| `--disk-serial SERIAL` | random 20-char | Disk serial number |
| `--firewall 0\|1` | `1` | Enable PVE firewall |

### ISO Selection

When multiple ISOs exist in storage, the deploy script shows an interactive numbered picker with auto-detected tags:

| Tag | Detected Patterns |
| --- | --- |
| **[SLIM]** | `tiny11`, `tiny10`, `atlas`, `revi`, `ghost`, `spectre`, `slim`, `lite`, `compact`, `debloat`, `stripped`, `mini`, `micro`, `optimized`, `ntlite`, `msmg` |
| **[STOCK]** | `Win10`, `Win11`, `en-us_windows`, `en_windows`, `SW_DVD`, `MediaCreation` |

- **`--iso-type slim`** — shows only slim ISOs (auto-selects if there's exactly one)
- **`--iso-type stock`** — shows only stock ISOs (falls back to "not slim" if no stock pattern matches)
- **`--iso FILENAME`** — skips the picker entirely and uses the specified file
- **No flag** — shows all ISOs with tags and lets you choose

### What the VM Gets

The deploy script creates a VM matching the upstream AICodo/pve-emu-realpc recommended configuration:

- **OVMF + Q35** machine type with patched Strong OVMF firmware
- **EFI disk** without `pre-enrolled-keys` (patched OVMF sanitizes NVRAM variables internally)
- **SATA disk** with randomized serial (no VirtIO — VirtIO vendor IDs are a detection vector)
- **e1000 NIC** with Dell/Intel MAC prefix (`D8:FC:93`)
- **SMBIOS spoofing** — Types 0 (BIOS), 1 (System), 2 (Baseboard), 3 (Chassis), 4 (Processor), 8 (Ports), 9 (Slots), 17 (Memory)
- **ACPI tables** — fans, thermal zones, embedded controller, HPET
- **CPU flags** — `host,host-cache-info=on,hypervisor=off,vmware-cpuid-freq=false,enforce=false,host-phys-bits=true` (matches upstream exactly)
- **Balloon disabled** — balloon devices are a detection vector
- Optional: **TPM 2.0** (`--tpm`), **CPU affinity** (`--affinity`)

**What the patched QEMU 10 binary handles internally** (do NOT add these manually):
- KVM/hypervisor CPUID leaf hiding (`kvm=off` is handled inside the binary)
- TSC frequency pinning, `invtsc`, `tsc-deadline`, `tsc_adjust`
- System timers: HPET, PIT, RTC, ACPI PM timer obfuscation
- EFI NVRAM variable sanitization
- CPU power management passthrough
- CPU topology masking
- S3/S4 sleep state handling

---

## Post-Install Checklist (Inside the Guest)

After installing Windows in the VM:

1. **Do NOT install VirtIO/QEMU guest agent/tools** — they add detectable drivers and registry entries
2. **Do NOT enable Hyper-V** in Windows features
3. **Clean the registry** — run `qemu-cleanup.ps1` (see below) or manually remove leftover PCI vendor entries for `1af4` (Red Hat VirtIO), `1b36` (QEMU), `0627` (QEMU VGA)
4. **Do NOT install SPICE tools** or any VM-aware guest utilities
5. **For GPU passthrough** — recreate the VM with `--vga none` and add your PCI GPU device manually
6. **Use standard Windows drivers** — the e1000 NIC and SATA controller use native inbox drivers
7. **Spoof identifiers** — run `identifier-spoofer.ps1` to randomise machine GUID, MAC, hostname, install date, and more
8. **Spoof EDID** — if you have a GPU passthrough setup, run `edid-spoofer.ps1` to strip monitor serial numbers

---

## Windows Guest Tools

The `windows/` directory contains PowerShell scripts to run **inside the Windows guest** after the VM is deployed.  They eliminate residual VM fingerprints that survive even a patched QEMU/OVMF setup.

> **Attribution:** These guest-side cleanup scripts are based on the PowerShell tools from [Scrut1ny/AutoVirt](https://github.com/Scrut1ny/AutoVirt) (`resources/scripts/Windows/`). They have been rewritten with broader detection coverage, parameterisation, backup/restore support, and structured logging, but the original concept, registry target lists, and approach originated in AutoVirt.

### Quick Launch

Double-click **`run-tools.bat`** — it auto-elevates to Administrator, bypasses the PowerShell execution policy, and presents a menu:

```text
  [1]  QEMU Cleanup        - Remove VM registry & driver traces
  [2]  Identifier Spoofer  - Randomise machine IDs / MAC / hostname
  [3]  EDID Spoofer        - Strip monitor serial numbers
  [A]  Run ALL (1 → 2 → 3)
  [Q]  Quit
```

### 1. `qemu-cleanup.ps1` — Registry & Driver Artefact Removal

Removes QEMU, VirtIO, Red Hat, and Bochs traces from the Windows registry and DriverStore.

```powershell
# Default: uses PsExec64 (auto-downloaded) to run as SYSTEM
.\qemu-cleanup.ps1

# Run directly in current elevated session (no PsExec)
.\qemu-cleanup.ps1 -SkipPsExec

# Preview what would be deleted
.\qemu-cleanup.ps1 -WhatIf
```

| Feature | Detail |
|---|---|
| **Signature list** | `VEN_1AF4`, `DEV_1B36`, `VEN_1234`, `QEMU`, `BOCHS`, `VirtIO`, `VBOX`, and more |
| **Registry roots scanned** | `Enum`, `Services`, `Control\Class`, `Control\Video` |
| **SCSI wipe** | All sub-keys under `Enum\SCSI` removed |
| **DriverStore** | VirtIO/QEMU driver packages in `FileRepository` deleted |
| **Backup** | Each deleted key exported to `%TEMP%\qemu-cleanup-backup\` before removal |
| **WhatIf** | Dry-run mode — shows what would be deleted without touching anything |

### 2. `identifier-spoofer.ps1` — Machine Identity Randomiser

Randomises 8 categories of Windows identifiers commonly used for hardware fingerprinting.

```powershell
# Full spoof + automatic reboot
.\identifier-spoofer.ps1

# Custom computer name, skip reboot
.\identifier-spoofer.ps1 -ComputerName "DESKTOP-MYPC01" -NoReboot

# Custom MAC address
.\identifier-spoofer.ps1 -MacAddress "A4BB6D123456"
```

| # | Identifier | Registry / API |
|---|---|---|
| 1 | MachineGuid | `HKLM:\SOFTWARE\Microsoft\Cryptography` |
| 2 | InstallDate / InstallTime | `HKLM:\...\Windows NT\CurrentVersion` |
| 3 | Computer Name | `Rename-Computer` (NetBIOS + hostname) |
| 4 | MAC Address | `Set-NetAdapter` (first active adapter) |
| 5 | ProductId | `HKLM:\...\Windows NT\CurrentVersion` |
| 6 | HardwareGUID | `HKLM:\...\HardwareConfig` |
| 7 | SQM MachineId | `HKLM:\SOFTWARE\Microsoft\SQMClient` |
| 8 | Windows Update SusClientId | `HKLM:\...\WindowsUpdate` |

Original values are saved to `%TEMP%\identifier-spoofer-backup.json` before changes.

### 3. `edid-spoofer.ps1` — Monitor Serial Removal

Strips hardware serial numbers from the EDID data that anti-cheat reads via WMI, then writes a sanitised `EDID_OVERRIDE` to the registry.

```powershell
# Spoof all connected monitors + restart graphics driver
.\edid-spoofer.ps1

# Spoof without restarting the driver
.\edid-spoofer.ps1 -NoDriverRestart

# Revert to factory EDID
.\edid-spoofer.ps1 -Restore
```

| Feature | Detail |
|---|---|
| **Bytes zeroed** | EDID[12-15] (ID serial) + any 0xFF descriptor (alphanumeric serial) |
| **Checksum** | Base-block checksum (byte 127) automatically recomputed |
| **Extension blocks** | All CTA/DisplayID extension blocks preserved and forwarded |
| **Backup** | Original EDID saved as `.bin` to `%TEMP%\edid-spoofer-backup\` |
| **Restore** | `-Restore` flag removes all `EDID_OVERRIDE` keys and restarts the driver |

---

## Testing & Validation

Use these tools **inside the Windows guest** to verify anti-detection:

| Tool | Description |
|---|---|
| [pafish64.exe](https://github.com/a0rtega/pafish) | Comprehensive VM detection suite — checks CPUID, registry, timing, devices |
| [al-khaser](https://github.com/LordNoteworthy/al-khaser) | Advanced anti-analysis detection tool |
| [VMAware](https://github.com/kernelwernel/VMAware) | Cross-platform VM detection library |
| CPU-Z / HWiNFO / HWMonitor | Verify CPU sensor data appears (Strong build) |

A properly configured VM should pass all major checks in `pafish64` and `al-khaser`.

---

## Restoring Stock Packages

To undo all changes and restore the original Proxmox QEMU/OVMF:

```bash
# 1. Remove APT pin
rm /etc/apt/preferences.d/pve-realpc-hold
apt-mark unhold pve-qemu-kvm pve-edk2-firmware-ovmf

# 2. Reinstall stock packages
apt reinstall pve-qemu-kvm
apt reinstall pve-edk2-firmware-ovmf

# 3. Restore stock KVM module (if backed up)
cp /root/pve-realpc/backup/kvm.ko.stock /lib/modules/$(uname -r)/kernel/arch/x86/kvm/kvm.ko
depmod -a

# 4. Reboot
reboot
```

Backups of the original binaries are saved during setup in `/root/pve-realpc/backup/`.

---

## Upstream Sources & Credits

| Resource | Link |
|---|---|
| **Patched packages (PVE release)** | [AICodo/pve-emu-realpc — `v20260306-213905-pve9`](https://github.com/AICodo/pve-emu-realpc/releases/tag/v20260306-213905-pve9) |
| **Patched ROMs (Debian release)** | [AICodo/pve-emu-realpc — `v20260307-191041-debian`](https://github.com/AICodo/pve-emu-realpc/releases/tag/v20260307-191041-debian) |
| **Guest cleanup scripts (origin)** | [Scrut1ny/AutoVirt](https://github.com/Scrut1ny/AutoVirt) — `resources/scripts/Windows/` |
| **Anti-detection source code** | [lixiaoliu666/pve-anti-detection](https://github.com/lixiaoliu666/pve-anti-detection) |
| **Technical documentation** | [DeepWiki — pve-anti-detection](https://deepwiki.com/lixiaoliu666/pve-anti-detection) |
| **Original fork source** | [zhaodice/qemu-anti-detection](https://github.com/zhaodice/qemu-anti-detection) |
| **OVMF firmware source** | [lixiaoliu666/pve-anti-detection-edk2-firmware-ovmf](https://github.com/lixiaoliu666/pve-anti-detection-edk2-firmware-ovmf) |
| **Authors** | Li Xiaoliu (李晓流) & DadaShuai666 (大大帅666) |

The Strong build (sensor passthrough for CPU temperature/MHz/voltage/power) is an enhancement by [AICodo](https://github.com/AICodo) supporting both Intel and AMD CPUs on PVE 9.

---

## Related Repos & Resources

Nice-to-know projects in the VM anti-detection / virtualisation space:

| Repository | Description |
|---|---|
| [Scrut1ny/AutoVirt](https://github.com/Scrut1ny/AutoVirt) | Automated Linux virtualisation scripts covering QEMU, KVM, libvirt, VFIO GPU passthrough, EDK2/OVMF patching, and more. Shell-based with 590+ stars. Good reference for building anti-detection setups from source on Fedora/Debian. |
| [bryanem32/hyperv_vm_creator](https://github.com/bryanem32/hyperv_vm_creator) | PowerShell tool that automates Hyper-V VM creation on Windows 10/11 Pro with GPU Partitioning (GPU-P). Handles DISM image apply, Parsec, VB-Audio, virtual display driver, and GPU driver updates. Useful if you need a Windows-host alternative to QEMU/KVM. |
| [t4bby/smbios-patcher](https://github.com/t4bby/smbios-patcher) | CLI utility (C / Meson) for patching SMBIOS binary dumps. Lets you set BIOS vendor, system manufacturer, serial number, UUID, CPU info, baseboard, chassis, and memory device fields — then feed the patched binary back into QEMU. |
| [t4bby/smbios-parser](https://github.com/t4bby/smbios-parser) | Lightweight C99/C++98 library for parsing SMBIOS/DMI tables. Fork of brunexgeek/smbios-parser with added file-read support. Handy for inspecting what your guest actually exposes before and after patching. |
| [Ape-xCV/Nika-Read-Only](https://github.com/Ape-xCV/Nika-Read-Only) | In-depth QEMU/KVM anti-detection walkthrough for bare-metal Linux (Fedora/Debian + libvirt). Covers patched QEMU & OVMF builds, VFIO GPU passthrough, evdev input, SMBIOS spoofing, EDID spoofing, custom kernel builds, and network spoofing. |

---

## FAQ / Troubleshooting

**Q: The script says "REBOOT REQUIRED" after setup — is that normal?**
A: Yes. If your running kernel didn't match the patched KVM module, the script installed the correct kernel and pinned it as the boot default. Run `reboot`, then verify with `uname -r`. After reboot, proceed directly to VM deployment — no need to re-run the setup script.

**Q: Do I need to reboot after running the setup script?**
A: Only if the KVM module was already loaded (VMs were running). The script will warn you. Otherwise, no reboot is needed.

**Q: Will `apt upgrade` break the patched packages?**
A: No — the setup script pins `pve-qemu-kvm` and `pve-edk2-firmware-ovmf` at priority `-1` and marks them as held. You must explicitly unpin before upgrading these packages.

**Q: Which PVE version is supported?**
A: The current release (`v20260306-213905-pve9`) targets **PVE 9**. Older releases on the [AICodo releases page](https://github.com/AICodo/pve-emu-realpc/releases) support PVE 8.

**Q: Can I use this on bare Debian/Ubuntu (not Proxmox)?**
A: The AICodo releases page also provides standalone `qemu-system-x86_64` binaries for Debian 13 and Ubuntu 24.04. These scripts are Proxmox-specific, but the upstream binaries work on plain Linux.

**Q: The VM still gets detected — what should I check?**
1. Verify the Strong QEMU binary is installed: `ls -la /usr/bin/qemu-system-x86_64` (should be ~29.7 MB)
2. Verify the **Strong OVMF** is installed (not stock): `dpkg -l | grep pve-edk2-firmware`
3. Check ACPI tables exist: `ls /root/*.aml`
4. Ensure the `args:` line in `/etc/pve/qemu-server/<VMID>.conf` matches the upstream minimal format (see below)
5. **Remove any extra args**: `kvm=off`, `-smp`, `-rtc`, `-overcommit`, `-global`, `+invtsc`, `tsc-frequency=`, `affinity:` — the binary handles these internally
6. **Remove `pre-enrolled-keys=1`** from `efidisk0:` — stock OVMF templates contain detectable NVRAM variables
7. Check you did NOT install VirtIO drivers or QEMU guest agent inside Windows
8. Run `windows\run-tools.bat` to clean VM fingerprints from the guest registry
9. Verify the patched KVM module is loaded: `modinfo kvm | grep filename`

**Q: I'm failing timing anomalies, NVRAM, system timers, or thread count — what went wrong?**

The patched QEMU 10 binary handles **all** of these internally. If you're failing, it's almost certainly because extra args flags are **conflicting** with the binary's built-in handling. The upstream author explicitly states:

> *"In QEMU 10, all args parameters are now handled internally except for what's shown above (others are hidden/customized)."*

**Solution:** Strip your args to match upstream exactly:
```
args: -acpitable file=/root/ssdt.aml -acpitable file=/root/ssdt-ec.aml -acpitable file=/root/hpet.aml -cpu host,host-cache-info=on,hypervisor=off,vmware-cpuid-freq=false,enforce=false,host-phys-bits=true -smbios type=0,... -smbios type=1,... [etc.]
```
**Remove** these if present:
- `kvm=off` from CPU flags (binary hides KVM internally)
- `-smp ...` (let PVE handle topology via `cores:` and `sockets:`)
- `-overcommit cpu-pm=on` (binary handles CPU PM)
- `-rtc base=localtime,driftfix=slew` (binary handles RTC)
- `-global kvm-pit.lost_tick_policy=delay` (binary handles PIT)
- `-global ICH9-LPC.disable_s3=1` / `disable_s4=1` (binary handles S3/S4)
- `+invtsc`, `+tsc-deadline`, `+tsc_adjust`, `+rdpid`, `+xsaves`, `+pdpe1gb`, `+umip`, `+md-clear`, `+arch-capabilities` (binary handles CPUID)
- `tsc-frequency=...` (binary handles TSC)
- `affinity:` line (not needed)
- `pre-enrolled-keys=1` on `efidisk0:` (causes detectable NVRAM)

Also verify your `efidisk0:` does NOT have `pre-enrolled-keys=1` — the patched OVMF handles EFI variables internally.

**Q: How do I update when a new release comes out?**
A: Edit the `RELEASE_TAG` variable at the top of `pve-realpc-setup.sh` to the new tag, then re-run the script. It will download new assets and reinstall.

**Q: What about GPU passthrough?**
A: Deploy the VM with `--vga none`, then add your GPU as a PCI device via `qm set <VMID> --hostpci0 ...`. For NVIDIA cards that show error 43, use `--type laptop` to include `ssdt-battery.aml`.

---

## License

These deployment scripts are provided as-is. The upstream patched packages are built from the [pve-anti-detection](https://github.com/lixiaoliu666/pve-anti-detection) and [pve-emu-realpc](https://github.com/AICodo/pve-emu-realpc) repositories — refer to those projects for their respective licenses.
