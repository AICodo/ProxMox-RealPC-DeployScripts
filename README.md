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
| `pve-realpc-setup.sh` | **One-time host preparation.** Downloads release assets from GitHub, backs up stock packages, installs patched QEMU + OVMF + KVM module, deploys ACPI tables, sets a realistic MAC prefix, and pins packages against `apt upgrade`. |
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
Applied by `pve-realpc-deploy-vm.sh`:
- `hypervisor=off` + `kvm=off` in CPU flags
- `e1000` NIC with physical vendor MAC OUI (`D8:FC:93`)
- SATA disk with randomized serial (no VirtIO)
- TSC frequency pinning + `invtsc`
- CPU power management passthrough (`-overcommit cpu-pm=on`)
- Balloon disabled, LSI SCSI controller

### Strong Build (Enhanced)
The **Strong** build (`_Strong.deb` packages + patched `kvm.ko`) adds CPU sensor passthrough — temperature, MHz, voltage, and power consumption are visible inside the Windows guest via CPU-Z, HWiNFO, HWMonitor. Supports both Intel and AMD CPUs.

---

## Requirements

- **Proxmox VE 8 or 9** (scripts target PVE 9 by default; PVE 8 releases also available upstream)
- **Root access** on the PVE host
- **Internet access** (to download release assets from GitHub)
- A **Windows ISO** uploaded to your PVE ISO storage (for VM deployment)
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

Automates all host-level preparation in 8 steps:

