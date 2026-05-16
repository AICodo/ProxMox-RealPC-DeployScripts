# ProxMox-RealPC-DeployScripts

Automated deployment scripts for installing [pve-emu-realpc](https://github.com/AICodo/pve-emu-realpc) anti-VM-detection packages on Proxmox VE and creating fully cloaked Windows VMs that pass common virtualization checks.

> ⚠️ **Read this before running anything.**
>
> - **Secure Boot must be DISABLED on the Proxmox host.** The patched `kvm.ko` shipped by upstream is an unsigned out-of-tree module; a Secure-Boot-enforcing kernel will refuse to load it.
> - **The host kernel may be pinned.** With Strong enabled (default), the script will install + pin kernel `6.17.13-2` so the patched `kvm.ko` loads. Skip with `--no-strong` if you don't want this.
> - **A spoofed MAC OUI is configured at the datacenter level** (`D8:FC:93`, Dell/Intel range). Don't use on a network that enforces MAC OUI ACLs without first changing `MAC_PREFIX` in `pve-realpc-setup.sh`.
> - **Intended use is security research, sandboxing, malware analysis, and legitimate cloaking against fingerprinting telemetry.** Using these scripts to evade anti-cheat in online games is almost certainly a violation of the game's Terms of Service and may be illegal in some jurisdictions. The patched binaries also do *not* hide the VM from modern kernel-mode anti-cheats — see the FAQ entry on VMAware v2.7+ for the actual detection coverage.
> - **Windows guest tools rewrite registry identifiers and download Sysinternals PsExec64.** Windows Defender and most EDRs will flag these operations. Snapshot the VM first; add `windows\` to AV exclusions; do not run these on a machine where you actually want anti-cheat to work.
> - **No warranty.** See [LICENSE](LICENSE). Run these on hardware you own.

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

These scripts target **QEMU 11** on PVE 9 using upstream's split-release model: base files come from the latest tag ([`v20260516-211490-pve9`](https://github.com/AICodo/pve-emu-realpc/releases/tag/v20260516-211490-pve9), v11.0.0-2) and the Strong `.tgz` (CPU sensor passthrough + matching `kvm.ko` for kernel 6.17.13-2) is overlaid from the previous enhanced tag ([`v20260506-222829-pve9`](https://github.com/AICodo/pve-emu-realpc/releases/tag/v20260506-222829-pve9), v11.0.0-1). The `qemu-autoGenPatch.patch` is byte-identical between the two, so the anti-detection footprint is the same either way — only Strong availability differs. v11 adds a rewritten `fw_cfg` DMA signature (`"QEMU CFG"` / `0x51454d5520434647` → `"AUSU CFG"` / `0x4155535520434647`), bumps the FADT revision from 3 → 4, the DSDT revision from 1 → 3 (HPET/SRAT/DMAR/IVRS also rev 3), renames the WAET ACPI signature to `"WWWT"`, and auto-generates additional SMBIOS types 7 (Cache), 20 (Memory Device Mapped Address), 26 (Voltage Probe), and 27 (Cooling Device) internally. Pass `--no-strong` to install only the base release if you don't want the kernel pin to 6.17.13-2.

**These scripts** automate the entire setup so you don't have to manually download packages, run `dpkg`, copy files, or hand-craft VM config arguments.

---

## What These Scripts Do

| Script | Purpose |
|---|---|
| `pve-realpc-setup.sh` | **One-time host preparation.** Downloads release assets from both PVE and Debian GitHub releases, backs up stock packages, installs patched QEMU + OVMF + KVM module, overlays patched ROM/BIOS files (removes VM strings from SeaBIOS/VGA/EFI), deploys ACPI tables, optionally configures iGPU passthrough (Intel or AMD), sets a realistic MAC prefix, and pins packages against `apt upgrade`. |
| `pve-realpc-deploy-vm.sh` | **Per-VM creation.** Creates a fully configured Proxmox VM with OVMF/Q35, SATA disk, e1000 NIC, full SMBIOS spoofing (8 types), custom ACPI tables, hidden hypervisor, host EFI variable injection, S3/S4 sleep states, PIT SSDT, and more — all via a single command. |

---

## Anti-Detection Layers

The patched packages implement five layers of anti-detection, as described in the [upstream documentation](https://deepwiki.com/lixiaoliu666/pve-anti-detection):

### Layer 1 — String Obfuscation (sedPatch)
110+ `sed` replacements across 80+ QEMU source files:
- `QEMU` → `DELL`, `BOCHS` → `INTEL`, `RHT` → `DEL`
- `KVMKVMKVM` → null bytes (hides KVM CPUID signature)
- `VMware` → `GenuineIntel`

### Layer 2 — SMBIOS Hardware Spoofing
Custom `smbios.c` generates realistic hardware identity tables (updated for QEMU 10.2.1 with new `vm` field support in `smbios_type0_t` for UEFI/VM awareness; QEMU 11 additionally generates types 7/20/26/27 internally):
- **Type 0** — BIOS: American Megatrends International LLC. (v10.2.1+: internal `vm` field controls UEFI vs legacy behavior)
- **Type 1** — System: Maxsun MS-Terminator B760M (Intel) / MSI MAG B650 TOMAHAWK (AMD)
- **Type 2** — Baseboard: vendor-matched to CPU (auto-detected by deploy script)
- **Type 3** — Chassis: realistic enclosure information
- **Type 4** — Processor: auto-detected from host CPU (model obfuscated to "0000")
- **Type 7** — Cache Information: *(QEMU 11 only)* auto-generated by patched binary; L1/L2/L3 cache topology with realistic socket designation, error correction, and associativity
- **Type 8** — Port Connectors: two empty entries emitted by the deploy script's args line (`-smbios type=8 -smbios type=8`); the patched binary populates the fan/peripheral port descriptors internally from those triggers
- **Type 9** — System Slots: PCI slot info (Strong build generates realistic data)
- **Type 17** — Memory: QEMU 10+/11 simplified format (serial+asset; binary handles manufacturer/speed/part internally)
- **Type 20** — Memory Device Mapped Address: *(QEMU 11 only)* auto-generated; ties type 17 entries to physical address ranges in KB
- **Type 26** — Voltage Probe: *(QEMU 11 only)* auto-generated; location, max/min, resolution, tolerance — real PCs always expose these on motherboards
- **Type 27** — Cooling Device: *(QEMU 11 only)* auto-generated; temperature probe handle and device status

### Layer 3 — Firmware Customization
- Custom boot splash image (`bootsplash.jpg`) replaces QEMU default
- Patched OVMF (UEFI) firmware package (`pve-edk2-firmware-ovmf`)
- *(QEMU 11 only)* `fw_cfg` DMA interface signature rewritten from `"QEMU CFG"` (`0x51454d5520434647`) to `"AUSU CFG"` (`0x4155535520434647`) — defeats `VM::FIRMWARE` scans for the QEMU fw_cfg device signature. (Yes — `AUSU`, not `ASUS`. Those are the literal four bytes emitted by the upstream patched binary; appears to be a typo in the upstream patch but defeating the signature is the whole point, so don't "correct" it.)
- *(QEMU 11 only)* WAET ACPI table signature renamed to `"WWWT"` — defeats firmware scans that look for the literal `"WAET"` table identifier

### Layer 4 — ACPI Table Virtualization
Injected `.aml` tables add hardware that real PCs have but VMs normally lack:

| File | Provides |
|---|---|
| `ssdt.aml` | 6 fan devices + 8 thermal zones |
| `ssdt-ec.aml` | Embedded Controller (`EC__`) device |
| `hpet.aml` | High Precision Event Timer device |
| `ssdt-battery.aml` | Virtual battery (laptop mode / NVIDIA error 43 fix) |
| `pit.aml` | Programmable Interval Timer (`PNP0100`) — generated by setup script via `iasl` |

*(QEMU 11 only)* The patched binary additionally bumps the FADT revision from 3 → 4 (and forces PIIX FADT rev 1 → 4), bumps the DSDT/HPET/SRAT/DMAR/IVRS revisions to 3, renames the WAET ACPI table signature to `"WWWT"`, and adds `_OSI` declarations for Windows 2012/2013 compatibility. C2/C3 latency values (`plvl2_lat`/`plvl3_lat`) are widened from `0xfff` to `0x1fff`. These changes are emitted automatically by the patched binary — no args changes required.

### Layer 5 — Runtime VM Configuration
Applied by `pve-realpc-deploy-vm.sh` (matches upstream recommended args exactly):
- `-cpu host` with `hypervisor=off` (NO `kvm=off` — the patched binary hides KVM internally)
- `e1000` NIC with physical vendor MAC OUI (`D8:FC:93`) — Intel 82540EM, matches upstream for compatibility
- SATA disk with randomized serial (no VirtIO)
- Custom ACPI tables (`ssdt.aml`, `ssdt-ec.aml`, `hpet.aml`, `pit.aml`)
- Full SMBIOS spoofing (types 0,1,2,3,4,8,9,17 — type 17 uses upstream QEMU 10+/11 simplified format by default: serial + asset only, patched binary handles manufacturer/speed/part/bank internally; pass `--mem-*` flags for full override). QEMU 11 additionally auto-generates types 7 (Cache), 20 (Memory Mapped), 26 (Voltage Probe), and 27 (Cooling Device).
- Host EFI variable injection into VM NVRAM (replaces Red Hat certs with real Secure Boot keys)
- S3/S4 sleep states enabled via ICH9-LPC globals (defeats POWER_CAPABILITIES detection)
- PIT SSDT (PNP0100 device at I/O 0x40–0x43) defeats SYSTEM_TIMERS / CLOCK detection
- Auto-detected `cores:` / `sockets:` matching host CPUID (PVE generates `-smp` from those values — no override in args; prevents THREAD_MISMATCH detection)
- Balloon disabled
- **NO** timing args (patched binary handles TSC/HPET/PIT/RTC internally)
- **NO** extra CPU feature flags (patched binary handles CPUID hiding internally)
- **NO** `pre-enrolled-keys` (host EFI variables injected instead)

> **v10.2.1+ / v11 Display Changes:** The Strong build supports **VMware-compatible display** (`--vga vmware`), which is **recommended by upstream** for best 3D acceleration with iGPU/dGPU mirror setups. VirtIO-GPU is also supported (OVMF only). The PCI-IDs for Standard VGA, VMware, and VirtIO-GPU have all been changed from their stock QEMU values (no longer 0x1234, 0x15ad, or 0x1af4). Spice display still uses PCI-ID 0x1b36 and is not recommended.
>
> **VMware VGA ROM limitation:** The Debian release only provides patched `vgabios-stdvga.bin` and `vgabios-qxl.bin` ROMs (with VM strings removed). The `vgabios-vmware.bin` and `vgabios-virtio.bin` ROMs are **not** included in the Debian build output. These ROMs come from the PVE deb (pre-built blobs that bypass the sedPatch process) and may still contain `"QEMU"`/`"SeaBIOS"` strings. The setup script's verification step warns if this is detected. For maximum stealth, use `--vga std` (fully overlaid ROM) or GPU passthrough (`--vga none`).

> **v10.2.1 SMBIOS Changes:** The upstream `smbios.c` was updated (commit 9859f1f) to add a `vm` field to `smbios_type0_t` for UEFI/VM awareness support. This is handled entirely by the patched binary — no changes needed in args. The binary now generates more realistic SMBIOS type 0 (BIOS) entries with proper UEFI characteristic bits and firmware revision handling.
>
> **v11.0.0 SMBIOS Changes:** v11 extends `smbios.c` with `smbios_build_type_7_table()` (Cache Information), `smbios_build_type_20_table()` (Memory Device Mapped Address), `smbios_build_type_26_table()` (Voltage Probe), and `smbios_build_type_27_table()` (Cooling Device). Base addresses for types 28, 29, 37, and 39 are also reserved. All of these are auto-generated by the patched binary; no args changes are required to take advantage of them. The combination defeats VMAware's `VM::FIRMWARE` check (100% certainty) more thoroughly because real motherboards always expose these structures.

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
- **Secure Boot DISABLED** in host BIOS/UEFI — the patched `kvm.ko` module is unsigned and will be rejected by the kernel if Secure Boot is active. Proxmox itself does not require Secure Boot; only the guest VM benefits from Secure Boot (handled by OVMF).
- **Strong build note:** The Strong overlay (sourced from `STRONG_TAG` = [`v20260506-222829-pve9`](https://github.com/AICodo/pve-emu-realpc/releases/tag/v20260506-222829-pve9) — v11.0.0-1 enhanced) includes a patched `kvm.ko` compiled against **kernel 6.17.13-2**. If your PVE host runs a different kernel, the setup script will automatically install and pin the matching kernel. See [Automatic Kernel Downgrade](#automatic-kernel-downgrade). Pass `--no-strong` to skip the overlay (and the kernel pin) entirely.

---

## Quick Start

**One-liner install (recommended).** SSH into the Proxmox host as root and paste:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Diobyte/ProxMox-RealPC-DeployScripts/main/pve-realpc-setup.sh)"
```

That's it. The script:

1. Queries the GitHub API for every `AICodo/pve-emu-realpc` release
2. Classifies each release (base / Strong-shipping / debian-ROMs / other) by tag suffix and asset filename patterns
3. Auto-picks the newest base release + last Strong-shipping release + newest Debian ROM release as defaults
4. Launches a `whiptail` menu — confirm Default or pick Advanced for per-tag selection
5. Prompts for the two host-affecting choices (iGPU passthrough? kernel pin?)
6. Downloads ~100 MB, installs the patched packages, configures the host, ~2 min

**No flags. No version numbers to hard-code. No filenames to update when upstream ships a new release.**

Then create a VM:

```bash
cd /root/pve-realpc 2>/dev/null || cd ~
curl -fsSLO https://raw.githubusercontent.com/Diobyte/ProxMox-RealPC-DeployScripts/main/pve-realpc-deploy-vm.sh
bash pve-realpc-deploy-vm.sh
qm start <VMID>      # the deploy script prints the chosen VMID on its last line
```

**Prefer git clone?**

```bash
git clone https://github.com/Diobyte/ProxMox-RealPC-DeployScripts.git
cd ProxMox-RealPC-DeployScripts
bash pve-realpc-setup.sh
bash pve-realpc-deploy-vm.sh
```

**Unattended / CI?** Skip the menus:

```bash
bash pve-realpc-setup.sh --list-releases       # see what upstream ships, exit
bash pve-realpc-setup.sh --non-interactive     # auto-pick latest + Strong, no prompts
bash pve-realpc-setup.sh --non-interactive --no-strong          # base only, no kernel pin
bash pve-realpc-setup.sh --release-tag v20260516-211490-pve9 --strong-tag none
```

---

## Selectable Options Inventory

Everything the setup script lets you control is here. **The default path is: run it, answer two whiptail prompts, done.** Nothing in this table requires a flag for the common case.

| Option | Auto-detected | Whiptail prompt | CLI flag | Notes |
|---|:-:|:-:|:-:|---|
| Base release tag | ✅ from GitHub API (newest `-pve9`) | ✅ Advanced mode | `--release-tag TAG` | Provides QEMU + OVMF .deb + ACPI + patch |
| Strong overlay tag | ✅ from GitHub API (newest `-pve9` w/ Strong .tgz) | ✅ Advanced mode | `--strong-tag TAG\|none` | Sensor passthrough + kernel-matched `kvm.ko` |
| Debian ROM tag | ✅ from GitHub API (newest `-debian`) | ✅ Advanced mode | `--debian-tag TAG` | Patched BIOS/EFI/VGA ROMs |
| Enable Strong build | ✅ (yes by default) | ✅ Advanced mode | `--no-strong` | Off → no sensor passthrough, no kernel pin |
| iGPU passthrough | ✅ (off by default) | ✅ **Both Default & Advanced modes** | `--igpu` | Intel+AMD aware; downloads ROM, enables IOMMU, blacklists drivers |
| Kernel auto-pin to 6.17.13-2 | ✅ (on by default if Strong) | ✅ **Both modes** | `--skip-kernel-downgrade` | Required for Strong `kvm.ko` to load |
| APT package pinning | ✅ (on by default) | ✅ Advanced mode | `--skip-pin` | Prevents `apt upgrade` overwriting patched packages |
| CPU vendor (Intel/AMD) | ✅ from `/proc/cpuinfo` | — | — | Auto-selects matching `kvm.ko` and IOMMU param |
| MAC OUI prefix | static `D8:FC:93` (Dell/Intel) | — | edit `MAC_PREFIX` in script | Set at PVE datacenter level |
| Skip GitHub API | — | — | `--skip-resolve` | Use static fallback tags (offline / rate-limited) |
| Skip downloads | — | — | `--skip-download` | Reuse pre-staged files in `/root/pve-realpc/` |
| Inspect available releases | — | — | `--list-releases` | Dumps resolved roster, exits (no root required) |
| Force / disable menus | — | — | `--interactive` / `--non-interactive` | Override TTY detection |

The deploy script (`pve-realpc-deploy-vm.sh`) adds another ~25 knobs (VMID, CPU cores, memory, disk size, SMBIOS strings, etc.) — all flag-driven there because the deploy is typically scripted per-VM. Run `bash pve-realpc-deploy-vm.sh --help` for the full reference.

---

## Architecture

### Design patterns adopted from `community-scripts/ProxmoxVE`

| Pattern | Source | Where in our code |
|---|---|---|
| Curl-pipe install (`bash -c "$(curl -fsSL ...)"`) | community-scripts container/VM installers | README Quick Start |
| Default vs Advanced bifurcation (one yes/no, then branch) | their `vm/debian-vm.sh:462` "Use Default Settings?" pattern | `run_interactive_config()` in `pve-realpc-setup.sh` |
| `header_info` ASCII banner | their `vm/debian-vm.sh:9` | `header_info()` in setup.sh |
| Progressive status helpers (`msg_info` / `msg_ok` / `msg_err` with CR overwrites) | their `misc/build.func` | UI helpers section in setup.sh |
| Colour palette + emoji status markers | their `vm/debian-vm.sh:29-61` | `YW`/`BL`/`CM`/`XX` defs in setup.sh |
| whiptail `--backtitle` consistency | their `misc/build.func` | `WT_BACK` constant + `wt_*` wrappers in setup.sh |
| `--cancel-button Exit-Script` UX for menus | their menu helpers | `wt_menu()` with exit-2 vs exit-1 distinction |

### Design patterns deliberately NOT adopted

| Their pattern | Why we skipped it |
|---|---|
| Telemetry POST to `api.community-scripts.org` | We don't want to phone home; users can audit the script line-by-line and run offline |
| Auto-update mechanism that overwrites the script in place | We pin via git / curl; users control their own update cadence |
| Container-targeted features (LXC config, ostype matrices) | We're VM-only by design (KVM passthrough needs full virt) |
| `applications.json` registry | Single product, no registry needed |

### Our additions on top

- **Dynamic GitHub release resolver** with regex-based asset filename derivation. Future upstream releases work without script edits as long as the `pve-qemu-kvm_<VER>_amd64.deb` / `*_Strong_intel_amd[_<KERNEL>].tgz` convention holds. Verified live against all 20 current upstream releases.
- **Split-release model awareness** — the resolver distinguishes pve9-base, pve9-strong, debian, ubuntu, and pve-other kinds so we can pull base + Strong from different tags (upstream's intentional pattern since v11.0.0-2).
- **Trap-based VM-creation rollback** in the deploy script — half-built VMs auto-destroy on Ctrl-C / error.
- **NVRAM round-trip validation** before writing host EFI variables back to the VM's `efidisk0` — corrupt writes are rolled back from the pristine backup.

---

## Script 1 — Host Setup

### `pve-realpc-setup.sh`

**Dynamic release resolver:** before step 1 runs, the script hits `https://api.github.com/repos/AICodo/pve-emu-realpc/releases` and classifies every release by the assets it ships — `pve9-base` / `pve9-strong` / `debian` / `ubuntu` / `pve-other`. Asset filenames are derived from regex pattern matches against the convention upstream has used across 20+ releases (`pve-qemu-kvm_<VER>_amd64.deb`, `pve-qemu-kvm_<VER>_amd64_Strong_intel_amd[_<KERNEL>].tgz`, etc.) so **new upstream releases work automatically without script edits**. If GitHub is unreachable or python3 is missing, the script falls back to the static tag constants at the top of the file.

Automates all host-level preparation in 12 steps:

| Step | Action |
|---|---|
| 1 | Set MAC address prefix (`D8:FC:93` — Dell/Intel OUI) in `/etc/pve/datacenter.cfg` |
| 2 | Download base PVE release assets from `RELEASE_TAG` (auto-resolved to the newest `-pve9` tag — currently [`v20260516-211490-pve9`](https://github.com/AICodo/pve-emu-realpc/releases/tag/v20260516-211490-pve9), v11.0.0-2); then download the Strong `.tgz` from `STRONG_TAG` (auto-resolved to the newest Strong-shipping tag — currently [`v20260506-222829-pve9`](https://github.com/AICodo/pve-emu-realpc/releases/tag/v20260506-222829-pve9), v11.0.0-1) unless `--no-strong` is passed |
| 3 | Download Debian release assets (patched ROM/BIOS files only) from `DEBIAN_TAG` (auto-resolved to the newest `-debian` tag — currently [`v20260507-200382-debian`](https://github.com/AICodo/pve-emu-realpc/releases/tag/v20260507-200382-debian), v11.0.0 for debian13) |
| 4 | Back up stock QEMU binary, OVMF firmware, and KVM module to `/root/pve-realpc/backup/` |
| 5 | Install base anti-detection `.deb` packages (`pve-qemu-kvm`, `pve-edk2-firmware-ovmf`) |
| 6 | Extract and install **Strong** build packages (enhanced CPU sensor passthrough) |
| 7 | Overlay patched Debian ROM/BIOS/VGA files — replaces stock SeaBIOS/EFI/VGA ROMs that still contain `QEMU`/`Bochs`/`SeaBIOS` strings (PVE binary is preserved); installs custom boot splash (`bootsplash.jpg`) to defeat VMAware BOOT_LOGO CRC32 check |
| 8 | Install patched KVM kernel module (auto-detects Intel vs AMD); **auto-downgrades kernel** if version mismatches |
| 9 | Place ACPI table files (`ssdt.aml`, `ssdt-ec.aml`, `ssdt-battery.aml`, `hpet.aml`) into `/root/` + compile `pit.aml` via `iasl` |
| 10 | *(Optional)* iGPU passthrough setup — Intel: downloads ROM + enables IOMMU + blacklists `i915`/`snd_hda_intel`; AMD: enables IOMMU + blacklists `amdgpu`/`radeon`/`snd_hda_amd` (requires `--igpu`) |
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

# Enable iGPU passthrough (Intel: downloads ROM + IOMMU + VFIO; AMD: IOMMU + VFIO)
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
| Patched QEMU | `/usr/bin/qemu-system-x86_64` | ~30.2 MB (v11.0.0-1 Strong build with PVE integration + sensor passthrough; v10.2.1 was ~29.7 MB) |
| Patched OVMF | `/usr/share/pve-edk2-firmware/` | UEFI firmware with anti-detection |
| Patched ROM/BIOS | `/usr/share/kvm/` + `/usr/share/qemu/` | SeaBIOS, VGA, and EFI ROMs with VM strings removed (from Debian release) |
| Boot splash | `/usr/share/kvm/bootsplash.jpg` | Custom boot logo replacing default EDK2/TianoCore splash (defeats VMAware BOOT_LOGO CRC32 check) |
| Patched KVM module | `/lib/modules/$(uname -r)/kernel/arch/x86/kvm/kvm.ko` | Hides KVM signatures |
| ACPI tables | `/root/ssdt.aml`, `/root/ssdt-ec.aml`, `/root/hpet.aml`, `/root/pit.aml`, `/root/ssdt-battery.aml` | Virtual hardware tables (pit.aml compiled locally by `iasl`) |
| iGPU ROM *(Intel only)* | `/usr/share/kvm/ultra-1-2-qemu10.rom` | Intel Ultra iGPU passthrough ROM (with `--igpu` on Intel hosts) |
| Backups | `/root/pve-realpc/backup/` | Stock binaries + ROMs for rollback |
| APT pin | `/etc/apt/preferences.d/pve-realpc-hold` | Prevents overwrite on upgrade |

### Release Assets Downloaded

**Base PVE release** — `RELEASE_TAG` = [`v20260516-211490-pve9`](https://github.com/AICodo/pve-emu-realpc/releases/tag/v20260516-211490-pve9) (v11.0.0-2 — latest):

| File | Purpose |
|---|---|
| `pve-qemu-kvm_11.0.0-2_amd64.deb` | Base anti-detection QEMU 11 |
| `pve-edk2-firmware-ovmf_4.2025.05-2_all.deb` | Base anti-detection OVMF |
| `ssdt.aml` / `ssdt-ec.aml` / `ssdt-battery.aml` / `hpet.aml` | ACPI tables |
| `qemu-autoGenPatch.patch` | Full diff of all source modifications (reference only) |

**Strong overlay** — `STRONG_TAG` = [`v20260506-222829-pve9`](https://github.com/AICodo/pve-emu-realpc/releases/tag/v20260506-222829-pve9) (v11.0.0-1 enhanced — last release shipping Strong), downloaded only when Strong is enabled (default):

| File | Purpose |
|---|---|
| `pve-qemu-kvm_11.0.0-1_amd64_Strong_intel_amd_6.17.13-2.tgz` | Strong overlay (QEMU + OVMF + `kvm.ko` for kernel 6.17.13-2) |

> **Split-release model (upstream's intentional pattern):** the latest PVE9 tag often ships base assets only, and the Strong `.tgz` lives on the prior "enhanced" tag. The `qemu-autoGenPatch.patch` is byte-identical between v11.0.0-1 and v11.0.0-2 (verified via `diff -q`; 92,289 bytes / 2,169 lines on both), so v11.0.0-2 introduces **zero new anti-detection content** — it only differs by omitting Strong. The setup script accordingly pulls base files from `RELEASE_TAG` (= [`v20260516-211490-pve9`](https://github.com/AICodo/pve-emu-realpc/releases/tag/v20260516-211490-pve9), v11.0.0-2 — latest) and overlays the Strong `.tgz` from `STRONG_TAG` (= [`v20260506-222829-pve9`](https://github.com/AICodo/pve-emu-realpc/releases/tag/v20260506-222829-pve9), v11.0.0-1 — last with Strong). When a future release re-ships Strong, point both tags at it.

### Strong opt-out

Pass `--no-strong` to `pve-realpc-setup.sh` to install only the base build:

| Behaviour | default (Strong on) | `--no-strong` |
|---|---|---|
| Base QEMU + OVMF | ✅ from `RELEASE_TAG` | ✅ from `RELEASE_TAG` |
| Anti-detection patches (fw_cfg / FADT / DSDT / SMBIOS 7-20-26-27 / WAET) | ✅ | ✅ (identical patch) |
| Strong `.tgz` overlay (Strong QEMU + Strong OVMF) | ✅ from `STRONG_TAG` | ❌ skipped |
| CPU sensor passthrough (CPU-Z / HWiNFO / HWMonitor temp/MHz/voltage) | ✅ | ❌ |
| Patched `kvm.ko` install | ✅ for kernel 6.17.13-2 | ❌ host stock module kept |
| Auto kernel pin to 6.17.13-2 | ✅ when mismatched | ❌ no kernel change |

Use `--no-strong` if you don't want sensor passthrough and would rather not pin to kernel 6.17.13-2 (for example, you're on a newer kernel and don't want to downgrade).

**Debian release** — tag [`v20260507-200382-debian`](https://github.com/AICodo/pve-emu-realpc/releases/tag/v20260507-200382-debian) (v11.0.0 for debian13, patched ROM/BIOS files only):

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
| `--cores NUM` | auto-detect | CPU cores (auto-detected from host CPUID topology) |
| `--memory MB` | `16384` | RAM in MB (realistic: `4096`, `8192`, `16384`) |
| `--disk-size SIZE` | `256G` | System disk size |
| `--disk-storage NAME` | `local-lvm` (auto-falls back) | Storage pool for disks; if missing/inactive, picks the first active pool with `images` content (e.g. ZFS/Ceph hosts) |
| `--iso-storage NAME` | `local` (auto-falls back) | Storage pool containing ISOs; if missing/inactive, picks the first active pool with `iso` content |
| `--iso FILENAME` | auto-detect | Explicit ISO filename |
| `--iso-type slim\|stock` | interactive | Auto-filter ISOs by type (see patterns below) |
| `--bridge NAME` | `vmbr0` | Network bridge |
| `--type desktop\|laptop` | `desktop` | Desktop = `ssdt.aml`; Laptop = `ssdt-battery.aml` |
| `--vga TYPE` | `vmware` | VGA: `std`, `vmware` (recommended by upstream v10.2.1+/v11), `none` (GPU passthrough), `virtio` |
| `--ostype TYPE` | `other` | `other` prevents PVE from injecting S3/S4-disable globals |
| `--tpm` | off | Add TPM 2.0 device (upstream doesn't include it) |
| `--affinity RANGE` | none | CPU pinning range (only set if explicitly passed) |
| `--igpu` | off | Enable iGPU passthrough (auto-detects Intel or AMD) |
| `--igpu-pci ADDR` | auto-detect | iGPU PCI address (e.g. `0000:00:02.0`) |
| `--igpu-audio ADDR` | auto-detect | Audio PCI address for passthrough |
| `--igpu-gms HEX` | `0x2` | (Intel only) DVMT pre-alloc: `0x2`=64M, `0x4`=128M, `0x8`=256M |
| `--igpu-rom FILE` | auto per vendor | ROM filename in `/usr/share/kvm/` (Intel default: `ultra-1-2-qemu10.rom` — desktop Core Ultra 1st/2nd gen) |
| `--board-mfg NAME` | `Maxsun` | Motherboard manufacturer |
| `--board-product NAME` | `MS-Terminator B760M` | Motherboard product name |
| `--disk-serial SERIAL` | random 20-char | Disk serial number |
| `--mem-mfg NAME` | `KINGSTON` | Memory module manufacturer |
| `--mem-speed SPEED` | `3200` | Memory speed in MT/s |
| `--mem-part PART` | auto per CPU vendor | Memory part number |
| `--mem-asset DIGITS` | random 10-digit | Memory asset tag (upstream: `9876543210`) |
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
- **SCSI controller** — `virtio-scsi-single` matching upstream (patched binary changes PCI-IDs)
- **e1000 NIC** with Dell/Intel MAC prefix (`D8:FC:93`) — Intel 82540EM adapter (matches upstream)
- **SMBIOS spoofing** — Types 0 (BIOS), 1 (System), 2 (Baseboard), 3 (Chassis), 4 (Processor), 8 (Ports), 9 (Slots), 17 (Memory — serial + asset by default per upstream QEMU 10+/11; full format with manufacturer, speed, part, bank, location prefix via `--mem-*` flags). QEMU 11 binary additionally auto-emits types 7 (Cache), 20 (Mapped Address), 26 (Voltage Probe), 27 (Cooling Device).
- **ACPI tables** — fans, thermal zones, embedded controller, HPET, PIT
- **CPU flags** — `host,host-cache-info=on,hypervisor=off,vmware-cpuid-freq=false,enforce=false,host-phys-bits=true`
- **Host EFI variable injection** — real Secure Boot certs from host replace OVMF defaults (defeats NVRAM detection)
- **S3/S4 sleep states** enabled via ICH9-LPC globals (defeats POWER_CAPABILITIES detection)
- **PIT SSDT** — PNP0100 device node (defeats SYSTEM_TIMERS / CLOCK detection)
- **Auto-detected CPU topology** — `cores:` and `sockets:` in the VM conf match host CPUID exactly (Arrow Lake / Core Ultra hosts are auto-detected and forced to threads-per-core=1); PVE then generates `-smp` from those values, so we don't add `-smp` to args (defeats THREAD_MISMATCH detection)
- **Balloon disabled** — balloon devices are a detection vector
- Optional: **TPM 2.0** (`--tpm`), **CPU affinity** (`--affinity`), **iGPU passthrough** (`--igpu` — Intel or AMD)

**What the patched QEMU 11 binary handles internally** (do NOT add these manually):
- KVM/hypervisor CPUID leaf hiding (`kvm=off` is handled inside the binary)
- TSC frequency pinning, `invtsc`, `tsc-deadline`, `tsc_adjust`
- System timers: HPET, PIT, RTC, ACPI PM timer obfuscation
- EFI NVRAM variable sanitization
- CPU power management passthrough
- CPU topology masking

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

> 🛡️ **AV / EDR warning.** These scripts download Sysinternals PsExec64 (Microsoft-signed; we verify the Authenticode signature before invoking it), execute registry cleanup as `SYSTEM`, rewrite `MachineGuid`/`ProductId`/MAC address, and clear Windows event logs. **Every modern AV/EDR will flag at least one of those operations.** Before running:
>
> 1. **Snapshot the VM** so you can roll back if something goes wrong.
> 2. Add `windows\` to Windows Defender exclusions (`Add-MpPreference -ExclusionPath "C:\path\to\windows"`) — otherwise Defender will quarantine `PsExec64.exe` (signature `HackTool:Win32/PsExec`) and the cleanup payload will silently no-op.
> 3. **Do not run on a machine where anti-cheat is installed.** Bulk identifier rewrites + event-log clearing is itself a textbook anti-cheat trip signal. The premise of these scripts is to *defeat fingerprinting in a fresh sandbox VM*, not to evade detection in a real gaming environment — see the disclaimer at the top of this README.

> **Attribution:** These guest-side cleanup scripts started from the PowerShell tools in [Scrut1ny/AutoVirt](https://github.com/Scrut1ny/AutoVirt) (`resources/scripts/Windows/`). They have since been substantially rewritten and now go well beyond the upstream versions:
>
> - **EDID spoofer** — AutoVirt zeroes the monitor serial bytes (which itself reads as "no serial assigned" and is suspicious on a named monitor). Ours randomises with non-zero values and writes a realistic 7-char alphanumeric string into the 0xFF descriptor with the correct 0x0A terminator and 0x20 padding.
> - **QEMU cleanup** — AutoVirt scans 3 patterns (`VEN_1AF4`, `DEV_1B36`, `SUBSYS_11001AF4`) and then nukes **every** subkey under `Enum\SCSI`, which can take out the active boot disk's registry entries. Ours scans 30+ patterns covering VirtIO/QEMU/Bochs/VBOX/VMware/KVM/S3 Corp/FWCF/WAET/etc., **filters** `Enum\SCSI` by VM signatures so SATA/NVMe stay intact, and additionally cleans the DriverStore, hidden PnP devices (via `pnputil`), event logs, prefetch entries, scheduled tasks, BIOS/CPU registry leaks, `setupapi.dev.log`, and Windows Error Reporting reports.
> - **Identifier spoofer** — Net-new in this repo (AutoVirt has no equivalent). Randomises MachineGuid, InstallDate, hostname, MAC OUI, ProductId, HardwareGUID, SQM/SusClient/PingID, BuildGUID, DiagTrack, AdvertisingInfo (HKLM + HKCU), NetworkList Profiles/Signatures, and validates SMBIOS doesn't leak.

### Quick Launch

Double-click **`run-tools.bat`** — it auto-elevates to Administrator, bypasses the PowerShell execution policy, and runs all three cleanup scripts in sequence:

```text
  [1/3]  QEMU Cleanup        - Remove VM registry & driver traces
  [2/3]  Identifier Spoofer  - Randomise machine IDs / MAC / hostname
  [3/3]  EDID Spoofer        - Strip monitor serial numbers
         → Automatic reboot after completion
```

### 1. `qemu-cleanup.ps1` — Registry & Driver Artefact Removal

Removes QEMU, VirtIO, Red Hat, Bochs, and VMware traces from the Windows registry, SCSI tree, and DriverStore. Uses PsExec64 (auto-downloaded from Sysinternals) to run as SYSTEM for full registry access.

```powershell
# Runs as SYSTEM via PsExec64 (auto-downloaded)
.\qemu-cleanup.ps1
```

| Feature | Detail |
|---|---|
| **Signature list** | `VEN_1AF4`, `DEV_1B36`, `SUBSYS_11001AF4`, `VEN_1234`, `DEV_0627`, `VEN_15AD`, `QEMU`, `BOCHS`, `VirtIO`, `VBOX`, `Red Hat`, `DEV_1050`, `DEV_1053`, `SUBSYS_00001AF4`, `VEN_1D6B`, `PCI\VEN_1B36`, `S3 Corp`, `FWCF`, `WAET`, `VS2005R2`, `KVMKVMKVM`, `DEV_1100`, `pvpanic`, `qemufwcfg`, `QXL`, `Balloon`, `viogpu`, `VMSVGA`, `vmwgfx` |
| **Registry roots scanned** | `Enum`, `SCSI`, `Services`, `Control\Class` |
| **SCSI wipe** | VM-matching sub-keys under `Enum\SCSI` removed (preserves legitimate SATA/NVMe entries) |
| **DriverStore** | VirtIO/QEMU driver packages in `FileRepository` deleted (`vio*`, `qemu*`, `virtio*`, `red_hat*`, `netkvm*`, `balloon*`, `pvpanic*`, `spice*`, `qxl*`, `viogpu*`) |
| **Hidden device removal** | Enumerates all PnP devices (including ghost/disconnected) and removes those matching VM signatures via `pnputil` |
| **Event log cleanup** | Clears System, Application, and Setup event logs to remove VM-related entries |
| **Prefetch cleanup** | Deletes prefetch files for VM-related executables (QEMU, VirtIO, Balloon, Spice, etc.) |
| **Task scheduler cleanup** | Removes scheduled tasks referencing VM tools (QEMU, VirtIO, Spice, balloon, qemu-ga) |
| **BIOS registry validation** | Scans `HKLM:\HARDWARE\DESCRIPTION\System\BIOS` and `CentralProcessor\0` for residual VM strings (`QEMU`, `BOCHS`, `VBOX`, `VMware`, `SeaBIOS`, `OVMF`, `KVM`, `innotek`). Warns if SMBIOS spoofing leaked. |
| **Setupapi log cleanup** | Deletes device installation trace logs (`setupapi.dev.log`, `setupapi.app.log`) that record VM hardware PnP enumeration events |
| **WER report cleanup** | Removes Windows Error Reporting files that may reference VM hardware names |

### 2. `identifier-spoofer.ps1` — Machine Identity Randomiser

Randomises 8 categories of Windows identifiers commonly used for hardware fingerprinting.

```powershell
.\identifier-spoofer.ps1
```

Now covers 16 identifiers including Windows Update PingID, AdvertisingInfo ID, network profiles, and SMBIOS validation.

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
| 9 | BuildGUID | `HKLM:\...\Windows NT\CurrentVersion` |
| 10 | DiagTrack MachineId | `HKLM:\...\Diagnostics\DiagTrack` |
| 11 | Hardware Profile GUID | `HKLM:\...\IDConfigDB\Hardware Profiles\0001` |
| 12 | Windows Update PingID | `HKLM:\..\WindowsUpdate` |
| 13 | AdvertisingInfo ID | `HKLM:\..\AdvertisingInfo` + `HKCU:\..\AdvertisingInfo` |
| 14 | Network Profile GUIDs | `HKLM:\...\NetworkList\Profiles` (cross-session fingerprint prevention) |
| 15 | Network Signatures | `HKLM:\...\NetworkList\Signatures` (MAC/SSID cleanup) |
| 16 | SMBIOS Validation | `HKLM:\HARDWARE\DESCRIPTION\System\BIOS` (warns if VM strings detected) |
Reboot is handled by `run-tools.bat` after all scripts complete.

### 3. `edid-spoofer.ps1` — Monitor Serial Removal

Strips hardware serial numbers from the EDID data that anti-cheat reads via WMI, then writes a sanitised `EDID_OVERRIDE` to the registry.

```powershell
# Spoof all connected monitors + restart graphics driver
.\edid-spoofer.ps1
```

| Feature | Detail |
|---|---|
| **Bytes zeroed** | EDID[12-15] (ID serial) randomized + any 0xFF descriptor (alphanumeric serial) randomized |
| **Checksum** | Base-block checksum (byte 127) automatically recomputed |
| **Extension blocks** | All CTA/DisplayID extension blocks preserved and forwarded |

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
| **Patched packages — base PVE release** | [AICodo/pve-emu-realpc — `v20260516-211490-pve9`](https://github.com/AICodo/pve-emu-realpc/releases/tag/v20260516-211490-pve9) (v11.0.0-2 — latest) |
| **Patched packages — Strong overlay** | [AICodo/pve-emu-realpc — `v20260506-222829-pve9`](https://github.com/AICodo/pve-emu-realpc/releases/tag/v20260506-222829-pve9) (v11.0.0-1 enhanced, kernel 6.17.13-2) |
| **Patched ROMs (Debian release)** | [AICodo/pve-emu-realpc — `v20260507-200382-debian`](https://github.com/AICodo/pve-emu-realpc/releases/tag/v20260507-200382-debian) (v11.0.0 for debian13) |
| **Guest cleanup scripts (origin)** | [Scrut1ny/AutoVirt](https://github.com/Scrut1ny/AutoVirt) — `resources/scripts/Windows/` |
| **Anti-detection source code** | [AICodo/pve-emu-realpc](https://github.com/AICodo/pve-emu-realpc) (fork lineage: [lixiaoliu666/pve-anti-detection](https://github.com/lixiaoliu666/pve-anti-detection)) |
| **Technical documentation** | [DeepWiki — pve-anti-detection](https://deepwiki.com/lixiaoliu666/pve-anti-detection) |
| **Original fork source** | [zhaodice/qemu-anti-detection](https://github.com/zhaodice/qemu-anti-detection) |
| **OVMF firmware source** | [AICodo/pve-emu-realpc_edk2-firmware-ovmf](https://github.com/AICodo/pve-emu-realpc_edk2-firmware-ovmf) |
| **Intel iGPU ROMs** | [AICodo/intel-ultra-rom — `v2.0-20260307-095826`](https://github.com/AICodo/intel-ultra-rom/releases/tag/v2.0-20260307-095826) — multiple SKU ROMs (see below) |
| **Standalone QEMU patches** | [AICodo/qemu-emu-realpc](https://github.com/AICodo/qemu-emu-realpc) — raw `.patch` files for QEMU 6.2–11.0.0 (non-PVE / libvirt) |
| **Authors** | Li Xiaoliu (李晓流) & DadaShuai666 (大大帅666) |

The Strong build (sensor passthrough for CPU temperature/MHz/voltage/power) is an enhancement by [AICodo](https://github.com/AICodo) supporting both Intel and AMD CPUs on PVE 9.

---

## Related Repos & Resources

Nice-to-know projects in the VM anti-detection / virtualisation space:

| Repository | Description |
|---|---|
| [Scrut1ny/AutoVirt](https://github.com/Scrut1ny/AutoVirt) | Automated Linux virtualisation scripts covering QEMU, KVM, libvirt, VFIO GPU passthrough, EDK2/OVMF patching, and more. Shell-based with 590+ stars. Good reference for building anti-detection setups from source on Fedora/Debian. |
| [Justsenger/ExHyperV](https://github.com/Justsenger/ExHyperV) | WPF/C# graphical management tool for advanced Hyper-V features on Windows 10/11 Pro & Server 2019/2022/2025 (4k+ stars). Configures GPU-PV (GPU paravirtualization, requires Build 17134+), CPU pinning, memory tuning, PCIe passthrough, and detailed networking — drop-in alternative if you'd rather run Windows VMs natively on a Windows host instead of QEMU/KVM. |
| [t4bby/smbios-patcher](https://github.com/t4bby/smbios-patcher) | CLI utility (C / Meson) for patching SMBIOS binary dumps. Lets you set BIOS vendor, system manufacturer, serial number, UUID, CPU info, baseboard, chassis, and memory device fields — then feed the patched binary back into QEMU. |
| [t4bby/smbios-parser](https://github.com/t4bby/smbios-parser) | Lightweight C99/C++98 library for parsing SMBIOS/DMI tables. Fork of brunexgeek/smbios-parser with added file-read support. Handy for inspecting what your guest actually exposes before and after patching. |
| [Ape-xCV/Nika-Read-Only](https://github.com/Ape-xCV/Nika-Read-Only) | In-depth QEMU/KVM anti-detection walkthrough for bare-metal Linux (Fedora/Debian + libvirt). Covers patched QEMU & OVMF builds, VFIO GPU passthrough, evdev input, SMBIOS spoofing, EDID spoofing, custom kernel builds, and network spoofing. |

---

## FAQ / Troubleshooting

**Q: The script says "REBOOT REQUIRED" after setup — is that normal?**
A: Yes. If your running kernel didn't match the patched KVM module, the script installed the correct kernel and pinned it as the boot default. Run `reboot`, then verify with `uname -r`. After reboot, proceed directly to VM deployment — no need to re-run the setup script.

**Q: Do I need to reboot after running the setup script?**
A: Only if the KVM module was already loaded (VMs were running). The script will warn you. Otherwise, no reboot is needed.

**Q: The setup script shows `modprobe: ERROR: could not insert 'kvm': Key was rejected by service` — what does this mean?**
A: **Secure Boot is enabled on your Proxmox host.** The patched `kvm.ko` module is not signed with a trusted key, so the kernel refuses to load it. This will **not** fix itself after a reboot — the same signature check will reject it again. **Fix:** Disable Secure Boot in your BIOS/UEFI settings, then reboot. Proxmox does not need Secure Boot on the host; only the guest VM uses Secure Boot (handled by OVMF). After disabling, verify with:
```bash
dmesg | grep -i kvm
# Should show: kvm.ko aicodo v3.x ... Start,ok!!!
```

**Q: Will `apt upgrade` break the patched packages?**
A: No — the setup script pins `pve-qemu-kvm` and `pve-edk2-firmware-ovmf` at priority `-1` and marks them as held. You must explicitly unpin before upgrading these packages.

**Q: Which PVE version is supported?**
A: The current setup uses base from `v20260516-211490-pve9` (QEMU 11.0.0-2) + Strong overlay from `v20260506-222829-pve9` (QEMU 11.0.0-1 enhanced), both targeting **PVE 9**. Older releases on the [AICodo releases page](https://github.com/AICodo/pve-emu-realpc/releases) support PVE 8 and QEMU 7/8/9/10.

**Q: Can I use this on bare Debian/Ubuntu (not Proxmox)?**
A: Yes! For non-PVE setups, use [AICodo/qemu-emu-realpc](https://github.com/AICodo/qemu-emu-realpc) which provides raw `.patch` files for QEMU 6.2.0–11.0.0. These patches apply the same anti-detection modifications (sedPatch + smbios.c) to a standard QEMU build. The repo includes build instructions for Debian/Ubuntu/Arch and a libvirt XML template. The AICodo Debian releases (e.g. [`v20260507-200382-debian`](https://github.com/AICodo/pve-emu-realpc/releases/tag/v20260507-200382-debian)) also provide pre-built `qemu-system-x86_64` binaries for Debian 13. These deploy scripts are Proxmox-specific, but the upstream anti-detection patches work on any Linux distribution with `qemu-system-x86_64`.

**Q: The VM still gets detected — what should I check?**
1. Verify the Strong QEMU binary is installed: `ls -la /usr/bin/qemu-system-x86_64` (should be ~30 MB for v11; v10.2.1 was ~29.7 MB)
2. Verify the **Strong OVMF** is installed (not stock): `dpkg -l | grep pve-edk2-firmware`
3. Check ACPI tables exist: `ls /root/*.aml`
4. Ensure the `args:` line in `/etc/pve/qemu-server/<VMID>.conf` matches the upstream minimal format (see below)
5. **Remove any extra args**: `kvm=off`, `-smp`, `-rtc`, `-overcommit`, `-global`, `+invtsc`, `tsc-frequency=`, `affinity:` — the binary handles these internally
6. **Remove `pre-enrolled-keys=1`** from `efidisk0:` — stock OVMF templates contain detectable NVRAM variables
7. Check you did NOT install VirtIO drivers or QEMU guest agent inside Windows
8. Run `windows\run-tools.bat` to clean VM fingerprints from the guest registry
9. Verify the patched KVM module is loaded: `modinfo kvm | grep filename`

**Q: I'm failing timing anomalies, NVRAM, system timers, or thread count — what went wrong?**

The patched QEMU 11 binary handles **all** of these internally. If you're failing, it's almost certainly because extra args flags are **conflicting** with the binary's built-in handling. The upstream author explicitly states:

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
- `-global ICH9-LPC.disable_s3=1` / `disable_s4=1` (the deploy script sets `=0` to enable S3/S4 — do not set `=1`)
- `+invtsc`, `+tsc-deadline`, `+tsc_adjust`, `+rdpid`, `+xsaves`, `+pdpe1gb`, `+umip`, `+md-clear`, `+arch-capabilities` (binary handles CPUID)
- `tsc-frequency=...` (binary handles TSC)
- `affinity:` line (not needed)
- `pre-enrolled-keys=1` on `efidisk0:` (causes detectable NVRAM)

Also verify your `efidisk0:` does NOT have `pre-enrolled-keys=1` — the patched OVMF handles EFI variables internally.

**Q: How do I update when a new release comes out?**
A: Just re-run `bash pve-realpc-setup.sh`. The dynamic resolver queries the GitHub API and auto-picks the newest base + last-Strong-shipping tag. Run `bash pve-realpc-setup.sh --list-releases` first if you want to see what's available, or pin a specific tag with `--release-tag TAG` / `--strong-tag TAG`. The static `RELEASE_TAG` / `STRONG_TAG` constants at the top of the script are only used as a fallback when the GitHub API can't be reached.

**Q: What about GPU passthrough?**
A: Deploy the VM with `--vga none`, then add your GPU as a PCI device via `qm set <VMID> --hostpci0 ...`. For NVIDIA cards that show error 43, use `--type laptop` to include `ssdt-battery.aml`.

**Q: I have an Intel Core Ultra 155H / 255H mobile CPU — which iGPU ROM should I use?**
A: The upstream [AICodo/intel-ultra-rom release](https://github.com/AICodo/intel-ultra-rom/releases/tag/v2.0-20260307-095826) ships four variants:

| ROM filename | Target SKU |
|---|---|
| `ultra-1-2-qemu10.rom` (default) | Generic Intel Core Ultra 1st/2nd gen |
| `pc-ultra-1-2-qemu10.rom` | Desktop Core Ultra 1st/2nd gen |
| `nb-155h-qemu10.rom` | Notebook Core Ultra 155H (Meteor Lake mobile) |
| `nb-255h-qemu10.rom` | Notebook Core Ultra 255H (Arrow Lake-H mobile) |

The setup script auto-downloads the generic `ultra-1-2-qemu10.rom`. To use a SKU-specific ROM, download it manually from the release page into `/usr/share/kvm/`, then pass it to the deploy script: `bash pve-realpc-deploy-vm.sh --igpu --igpu-rom nb-155h-qemu10.rom`. The release also includes an `EfiRom.exe` tool and an `edk2-autoGenPatch.patch` for users who want to build their own ROM. All Intel iGPU ROMs require QEMU 10 or higher (QEMU 7/8/9 are incompatible).

**Q: Will this defeat 100% of VMAware checks?**
A: No. As of [VMAware v2.7.0](https://github.com/kernelwernel/VMAware/releases/tag/v2.7.0), several new 100%-certainty Windows checks operate at the KVM/hypervisor level and are **not** fully defeated by this setup:

| VMAware technique | What it detects | Status |
|---|---|---|
| `VM::KVM_INTERCEPTION` | KVM patching of mismatched `VMMCALL` instructions | Patched `kvm.ko` may help, no guarantee |
| `VM::HYPERVISOR_HOOK` | EPT/NPT hooking used to intercept hardware breakpoints | Not defeated |
| `VM::BLOCKSTEP` | Hypervisor failing to restore interruptibility state after VM-exit | Not defeated |
| `VM::POPF` | Hypervisor delaying trap flags across exiting instructions | Not defeated |
| `VM::EIP_OVERFLOW` | Hypervisor not correctly emulating compatibility mode | Not defeated |
| `VM::TRAP` | Hypervisor interfering with instruction pointer delivery after two traps at same RIP | Not defeated |
| `VM::HYPERVISOR_QUERY` | `NtQuerySystemInformation(0x9f)` populating `_SYSTEM_HYPERVISOR_DETAIL_INFORMATION` | Possibly defeated by patched `kvm.ko` |

These represent the bleeding edge of VM detection and require kernel/hypervisor-level patching that is beyond what `cpu host,hypervisor=off` and the patched OVMF/SeaBIOS can address. The patched `kvm.ko` already hides much of KVM's CPUID/MSR surface, but the timing/exception-based hypervisor probes above remain partially detectable. For sandbox/anti-cheat use cases that don't run VMAware v2.7+, the setup defeats the broader fingerprinting surface (FIRMWARE, NVRAM, BOOT_LOGO, DEVICES, SMBIOS, CLOCK, POWER_CAPABILITIES, DISK_SERIAL, EDID, THREAD_MISMATCH, DISPLAY, GPU_CAPABILITIES). For maximum coverage you would need bare-metal hardware.

---

## License

These deployment scripts are provided as-is. The upstream patched packages are built from the [pve-anti-detection](https://github.com/lixiaoliu666/pve-anti-detection) and [pve-emu-realpc](https://github.com/AICodo/pve-emu-realpc) repositories — refer to those projects for their respective licenses.
