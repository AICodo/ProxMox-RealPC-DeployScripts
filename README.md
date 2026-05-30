<p align="center">
  <img src="https://img.shields.io/badge/QEMU-11.0.0-FF6600?style=for-the-badge&logo=qemu&logoColor=white" alt="QEMU 11">
  <img src="https://img.shields.io/badge/Proxmox-VE_9-E57000?style=for-the-badge&logo=proxmox&logoColor=white" alt="Proxmox VE 9">
  <img src="https://img.shields.io/badge/license-MIT-green?style=for-the-badge" alt="MIT">
  <img src="https://img.shields.io/badge/platform-Linux_|_Windows-blue?style=for-the-badge" alt="Platform">
</p>

<h1 align="center">
  ⚡ ProxMox RealPC DeployScripts ⚡
</h1>

<p align="center">
  <i>Cloak your VMs. Defeat detection. Own your hardware.</i>
</p>

<p align="center">
  <sub>Deployment automation and Windows guest hardening for the <a href="https://github.com/AICodo/pve-emu-realpc">pve-emu-realpc</a> anti‑detection stack.</sub>
</p>

<p align="center">
  <sub><i>For security research, sandboxing, and malware analysis only. You are responsible for how you use this.</i></sub>
</p>

<br>

---

## 📦 What's Inside

<pre align="center">
<b>pve-realpc-setup.sh</b>       →  One-shot host prep — patched QEMU · OVMF · KVM
<b>pve-realpc-deploy-vm.sh</b>   →  Per‑VM cloaking — SMBIOS · ACPI · NVRAM · timing
<b>windows/run-tools.bat</b>     →  Guest cleanup launcher (auto‑elevate)
<b>windows/qemu-cleanup.ps1</b> →  Registry & driver artefact removal (30+ sigs)
<b>windows/identifier-spoofer.ps1</b> →  Machine identity randomiser (16 fields)
<b>windows/edid-spoofer.ps1</b> →  Monitor serial spoofing (realistic non‑zero)
</pre>

> The Windows tools are heavily rewritten from [Scrut1ny/AutoVirt](https://github.com/Scrut1ny/AutoVirt) — broader pattern coverage, safe SCSI filtering, realistic EDID serials, and the identifier spoofer is entirely new.

---

## 🔗 Source Repos

| Repository | Stars | Role |
|:---|:---:|:---|
| [**AICodo/pve-emu-realpc**](https://github.com/AICodo/pve-emu-realpc) | `473` | **Primary upstream** — patched QEMU · OVMF · KVM for PVE 9 |
| [zhaodice/qemu-anti-detection](https://github.com/zhaodice/qemu-anti-detection) | `1.5k` | **Original source** — patches for QEMU 6.2 → 10.2.2 |
| [Scrut1ny/AutoVirt](https://github.com/Scrut1ny/AutoVirt) | `684` | **Guest scripts origin** — libvirt · VFIO · OVMF (GPL‑3.0) |
| [lixiaoliu666/pve-anti-detection](https://deepwiki.com/lixiaoliu666/pve-anti-detection) | — | **DeepWiki docs** — repo ↪ AICodo/pve-emu-realpc |
| [AICodo/qemu-emu-realpc](https://github.com/AICodo/qemu-emu-realpc) | — | Standalone `.patch` files (non‑PVE / libvirt) |
| [AICodo/pve-emu-realpc_edk2-firmware-ovmf](https://github.com/AICodo/pve-emu-realpc_edk2-firmware-ovmf) | — | Patched EDK2 / OVMF firmware |
| [AICodo/intel-ultra-rom](https://github.com/AICodo/intel-ultra-rom) | — | Intel iGPU passthrough ROMs (Ultra desktop & notebook) |

### 🧪 Detection Validation

| Tool | | Tool | |
|:---|:---:|:---|:---:|
| [pafish](https://github.com/a0rtega/pafish) | — | [al‑khaser](https://github.com/LordNoteworthy/al-khaser) | — |
| [VMAware](https://github.com/kernelwernel/VMAware) | — | | |

### 🌐 Related Projects

| Repository | Stars | Description |
|:---|:---:|:---|
| [Justsenger/ExHyperV](https://github.com/Justsenger/ExHyperV) | `4k+` | Hyper‑V GPU‑PV · CPU pinning · PCIe passthrough |
| [t4bby/smbios-patcher](https://github.com/t4bby/smbios-patcher) | — | CLI SMBIOS binary patcher (C / Meson) |
| [t4bby/smbios-parser](https://github.com/t4bby/smbios-parser) | — | C99 / C++98 SMBIOS table parser |
| [Ape‑xCV/Nika‑Read‑Only](https://github.com/Ape-xCV/Nika-Read-Only) | — | QEMU / KVM anti‑detection walkthrough |

---

## 🙏 Credits

Anti‑detection by **Li Xiaoliu** (李晓流) & **DadaShuai666** (大大帅666). Strong build by [AICodo](https://github.com/AICodo). Windows tools derived from [Scrut1ny/AutoVirt](https://github.com/Scrut1ny/AutoVirt).

---

<p align="center">
  <sub>MIT © <a href="LICENSE">Diobyte</a> — scripts & docs only. Upstream QEMU binaries are GPL‑2.0.</sub>
</p>
