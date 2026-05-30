<p align="center">
  <img src="https://img.shields.io/badge/QEMU-11.0.0-FF6600?style=for-the-badge&logo=qemu&logoColor=white">
  <img src="https://img.shields.io/badge/Proxmox-VE_9-E57000?style=for-the-badge&logo=proxmox&logoColor=white">
  <img src="https://img.shields.io/badge/license-MIT-green?style=for-the-badge">
  <img src="https://img.shields.io/badge/shell-|_powershell-blue?style=for-the-badge">
</p>

<h1 align="center">ProxMox RealPC DeployScripts</h1>

<p align="center">
  <i>Deployment automation and Windows guest hardening for the <a href="https://github.com/AICodo/pve-emu-realpc">pve-emu-realpc</a> anti‑detection stack.</i>
</p>

<p align="center">
  <sub>For security research, sandboxing, and malware analysis only. You are responsible for how you use this.</sub>
</p>

---

## Quick Start

SSH into your Proxmox host as root and paste:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Diobyte/ProxMox-RealPC-DeployScripts/main/pve-realpc-setup.sh)"
```

Then deploy a VM:

```bash
curl -fsSLO https://raw.githubusercontent.com/Diobyte/ProxMox-RealPC-DeployScripts/main/pve-realpc-deploy-vm.sh
chmod +x pve-realpc-deploy-vm.sh
./pve-realpc-deploy-vm.sh
qm start <VMID>
```

**Prefer git clone?**

```bash
git clone https://github.com/Diobyte/ProxMox-RealPC-DeployScripts.git
cd ProxMox-RealPC-DeployScripts
chmod +x pve-realpc-setup.sh pve-realpc-deploy-vm.sh
./pve-realpc-setup.sh
./pve-realpc-deploy-vm.sh
```

**Unattended / headless?**

```bash
chmod +x pve-realpc-setup.sh
./pve-realpc-setup.sh --non-interactive           # auto-pick latest + Strong
./pve-realpc-setup.sh --non-interactive --no-strong  # base only, no kernel pin
./pve-realpc-setup.sh --list-releases             # preview what's available
```

---

## What's Inside

| File | Purpose |
|---|---|
| `pve-realpc-setup.sh` | One-shot host preparation — downloads & installs patched QEMU, OVMF, KVM, ACPI tables, ROMs |
| `pve-realpc-deploy-vm.sh` | Per-VM cloaking — SMBIOS spoofing, ACPI injection, NVRAM hardening, timing fixes |
| `windows/run-tools.bat` | Guest cleanup launcher (auto-elevates to Administrator) |
| `windows/qemu-cleanup.ps1` | Registry & driver artefact removal — 30+ VM signature patterns, DriverStore, hidden PnP devices, event logs |
| `windows/identifier-spoofer.ps1` | Machine identity randomiser — 16 Windows identifiers (MachineGuid, MAC, hostname, network profiles, etc.) |
| `windows/edid-spoofer.ps1` | Monitor EDID serial spoofing with realistic non-zero serials + checksum correction |

The Windows tools are heavily rewritten from [Scrut1ny/AutoVirt](https://github.com/Scrut1ny/AutoVirt) — broader pattern coverage, safe SCSI filtering, realistic EDID serial generation, and the identifier spoofer is entirely new.

---

## GPU Passthrough

The display defaults to **`std`** for maximum stealth: the Debian release ships a scrubbed `vgabios-stdvga.bin` (no `QEMU`/`Bochs` option-ROM strings) and Windows shows a generic "Standard VGA" adapter. Both `std` and `vmware` have patched (non-`0x1234`/`0x15ad`) PCI-IDs, but the `vmware`/`virtio` option ROMs are **not** scrubbed upstream — so use `--vga vmware` only if you need its better 3D path (e.g. dGPU *mirror* mode), accepting the option-ROM string trade-off.

**Integrated GPU (Intel/AMD):**

```bash
./pve-realpc-setup.sh --igpu          # host: IOMMU + blacklist i915/amdgpu + VFIO + Intel ROM
./pve-realpc-deploy-vm.sh --igpu      # VM:   auto-detect iGPU, Intel IGD opregion/GMS
```

**Discrete NVIDIA / AMD GPU (full PCIe passthrough):**

```bash
./pve-realpc-setup.sh --nvidia        # host: IOMMU (GRUB + systemd-boot), blacklist
                                      #       nouveau/nvidia, bind the card's functions
                                      #       (GPU + HDMI audio) to vfio-pci by ID, then REBOOT