| Step | Action |
|---|---|
| 1 | Set MAC address prefix (`D8:FC:93` — Dell/Intel OUI) in `/etc/pve/datacenter.cfg` |
| 2 | Download all release assets from [AICodo/pve-emu-realpc releases](https://github.com/AICodo/pve-emu-realpc/releases) with SHA-256 verification |
| 3 | Back up stock QEMU binary, OVMF firmware, and KVM module to `/root/pve-realpc/backup/` |
| 4 | Install base anti-detection `.deb` packages (`pve-qemu-kvm`, `pve-edk2-firmware-ovmf`) |
| 5 | Extract and install **Strong** build packages (enhanced CPU sensor passthrough) |
| 6 | Install patched KVM kernel module (auto-detects Intel vs AMD); **auto-downgrades kernel** if version mismatches |
| 7 | Place ACPI table files (`ssdt.aml`, `ssdt-ec.aml`, `ssdt-battery.aml`, `hpet.aml`) into `/root/` |
| 8 | Pin packages via APT preferences + `dpkg hold` to prevent `apt upgrade` from overwriting |

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

# Show help
bash pve-realpc-setup.sh --help
```

### Automatic Kernel Downgrade

The patched `kvm.ko` module is built against a specific kernel version. If your running kernel doesn't match, Step 6 will automatically:

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
| Patched QEMU | `/usr/bin/qemu-system-x86_64` | ~29.7 MB (Strong build) |
| Patched OVMF | `/usr/share/pve-edk2-firmware/` | UEFI firmware with anti-detection |
| Patched KVM module | `/lib/modules/$(uname -r)/kernel/arch/x86/kvm/kvm.ko` | Hides KVM signatures |
| ACPI tables | `/root/ssdt.aml`, `/root/ssdt-ec.aml`, `/root/hpet.aml`, `/root/ssdt-battery.aml` | Virtual hardware tables |
| Backups | `/root/pve-realpc/backup/` | Stock binaries for rollback |
| APT pin | `/etc/apt/preferences.d/pve-realpc-hold` | Prevents overwrite on upgrade |

### Release Assets Downloaded

From tag `v20260306-213905-pve9`:

| File | Purpose |
|---|---|
| `pve-qemu-kvm_10.1.2-7_amd64.deb` | Base anti-detection QEMU |
| `pve-edk2-firmware-ovmf_4.2025.05-2_all.deb` | Base anti-detection OVMF |
| `pve-qemu-kvm_10.1.2-7_amd64_Strong_intel_amd.tgz` | Strong build (QEMU + OVMF + KVM modules) |
| `ssdt.aml` / `ssdt-ec.aml` / `ssdt-battery.aml` / `hpet.aml` | ACPI tables |
| `qemu-autoGenPatch.patch` | Full diff of all source modifications (reference) |

---

## Script 2 — VM Deployment

### `pve-realpc-deploy-vm.sh`

Creates a single Proxmox VM with every anti-detection measure pre-configured.

### Usage

```bash
# Interactive / all defaults (auto-detects VMID, ISO, TSC frequency, CPU affinity)
bash pve-realpc-deploy-vm.sh

# Custom VM
bash pve-realpc-deploy-vm.sh --vmid 200 --name win10-stealth --cores 8 --memory 16384

# Laptop mode (virtual battery — useful for NVIDIA error 43 fix)
bash pve-realpc-deploy-vm.sh --type laptop --vga none

# Best anti-timing-detection setup (host CPU isolation + explicit topology)
bash pve-realpc-deploy-vm.sh --cores 8 --threads 2 --isolate-cpus

# Force single-threaded on a host with SMT (if game expects no HyperThreading)
bash pve-realpc-deploy-vm.sh --no-smt

# Show all options
bash pve-realpc-deploy-vm.sh --help
```

### All CLI Options

| Flag | Default | Description |
|---|---|---|
| `--vmid NUM` | next available | VM ID |
| `--name NAME` | `win10` | VM name |
| `--cores NUM` | `8` | Total logical CPUs (auto-split into cores × threads) |
| `--memory MB` | `16384` | RAM in MB (realistic: `4096`, `8192`, `16384`) |
| `--disk-size SIZE` | `256G` | System disk size |
| `--disk-storage NAME` | `local-lvm` | Storage pool for disks |
| `--iso-storage NAME` | `local` | Storage pool containing ISOs |
| `--iso FILENAME` | auto-detect | ISO filename |
| `--bridge NAME` | `vmbr0` | Network bridge |
| `--type desktop\|laptop` | `desktop` | Desktop = `ssdt.aml`; Laptop = `ssdt-battery.aml` |
| `--vga TYPE` | `std` | VGA: `std`, `none` (GPU passthrough), `virtio` |
| `--ostype TYPE` | `l26` | `l26` hides "win" from PCI config |
| `--affinity RANGE` | auto (`0-N`) | CPU pinning range |
| `--tsc-freq HZ` | auto-detect | TSC frequency in Hz |
| `--board-mfg NAME` | `Maxsun` | Motherboard manufacturer |
| `--board-product NAME` | `MS-Terminator B760M` | Motherboard product name |
| `--disk-serial SERIAL` | random 20-char | Disk serial number |
| `--threads NUM` | auto-detect | Threads per core (`1` or `2`); auto-detected from host SMT |
| `--no-smt` | — | Force `threads=1` even if host CPU has SMT/HyperThreading |
| `--isolate-cpus` | — | Print host CPU isolation commands after deploy (timing fix) |
| `--firewall 0\|1` | `1` | Enable PVE firewall |

### What the VM Gets

The deploy script creates a VM with these anti-detection features:

- **OVMF + Q35** machine type with patched firmware
- **Secure Boot** (4M OVMF, pre-enrolled Microsoft keys)
- **TPM 2.0** emulation
- **SATA disk** with randomized serial (no VirtIO — VirtIO vendor IDs are a detection vector)
- **e1000 NIC** with Dell/Intel MAC prefix (`D8:FC:93`)
- **LSI SCSI controller** (not VirtIO-SCSI)
- **SMBIOS spoofing** — Types 0 (BIOS), 1 (System), 2 (Baseboard), 3 (Chassis), 4 (Processor), 8 (Ports), 9 (Slots), 17 (Memory)
- **ACPI tables** — fans, thermal zones, embedded controller, HPET
- **CPU topology** — auto-detects host SMT/HyperThreading; configures matching `cores × threads` so CPUID thread count matches reality
- **CPU flags** — `hypervisor=off`, `kvm=off`, `host-cache-info=on`, `+invtsc`, `+tsc-deadline`, `+tsc_adjust`, `+rdtscp`, TSC frequency pinning
- **Timing mitigations** — `hv-frequencies`, `hv-time`, `hv-reenlightenment`, `hv-vapic`, `hv-spinlocks`, PIT lost-tick delay, no-hpet, S3/S4 disabled
- **CPU power management** passthrough (`-overcommit cpu-pm=on`)
- **RTC drift fix** — `base=localtime,driftfix=slew`
- **Balloon disabled** — balloon devices are a detection vector
- **CPU affinity** — pins vCPUs to physical cores
- **Host CPU isolation** — optional `--isolate-cpus` prints `isolcpus`/`nohz_full`/`rcu_nocbs` kernel params + performance governor setup

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

### Quick Launch

Double-click **`run-tools.bat`** — it auto-elevates to Administrator, bypasses the PowerShell execution policy, and presents a menu:

```text
  [1]  QEMU Cleanup        - Remove VM registry & driver traces
  [2]  Identifier Spoofer  - Randomise machine IDs / MAC / hostname
  [3]  EDID Spoofer        - Strip monitor serial numbers
  [A]  Run ALL (1 → 2 → 3)
  [Q]  Quit
```

> **Origin:** based on the PS1 tools in [Scrut1ny/AutoVirt](https://github.com/Scrut1ny/AutoVirt/tree/main/resources/scripts/Windows), rewritten with broader coverage, parameterisation, backup/restore support, and structured logging.

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
| **Patched packages (releases)** | [AICodo/pve-emu-realpc](https://github.com/AICodo/pve-emu-realpc/releases) |
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
2. Check ACPI tables exist: `ls /root/*.aml`
3. Ensure the `args:` line is present in `/etc/pve/qemu-server/<VMID>.conf`
4. Check you did NOT install VirtIO drivers or QEMU guest agent inside Windows
5. Run `windows\run-tools.bat` to clean VM fingerprints from the guest registry
6. Verify the patched KVM module is loaded: `modinfo kvm | grep filename`

**Q: I am still failing timing anomalies or thread-count checks — what can I do?**
1. **Thread count**: If your host CPU has HyperThreading/SMT the script auto-detects it and sets `threads=2`. If detection doesnot match, force it: `--threads 2` (HT host) or `--no-smt` (disable). Check with `lscpu | grep 'Thread(s) per core'` on the host.
2. **CPU isolation**: Re-deploy with `--isolate-cpus`. The script will print `isolcpus`, `nohz_full`, `rcu_nocbs` kernel parameters and CPU governor setup. This prevents the host from scheduling on guest CPU cores, dramatically reducing RDTSC/CPUID timing jitter.
3. **TSC frequency**: Ensure `--tsc-freq` matches your CPU exactly. The script auto-detects via `journalctl`, but verify with `dmesg | grep -i tsc`.
4. **CPU governor**: Set all cores to `performance` mode: `cpufreq-set -g performance` or see the `--isolate-cpus` output.

**Q: How do I update when a new release comes out?**
A: Edit the `RELEASE_TAG` variable at the top of `pve-realpc-setup.sh` to the new tag, then re-run the script. It will download new assets and reinstall.

**Q: What about GPU passthrough?**
A: Deploy the VM with `--vga none`, then add your GPU as a PCI device via `qm set <VMID> --hostpci0 ...`. For NVIDIA cards that show error 43, use `--type laptop` to include `ssdt-battery.aml`.

---

## License

These deployment scripts are provided as-is. The upstream patched packages are built from the [pve-anti-detection](https://github.com/lixiaoliu666/pve-anti-detection) and [pve-emu-realpc](https://github.com/AICodo/pve-emu-realpc) repositories — refer to those projects for their respective licenses.