./pve-realpc-deploy-vm.sh --nvidia    # VM:   pass whole card via pcie=1; keeps the VMware
                                      #       display for console ("mirror"). --gpu-primary
                                      #       makes the dGPU the only display (x-vga=1).
```

NVIDIA **Code 43** is handled by `hypervisor=off` + the patched KVM (driver 465+ needs nothing more). For old Optimus/laptop drivers, add `--type laptop` (virtual battery). Pass an explicit card with `--gpu-pci 0000:01:00`, and a dumped vBIOS with `--gpu-rom card.rom` (placed in `/usr/share/kvm/`). `--igpu` and `--nvidia` are mutually exclusive (both use `hostpci0`).

---

## Source Repositories

### Primary upstream

| Repository | ★ | Role |
|---|---|---|
| [AICodo/pve-emu-realpc](https://github.com/AICodo/pve-emu-realpc) | 473 | Patched QEMU, OVMF, and KVM packages for PVE 9. Forked from zhaodice/qemu-anti-detection. Latest: v11.0.0-4. |
| [zhaodice/qemu-anti-detection](https://github.com/zhaodice/qemu-anti-detection) | 1.5k | Original anti-detection source. Patches for QEMU 6.2 through 10.2.2. |
| [Scrut1ny/AutoVirt](https://github.com/Scrut1ny/AutoVirt) | 684 | Origin of the Windows guest cleanup scripts. QEMU/KVM/libvirt automation, VFIO, OVMF patching. GPL-3.0. |
| [lixiaoliu666/pve-anti-detection](https://deepwiki.com/lixiaoliu666/pve-anti-detection) | — | Technical documentation on DeepWiki. Repo now redirects to AICodo/pve-emu-realpc. |

### Supplementary

| Repository | ★ | Contents |
|---|---|---|
| [AICodo/qemu-emu-realpc](https://github.com/AICodo/qemu-emu-realpc) | 3 | Standalone `.patch` files for QEMU 6.2–11.0.0 (non-PVE, libvirt-compatible). |
| [AICodo/pve-emu-realpc_edk2-firmware-ovmf](https://github.com/AICodo/pve-emu-realpc_edk2-firmware-ovmf) | — | Patched EDK2 / OVMF firmware packages. |
| [AICodo/intel-ultra-rom](https://github.com/AICodo/intel-ultra-rom) | — | Intel iGPU passthrough ROMs — desktop & notebook Core Ultra variants. |

### Detection validation tools

| Repository | ★ | Notes |
|---|---|---|
| [a0rtega/pafish](https://github.com/a0rtega/pafish) | 3.9k | Comprehensive VM detection suite. Archived Aug 2025. |
| [ayoubfaouzi/al-khaser](https://github.com/ayoubfaouzi/al-khaser) | 7k | Advanced anti-analysis detection (formerly LordNoteworthy/al-khaser). |
| [kernelwernel/VMAware](https://github.com/kernelwernel/VMAware) | 1.2k | Cross-platform VM detection library. Actively maintained. |

### Related projects

| Repository | ★ | Description |
|---|---|---|
| [Justsenger/ExHyperV](https://github.com/Justsenger/ExHyperV) | 4k+ | Hyper-V GPU-PV, CPU pinning, PCIe passthrough. Windows-on-Windows alternative. |
| [t4bby/smbios-patcher](https://github.com/t4bby/smbios-patcher) | — | CLI SMBIOS binary patcher (C / Meson). |
| [t4bby/smbios-parser](https://github.com/t4bby/smbios-parser) | — | C99 / C++98 SMBIOS / DMI table parser. |
| [Ape-xCV/Nika-Read-Only](https://github.com/Ape-xCV/Nika-Read-Only) | — | QEMU / KVM anti-detection walkthrough for Fedora/Debian + libvirt. |

---

## Credits

Anti‑detection by **Li Xiaoliu** (李晓流) & **DadaShuai666** (大大帅666). Strong build enhancements by [AICodo](https://github.com/AICodo). Windows guest tools derived from [Scrut1ny/AutoVirt](https://github.com/Scrut1ny/AutoVirt).

---

<p align="center">
  <sub>MIT © <a href="LICENSE">Diobyte</a> — applies to scripts & docs only. Downloaded QEMU/OVMF/KVM binaries are GPL-2.0.</sub>
</p>
