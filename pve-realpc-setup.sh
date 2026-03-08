#!/usr/bin/env bash
###############################################################################
# pve-realpc-setup.sh — PVE Anti-VM-Detection Host Setup (AICodo/pve-emu-realpc)
#
# Fully automates:
#   1. MAC prefix configuration (Datacenter level)
#   2. Download of ALL release assets (PVE debs, Strong .tgz, ACPI tables)
#   3. Download of Debian release assets (patched ROM/BIOS files only)
#   4. Backup of stock QEMU & OVMF packages
#   5. Installation of base anti-detection debs
#   6. Extraction & installation of Strong build debs
#   7. Overlay patched Debian ROM/BIOS/VGA files (removes VM strings; keeps PVE binary)
#   8. Installation of patched KVM kernel module (Intel or AMD)
#   9. Placement of ACPI table files (/root/)
#  10. Intel Ultra iGPU passthrough setup (optional, --igpu)
#  11. Package pinning (prevent apt from overwriting patched QEMU/OVMF)
#  12. Verification of installation
#
# Usage:   bash pve-realpc-setup.sh [--skip-download] [--skip-pin] [--skip-kernel-downgrade] [--igpu]
# Requires: root on a Proxmox VE 9 host, internet access (for downloads)
###############################################################################
set -euo pipefail
IFS=$'\n\t'

# ─── Tunables ────────────────────────────────────────────────────────────────
RELEASE_TAG="v20260306-213905-pve9"
BASE_URL="https://github.com/AICodo/pve-emu-realpc/releases/download/${RELEASE_TAG}"
WORK_DIR="/root/pve-realpc"
ACPI_DIR="/root"                       # ACPI .aml files go here (args reference /root/)
MAC_PREFIX="D8:FC:93"                  # Realistic Dell/Intel OUI
DATACENTER_CFG="/etc/pve/datacenter.cfg"
BACKUP_DIR="/root/pve-realpc/backup"

# Debian release — patched ROM/BIOS files with VM strings removed
# The PVE deb and Debian release are built from the SAME sedPatch source patches,
# but only the Debian release includes separately compiled SeaBIOS/VGA/EFI ROMs
# with "QEMU", "Bochs", "SeaBIOS" strings scrubbed (the PVE deb ships stock ROMs).
# The QEMU binary from the PVE deb is PREFERRED over the Debian one because it
# includes PVE management integration + Strong build CPU sensor passthrough
# (the PVE qemu-autoGenPatch.patch is also ~836 bytes larger with extra patches).
# We only use the Debian release for ROM overlay, NOT the binary.
DEBIAN_TAG="v20260307-191041-debian"
DEBIAN_URL="https://github.com/AICodo/pve-emu-realpc/releases/download/${DEBIAN_TAG}"
DEBIAN_BIOS_FILES=("bios-256k.bin" "bios.bin" "bios-microvm.bin")
DEBIAN_EFI_ROMS=("efi-e1000.rom" "efi-e1000e.rom" "efi-virtio.rom")
DEBIAN_VGA_ROMS=("vgabios-qxl.bin" "vgabios-stdvga.bin")
DEBIAN_ALL_ROMS=("${DEBIAN_BIOS_FILES[@]}" "${DEBIAN_EFI_ROMS[@]}" "${DEBIAN_VGA_ROMS[@]}")
SEABIOS_PATCH="seabios-autoGenPatch.patch"

# PVE release asset filenames (OVMF + Strong build + KVM module)
QEMU_BASE_DEB="pve-qemu-kvm_10.1.2-7_amd64.deb"
OVMF_BASE_DEB="pve-edk2-firmware-ovmf_4.2025.05-2_all.deb"
STRONG_TGZ="pve-qemu-kvm_10.1.2-7_amd64_Strong_intel_amd.tgz"
STRONG_QEMU_DEB="pve-qemu-kvm_10.1.2-7_amd64_Strong.deb"
STRONG_OVMF_DEB="pve-edk2-firmware-ovmf_4.2025.05-2_all_Strong.deb"
PATCH_FILE="qemu-autoGenPatch.patch"
ACPI_FILES=("ssdt.aml" "ssdt-ec.aml" "ssdt-battery.aml" "hpet.aml")

# Intel Ultra iGPU passthrough ROM (AICodo/intel-ultra-rom)
IGPU_ROM_TAG="v2.0-20260307-095826"
IGPU_ROM_URL="https://github.com/AICodo/intel-ultra-rom/releases/download/${IGPU_ROM_TAG}"
IGPU_ROM_FILE="ultra-1-2-qemu10.rom"
IGPU_ROM_DIR="/usr/share/kvm"

# SHA-256 digests (from GitHub release API) for integrity verification
# NOTE: Debian release assets do not have verified checksums yet —
#       they are downloaded fresh from the latest release each time.
#       Add hashes here after verifying a known-good download.
declare -A CHECKSUMS=(
    # PVE release assets
    ["hpet.aml"]="cb0cf3c29fdf5b734422ec3f64589f1b88a11bb0a0f30bb41c6ce63c3e61367b"
    ["${OVMF_BASE_DEB}"]="cbdb7c949c057a8c5972ffb4fef03dd7c9fa52e42aa94cee63b00be1af4b9d81"
    ["${QEMU_BASE_DEB}"]="cbbfd70769da198d17ead114bf4d32879c1ac015288dbe1c00982d6f983a88d8"
    ["${STRONG_TGZ}"]="94e56520c4cb2c3fb4d0be40e703fae1e58b56cabe4d777123ffa44b4e8f0176"
    ["${PATCH_FILE}"]="57a5c63baec4875b45e00e1ccbbd8ff41e9fa6132219c39558955428f56bcfb3"
    ["ssdt-battery.aml"]="ea9c737cde6384c7e86028fe891ed3d8662721b8e254aea54f5d227d1e8009f1"
    ["ssdt-ec.aml"]="6694edf9c3cc5914063dcb3e25f374531f65801374dbae90fb8604fa9851d48a"
    ["ssdt.aml"]="09e3aa35a9a7a63801ea4231846bf7835b6ca398f2024ceb79673df6d409a341"
    ["${IGPU_ROM_FILE}"]="b392ce4be9f1ff3e98dc45549248ba82d17d228a94c19a946b90d35ede97f0cc"
    # Debian release assets (ROM/BIOS files only — we do NOT use the Debian binary)
    ["bios-256k.bin"]="d4e9f97b049591c2e45327ed85a92255eae5002720f3a2b8c57e0e80824db930"
    ["bios.bin"]="a14dce0d9d9fb8118cdc3039e75066ef0b6c5a4150545e627a9baa8481baf19b"
    ["bios-microvm.bin"]="6cc4b9fb5c069ba4524054b5fb94ac3a20fc75878beb0c8234303cd9484a0132"
    ["efi-e1000.rom"]="f37222fcdf0481bfbaf7a16d9aaf740aeb41d3d24c187801eb6e9a628cec0fc8"
    ["efi-e1000e.rom"]="102c20348be2d0ebe45a77b076b31848182c2f7b4364775b6bc2ece6e97b4024"
    ["efi-virtio.rom"]="26be36901db7f8181c306cc62bd74891d8646528965a78e40cceadba5dd7c8e7"
    ["vgabios-qxl.bin"]="33f6e0775ff725026e6f7eba21c8a0ad816ecfe238c4923fa26e8eeaa2aa0b04"
    ["vgabios-stdvga.bin"]="e8fc9e55790dbe3cb31f019a3deb57206ba6c54f5e581adb2ab2677a9d391472"
    ["seabios-autoGenPatch.patch"]="6900d4e60fe8453c0bdc14ed3f83d88314ab0bcfeaa13e3d008d719b3c780173"
)

# ─── Flags ───────────────────────────────────────────────────────────────────
SKIP_DOWNLOAD=false
SKIP_PIN=false
SKIP_KERNEL_DOWNGRADE=false
ENABLE_IGPU=false
NEEDS_REBOOT=false
for arg in "$@"; do
    case "$arg" in
        --skip-download)          SKIP_DOWNLOAD=true ;;
        --skip-pin)               SKIP_PIN=true ;;
        --skip-kernel-downgrade)  SKIP_KERNEL_DOWNGRADE=true ;;
        --igpu)                   ENABLE_IGPU=true ;;
        --help|-h)
            echo "Usage: $0 [--skip-download] [--skip-pin] [--skip-kernel-downgrade] [--igpu]"
            echo "  --skip-download           Skip downloading assets (use existing files in ${WORK_DIR})"
            echo "  --skip-pin                Skip APT package pinning"
            echo "  --skip-kernel-downgrade   Skip automatic kernel downgrade if version mismatch"
            echo "  --igpu                    Download Intel Ultra iGPU ROM & configure host for passthrough"
            exit 0
            ;;
        *) echo "Unknown argument: $arg"; exit 1 ;;
    esac
done

# ─── Helpers ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; exit 1; }

require_root() {
    [[ $EUID -eq 0 ]] || fail "This script must be run as root."
}

check_pve9() {
    if ! command -v pveversion &>/dev/null; then
        fail "pveversion not found — this script requires Proxmox VE."
    fi
    local pve_ver
    pve_ver=$(pveversion 2>/dev/null | grep -oP 'pve-manager/\K[0-9]+')
    if [[ "$pve_ver" != "8" && "$pve_ver" != "9" ]]; then
        warn "Detected PVE major version ${pve_ver}. This release targets PVE 9. Proceed with caution."
    fi
}

detect_cpu_vendor() {
    if grep -qi "GenuineIntel" /proc/cpuinfo; then
        echo "intel"
    elif grep -qi "AuthenticAMD" /proc/cpuinfo; then
        echo "amd"
    else
        fail "Could not detect CPU vendor from /proc/cpuinfo."
    fi
}

verify_checksum() {
    local file="$1" expected="$2"
    local actual
    actual=$(sha256sum "$file" | awk '{print $1}')
    if [[ "$actual" != "$expected" ]]; then
        fail "Checksum mismatch for $(basename "$file"): expected ${expected}, got ${actual}"
    fi
}

###############################################################################
# Kernel downgrade / install helper
# Given a target kernel version fragment (e.g., "6.8.12-8"), finds and installs
# the matching PVE kernel package, pins it as the default GRUB entry, and
# installs the patched kvm.ko into the correct modules directory.
###############################################################################
install_target_kernel() {
    local target_ver_fragment="$1"   # e.g., "6.8.12-8"
    local cpu_vendor="$2"            # "intel" or "amd"
    local kvm_module_src="$3"        # path to the patched kvm.ko file
    local target_kernel="${target_ver_fragment}-pve"

    info "Kernel mismatch detected. Running: ${KERNEL_VER}, Module needs: ${target_ver_fragment}"
    info "Target kernel: ${target_kernel}"

    # ── Determine the PVE kernel package name ──
    # PVE 9 uses "proxmox-kernel-*", PVE 8 used "pve-kernel-*"
    local pkg_name=""
    local pkg_header=""

    # Search for available kernel packages matching the target
    info "Searching APT for kernel matching '${target_kernel}' ..."
    apt-get update -qq 2>/dev/null || true

    # Try proxmox-kernel (PVE 9) first, then pve-kernel (PVE 8)
    for prefix in "proxmox-kernel" "pve-kernel"; do
        local candidate="${prefix}-${target_kernel}"
        if apt-cache show "$candidate" &>/dev/null; then
            pkg_name="$candidate"
            pkg_header="${prefix}-headers-${target_kernel}"
            break
        fi
    done

    if [[ -z "$pkg_name" ]]; then
        # Broader search: list all available kernels and find a match
        warn "Exact package not found. Searching for kernels containing '${target_ver_fragment}' ..."
        local found
        found=$(apt-cache search "proxmox-kernel.*${target_ver_fragment}\|pve-kernel.*${target_ver_fragment}" 2>/dev/null | grep -v "headers\|dbg\|signed" | head -5)
        if [[ -n "$found" ]]; then
            info "Available kernel packages:"
            echo "$found"
            pkg_name=$(echo "$found" | head -1 | awk '{print $1}')
            info "Selecting: ${pkg_name}"
        else
            warn "No kernel package found for version '${target_ver_fragment}' in APT repositories."
            warn "You may need to add the correct Proxmox repository or download the kernel manually."
            warn ""
            warn "Manual fix options:"
            warn "  1. Check available kernels: apt-cache search proxmox-kernel | grep ${target_ver_fragment}"
            warn "  2. Check your APT sources:  cat /etc/apt/sources.list.d/*.list"
            warn "  3. Install manually if you have the .deb: dpkg -i proxmox-kernel-${target_kernel}_*.deb"
            return 1
        fi
    fi

    # ── Install the kernel package ──
    info "Installing kernel package: ${pkg_name} ..."
    if ! apt-get install -y "$pkg_name" 2>&1 | tail -10; then
        fail "Failed to install kernel package ${pkg_name}"
    fi
    ok "Kernel package ${pkg_name} installed"

    # Also install headers if available (not critical)
    if [[ -n "$pkg_header" ]] && apt-cache show "$pkg_header" &>/dev/null; then
        info "Installing kernel headers: ${pkg_header} ..."
        apt-get install -y "$pkg_header" 2>&1 | tail -5 || warn "Headers install skipped (non-critical)"
    fi

    # ── Pin the target kernel as the default GRUB boot entry ──
    info "Pinning kernel ${target_kernel} as default boot entry ..."

    # Method 1: proxmox-boot-tool (preferred on PVE with systemd-boot / ZFS boot)
    if command -v proxmox-boot-tool &>/dev/null; then
        info "Refreshing boot configuration via proxmox-boot-tool ..."
        proxmox-boot-tool refresh 2>&1 | tail -3 || true
    fi

    # Method 2: GRUB pinning (works on all setups)
    local grub_default="/etc/default/grub"
    if [[ -f "$grub_default" ]]; then
        # Find the GRUB menu entry for the target kernel
        # PVE GRUB entries look like: "proxmox-ve-kernel-X.Y.Z-N-pve" in advanced options
        # We use GRUB_DEFAULT=0 with pin so the newest installed kernel (our target) boots first
        # Backup current GRUB config
        cp "$grub_default" "${BACKUP_DIR}/grub.default.bak" 2>/dev/null || true

        # Set GRUB to boot the default (first) entry — PVE sorts by version, newest first
        if grep -q "^GRUB_DEFAULT=" "$grub_default"; then
            sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=0/' "$grub_default"
        else
            echo 'GRUB_DEFAULT=0' >> "$grub_default"
        fi

        # Pin the target kernel via /etc/default/pve-kernel
        # This tells PVE which kernel to prefer
        echo "$target_kernel" > /etc/default/pve-kernel 2>/dev/null || true

        # Rebuild GRUB config
        if command -v update-grub &>/dev/null; then
            info "Updating GRUB configuration ..."
            update-grub 2>&1 | tail -3
        fi
        ok "GRUB configured to boot kernel ${target_kernel}"
    fi

    # ── Install the patched kvm.ko into the TARGET kernel's module tree ──
    local target_kvm_dir="/lib/modules/${target_kernel}/kernel/arch/x86/kvm"
    if [[ -d "/lib/modules/${target_kernel}" ]]; then
        mkdir -p "$target_kvm_dir"

        # Remove any compressed stock module
        rm -f "${target_kvm_dir}/kvm.ko.zst" 2>/dev/null || true

        info "Installing patched kvm.ko into /lib/modules/${target_kernel}/ ..."
        cp "$kvm_module_src" "${target_kvm_dir}/kvm.ko"
        chmod 644 "${target_kvm_dir}/kvm.ko"

        # Rebuild depmod for the target kernel
        depmod -a "$target_kernel" 2>/dev/null || depmod -a
        ok "Patched KVM module installed for kernel ${target_kernel} (${cpu_vendor})"
    else
        warn "Module directory /lib/modules/${target_kernel}/ not found."
        warn "The kernel package may not have been fully installed."
        warn "After reboot, re-run this script with --skip-download to install the KVM module."
    fi

    # ── Flag for reboot ──
    NEEDS_REBOOT=true
    echo ""
    warn "╔══════════════════════════════════════════════════════════════════╗"
    printf "${YELLOW}[WARN]${NC}  ║  %-64s║\n" "REBOOT REQUIRED"
    printf "${YELLOW}[WARN]${NC}  ║%-66s║\n" ""
    printf "${YELLOW}[WARN]${NC}  ║  %-64s║\n" "A different kernel (${target_kernel}) has been installed"
    printf "${YELLOW}[WARN]${NC}  ║  %-64s║\n" "and pinned as the default boot entry."
    printf "${YELLOW}[WARN]${NC}  ║%-66s║\n" ""
    printf "${YELLOW}[WARN]${NC}  ║  %-64s║\n" "Please reboot now:  reboot"
    printf "${YELLOW}[WARN]${NC}  ║%-66s║\n" ""
    printf "${YELLOW}[WARN]${NC}  ║  %-64s║\n" "After reboot, verify with:  uname -r"
    printf "${YELLOW}[WARN]${NC}  ║  %-64s║\n" "Expected: ${target_kernel}"
    warn "╚══════════════════════════════════════════════════════════════════╝"

    return 0
}

download_asset() {
    local name="$1"
    local dest="${WORK_DIR}/${name}"
    if [[ -f "$dest" ]]; then
        # Verify existing file checksum if we have one
        if [[ -n "${CHECKSUMS[$name]:-}" ]]; then
            local actual
            actual=$(sha256sum "$dest" | awk '{print $1}')
            if [[ "$actual" == "${CHECKSUMS[$name]}" ]]; then
                ok "Already downloaded and verified: ${name}"
                return 0
            else
                warn "Existing ${name} has wrong checksum — re-downloading."
            fi
        else
            ok "Already downloaded: ${name} (no checksum to verify)"
            return 0
        fi
    fi
    info "Downloading ${name} ..."
    wget -q --show-progress -O "$dest" "${BASE_URL}/${name}" || fail "Failed to download ${name}"
    if [[ -n "${CHECKSUMS[$name]:-}" ]]; then
        verify_checksum "$dest" "${CHECKSUMS[$name]}"
        ok "Downloaded and verified: ${name}"
    else
        ok "Downloaded: ${name}"
    fi
}

###############################################################################
# STEP 0: Pre-flight checks
###############################################################################
require_root
check_pve9

info "CPU vendor: $(detect_cpu_vendor | tr '[:lower:]' '[:upper:]')"
info "Kernel: $(uname -r)"
info "Working directory: ${WORK_DIR}"

mkdir -p "${WORK_DIR}" "${BACKUP_DIR}"

###############################################################################
# STEP 1: Set MAC Address Prefix at Datacenter level
###############################################################################
echo ""
info "═══ Step 1/12: MAC Address Prefix ═══"

if [[ -f "$DATACENTER_CFG" ]]; then
    if grep -q "^mac_prefix:" "$DATACENTER_CFG" 2>/dev/null; then
        current_mac=$(grep "^mac_prefix:" "$DATACENTER_CFG" | awk '{print $2}')
        if [[ "$current_mac" == "$MAC_PREFIX" ]]; then
            ok "MAC prefix already set to ${MAC_PREFIX}"
        else
            warn "Changing MAC prefix from ${current_mac} to ${MAC_PREFIX}"
            sed -i "s/^mac_prefix:.*/mac_prefix: ${MAC_PREFIX}/" "$DATACENTER_CFG"
            ok "MAC prefix updated to ${MAC_PREFIX}"
        fi
    else
        echo "mac_prefix: ${MAC_PREFIX}" >> "$DATACENTER_CFG"
        ok "MAC prefix set to ${MAC_PREFIX}"
    fi
else
    # File doesn't exist yet (fresh PVE install)
    echo "mac_prefix: ${MAC_PREFIX}" > "$DATACENTER_CFG"
    ok "Created ${DATACENTER_CFG} with MAC prefix ${MAC_PREFIX}"
fi

###############################################################################
# STEP 2: Download ALL release assets
###############################################################################
echo ""
info "═══ Step 2/12: Download PVE Release Assets ═══"

if [[ "$SKIP_DOWNLOAD" == true ]]; then
    warn "Skipping downloads (--skip-download). Expecting assets in ${WORK_DIR}"
else
    # Download base debs
    download_asset "$QEMU_BASE_DEB"
    download_asset "$OVMF_BASE_DEB"

    # Download Strong .tgz (contains Strong debs + KVM modules)
    download_asset "$STRONG_TGZ"

    # Download ACPI tables
    for aml in "${ACPI_FILES[@]}"; do
        download_asset "$aml"
    done

    # Download patch file (for reference / manual rebuilds)
    download_asset "$PATCH_FILE"
fi

###############################################################################
# STEP 3: Download Debian release assets (patched ROM/BIOS files only)
###############################################################################
echo ""
info "═══ Step 3/12: Download Debian Release Assets (Patched ROMs) ═══"
info "The Debian release provides patched BIOS, EFI, and VGA ROM files"
info "with all VM-identifying strings ('QEMU', 'Bochs', 'SeaBIOS') removed."
info "These are overlaid after PVE deb installation to close firmware-scan gaps."

DEBIAN_DIR="${WORK_DIR}/debian"
mkdir -p "$DEBIAN_DIR"

download_debian_asset() {
    local name="$1"
    local dest="${DEBIAN_DIR}/${name}"
    if [[ -f "$dest" ]]; then
        if [[ -n "${CHECKSUMS[$name]:-}" ]]; then
            local actual
            actual=$(sha256sum "$dest" | awk '{print $1}')
            if [[ "$actual" == "${CHECKSUMS[$name]}" ]]; then
                ok "Already downloaded and verified: ${name} (debian)"
                return 0
            else
                warn "Existing ${name} has wrong checksum — re-downloading."
            fi
        else
            ok "Already downloaded: ${name} (debian, no checksum)"
            return 0
        fi
    fi
    info "Downloading ${name} (debian release) ..."
    wget -q --show-progress -O "$dest" "${DEBIAN_URL}/${name}" || fail "Failed to download ${name} from Debian release"
    if [[ -n "${CHECKSUMS[$name]:-}" ]]; then
        verify_checksum "$dest" "${CHECKSUMS[$name]}"
        ok "Downloaded and verified: ${name} (debian)"
    else
        ok "Downloaded: ${name} (debian)"
    fi
}

if [[ "$SKIP_DOWNLOAD" == true ]]; then
    warn "Skipping Debian downloads (--skip-download). Expecting assets in ${DEBIAN_DIR}"
else
    # NOTE: We do NOT download the Debian qemu-system-x86_64 binary.
    # The PVE deb binary (installed in Step 5/6) is superior — it includes
    # PVE management integration and Strong build CPU sensor passthrough.
    # Both binaries share the same ACPI/SMBIOS/device sedPatch anti-detection
    # patches (the PVE patch is actually 836 bytes larger).

    # Download patched BIOS ROMs (SeaBIOS with VM strings scrubbed)
    for f in "${DEBIAN_BIOS_FILES[@]}"; do
        download_debian_asset "$f"
    done

    # Download patched EFI network boot ROMs
    for f in "${DEBIAN_EFI_ROMS[@]}"; do
        download_debian_asset "$f"
    done

    # Download patched VGA BIOS ROMs
    for f in "${DEBIAN_VGA_ROMS[@]}"; do
        download_debian_asset "$f"
    done

    # Download SeaBIOS patch (reference only — not applied, the ROMs are pre-compiled)
    # download_debian_asset "$SEABIOS_PATCH"

    # Download ACPI tables from Debian release too (may be newer)
    for aml in "${ACPI_FILES[@]}"; do
        download_debian_asset "$aml"
    done
fi

###############################################################################
# STEP 4: Backup stock packages
###############################################################################
echo ""
info "═══ Step 4/12: Backup Stock Packages ═══"

# Back up the current qemu-system-x86_64 binary
QEMU_BIN="/usr/bin/qemu-system-x86_64"
if [[ -f "$QEMU_BIN" && ! -f "${BACKUP_DIR}/qemu-system-x86_64.stock" ]]; then
    cp "$QEMU_BIN" "${BACKUP_DIR}/qemu-system-x86_64.stock"
    ok "Backed up stock qemu-system-x86_64 ($(stat -c%s "$QEMU_BIN") bytes)"
elif [[ -f "${BACKUP_DIR}/qemu-system-x86_64.stock" ]]; then
    ok "Stock QEMU binary backup already exists"
else
    warn "No existing qemu-system-x86_64 found to back up"
fi

# Back up OVMF firmware files
OVMF_DIR="/usr/share/pve-edk2-firmware"
if [[ -d "$OVMF_DIR" && ! -d "${BACKUP_DIR}/pve-edk2-firmware.stock" ]]; then
    cp -a "$OVMF_DIR" "${BACKUP_DIR}/pve-edk2-firmware.stock"
    ok "Backed up stock OVMF firmware directory"
elif [[ -d "${BACKUP_DIR}/pve-edk2-firmware.stock" ]]; then
    ok "Stock OVMF firmware backup already exists"
fi

# Back up current KVM module
KVM_MOD="/lib/modules/$(uname -r)/kernel/arch/x86/kvm/kvm.ko"
KVM_MOD_ZST="${KVM_MOD}.zst"
if [[ -f "$KVM_MOD" && ! -f "${BACKUP_DIR}/kvm.ko.stock" ]]; then
    cp "$KVM_MOD" "${BACKUP_DIR}/kvm.ko.stock"
    ok "Backed up stock kvm.ko"
elif [[ -f "$KVM_MOD_ZST" && ! -f "${BACKUP_DIR}/kvm.ko.zst.stock" ]]; then
    cp "$KVM_MOD_ZST" "${BACKUP_DIR}/kvm.ko.zst.stock"
    ok "Backed up stock kvm.ko.zst"
elif [[ -f "${BACKUP_DIR}/kvm.ko.stock" || -f "${BACKUP_DIR}/kvm.ko.zst.stock" ]]; then
    ok "Stock KVM module backup already exists"
fi

###############################################################################
# STEP 5: Install base anti-detection deb packages
###############################################################################
echo ""
info "═══ Step 5/12: Install Base Anti-Detection Packages ═══"

info "Installing ${QEMU_BASE_DEB} ..."
dpkg -i "${WORK_DIR}/${QEMU_BASE_DEB}" 2>&1 | tail -5
ok "Base QEMU anti-detection package installed"

info "Installing ${OVMF_BASE_DEB} ..."
dpkg -i "${WORK_DIR}/${OVMF_BASE_DEB}" 2>&1 | tail -5
ok "Base OVMF anti-detection package installed"

###############################################################################
# STEP 6: Extract & install Strong build
###############################################################################
echo ""
info "═══ Step 6/12: Extract & Install Strong Build ═══"

STRONG_DIR="${WORK_DIR}/strong"
mkdir -p "$STRONG_DIR"

info "Extracting ${STRONG_TGZ} ..."
tar -xzf "${WORK_DIR}/${STRONG_TGZ}" -C "$STRONG_DIR" --strip-components=0 \
    || fail "Failed to extract ${STRONG_TGZ} — archive may be corrupt. Re-run without --skip-download."

# Find the Strong debs inside the extracted tree
STRONG_QEMU_PATH=$(find "$STRONG_DIR" -name "*Strong.deb" -path "*qemu*" | head -1)
STRONG_OVMF_PATH=$(find "$STRONG_DIR" -name "*Strong.deb" -path "*edk2*" -o -name "*Strong.deb" -path "*ovmf*" | head -1)

if [[ -z "$STRONG_QEMU_PATH" ]]; then
    # Try broader search
    STRONG_QEMU_PATH=$(find "$STRONG_DIR" -name "pve-qemu-kvm*Strong*.deb" | head -1)
fi
if [[ -z "$STRONG_OVMF_PATH" ]]; then
    STRONG_OVMF_PATH=$(find "$STRONG_DIR" -name "pve-edk2*Strong*.deb" | head -1)
fi

if [[ -n "$STRONG_QEMU_PATH" ]]; then
    info "Installing Strong QEMU: $(basename "$STRONG_QEMU_PATH") ..."
    dpkg -i "$STRONG_QEMU_PATH" 2>&1 | tail -5
    ok "Strong QEMU package installed"
else
    warn "Strong QEMU .deb not found in .tgz — skipping (base install still active)"
fi

if [[ -n "$STRONG_OVMF_PATH" ]]; then
    info "Installing Strong OVMF: $(basename "$STRONG_OVMF_PATH") ..."
    dpkg -i "$STRONG_OVMF_PATH" 2>&1 | tail -5
    ok "Strong OVMF package installed"
else
    warn "Strong OVMF .deb not found in .tgz — skipping (base install still active)"
fi

###############################################################################
# STEP 7: Overlay Debian release patched ROM/BIOS/VGA files
###############################################################################
echo ""
info "═══ Step 7/12: Overlay Patched Debian ROM/BIOS Files ═══"
info "The PVE deb ships stock SeaBIOS/VGA/EFI ROMs that still contain VM-identifying"
info "strings ('QEMU', 'Bochs', 'SeaBIOS'). The Debian release provides separately"
info "compiled ROMs with these strings removed. Both builds use the same sedPatch"
info "anti-detection patches — the PVE QEMU binary is kept (it has PVE integration"
info "+ Strong CPU sensor passthrough), only the ROM files are overlaid."

# Determine where PVE stores QEMU ROM/BIOS files
# PVE uses /usr/share/kvm/ but also checks /usr/share/qemu/
QEMU_ROM_DIR="/usr/share/kvm"
QEMU_ROM_DIR_ALT="/usr/share/qemu"

# Ensure directories exist
mkdir -p "$QEMU_ROM_DIR" "$QEMU_ROM_DIR_ALT" 2>/dev/null || true

# NOTE: We intentionally do NOT replace the QEMU binary here.
# The PVE deb binary (from Step 5) or Strong build (from Step 6) is preferred
# over the Debian standalone binary because it includes:
#   - PVE management integration (qmp, migration, etc.)
#   - Strong build CPU sensor passthrough (temperature, MHz, voltage, power)
#   - A larger qemu-autoGenPatch (~836 bytes more patches than Debian)
# Both binaries share the same ACPI/SMBIOS anti-detection sedPatch, so there
# is NO ACPI overlap concern. The internal ACPI table generation (hw/acpi/,
# hw/i386/acpi-build.c) is compiled into the binary; the external .aml files
# from Step 9 supplement (not conflict with) the built-in tables.

# ── Overlay patched BIOS ROMs (SeaBIOS — removes QEMU/Bochs/SeaBIOS strings) ──
for bios_file in "${DEBIAN_BIOS_FILES[@]}"; do
    if [[ -f "${DEBIAN_DIR}/${bios_file}" ]]; then
        # Back up stock version if not already done
        for rom_dir in "$QEMU_ROM_DIR" "$QEMU_ROM_DIR_ALT"; do
            if [[ -f "${rom_dir}/${bios_file}" && ! -f "${BACKUP_DIR}/${bios_file}.stock" ]]; then
                cp "${rom_dir}/${bios_file}" "${BACKUP_DIR}/${bios_file}.stock"
            fi
            cp "${DEBIAN_DIR}/${bios_file}" "${rom_dir}/${bios_file}"
            chmod 644 "${rom_dir}/${bios_file}"
        done
        ok "Overlaid patched BIOS: ${bios_file}"
    else
        warn "Missing Debian asset: ${bios_file}"
    fi
done

# ── Overlay patched EFI network boot ROMs ──
for efi_rom in "${DEBIAN_EFI_ROMS[@]}"; do
    if [[ -f "${DEBIAN_DIR}/${efi_rom}" ]]; then
        for rom_dir in "$QEMU_ROM_DIR" "$QEMU_ROM_DIR_ALT"; do
            if [[ -f "${rom_dir}/${efi_rom}" && ! -f "${BACKUP_DIR}/${efi_rom}.stock" ]]; then
                cp "${rom_dir}/${efi_rom}" "${BACKUP_DIR}/${efi_rom}.stock"
            fi
            cp "${DEBIAN_DIR}/${efi_rom}" "${rom_dir}/${efi_rom}"
            chmod 644 "${rom_dir}/${efi_rom}"
        done
        ok "Overlaid patched EFI ROM: ${efi_rom}"
    else
        warn "Missing Debian asset: ${efi_rom}"
    fi
done

# ── Overlay patched VGA BIOS ROMs ──
for vga_rom in "${DEBIAN_VGA_ROMS[@]}"; do
    if [[ -f "${DEBIAN_DIR}/${vga_rom}" ]]; then
        for rom_dir in "$QEMU_ROM_DIR" "$QEMU_ROM_DIR_ALT"; do
            if [[ -f "${rom_dir}/${vga_rom}" && ! -f "${BACKUP_DIR}/${vga_rom}.stock" ]]; then
                cp "${rom_dir}/${vga_rom}" "${BACKUP_DIR}/${vga_rom}.stock"
            fi
            cp "${DEBIAN_DIR}/${vga_rom}" "${rom_dir}/${vga_rom}"
            chmod 644 "${rom_dir}/${vga_rom}"
        done
        ok "Overlaid patched VGA BIOS: ${vga_rom}"
    else
        warn "Missing Debian asset: ${vga_rom}"
    fi
done

ok "Debian release ROM/BIOS overlay complete (PVE/Strong QEMU binary preserved)"

###############################################################################
# STEP 8: Install patched KVM kernel module
###############################################################################
echo ""
info "═══ Step 8/12: Install Patched KVM Kernel Module ═══"

CPU_VENDOR=$(detect_cpu_vendor)
KERNEL_VER=$(uname -r)

# The .tgz contains kvm.ko files named like: kvm.ko.6.17.9-1-intel / kvm.ko.6.17.9-1-amd
# We need to find the one matching our kernel and CPU vendor
info "Looking for KVM module matching kernel ${KERNEL_VER} and CPU vendor ${CPU_VENDOR} ..."

# Search for matching module
KVM_MODULE_SRC=""

# First try: exact kernel version match with CPU vendor suffix
KVM_MODULE_SRC=$(find "$STRONG_DIR" -name "kvm.ko.*${CPU_VENDOR}" 2>/dev/null | head -1)

if [[ -z "$KVM_MODULE_SRC" ]]; then
    # Second try: any kvm.ko with the vendor name
    KVM_MODULE_SRC=$(find "$STRONG_DIR" -name "kvm.ko*${CPU_VENDOR}*" 2>/dev/null | head -1)
fi

if [[ -z "$KVM_MODULE_SRC" ]]; then
    # Third try: list all kvm.ko files and let user see what's available
    warn "No KVM module found for vendor '${CPU_VENDOR}'. Available modules:"
    find "$STRONG_DIR" -name "kvm.ko*" 2>/dev/null || true
    warn "Skipping KVM module installation. You may need to install it manually."
else
    info "Found: $(basename "$KVM_MODULE_SRC")"

    # Extract the kernel version the module was built for (from filename)
    # e.g., kvm.ko.6.17.9-1-intel → kernel version component is 6.17.9-1
    MODULE_KERNEL_VER=$(basename "$KVM_MODULE_SRC" | sed 's/^kvm\.ko\.\?//' | sed "s/-${CPU_VENDOR}$//")

    # Check kernel compatibility
    KERNEL_MISMATCH=false
    if [[ -n "$MODULE_KERNEL_VER" ]] && ! echo "$KERNEL_VER" | grep -q "$MODULE_KERNEL_VER"; then
        KERNEL_MISMATCH=true
    fi

    if [[ "$KERNEL_MISMATCH" == true ]]; then
        warn "KVM module was built for kernel containing '${MODULE_KERNEL_VER}'"
        warn "Running kernel is '${KERNEL_VER}'"

        if [[ "$SKIP_KERNEL_DOWNGRADE" == true ]]; then
            warn "Kernel downgrade skipped (--skip-kernel-downgrade)."
            warn "Proceeding with install into current kernel — module may not load."
            # Fall through to install into current kernel anyway
        else
            info "Attempting automatic kernel install/downgrade to match the patched module ..."
            if install_target_kernel "$MODULE_KERNEL_VER" "$CPU_VENDOR" "$KVM_MODULE_SRC"; then
                ok "Kernel downgrade and KVM module installation complete."
                # Update KERNEL_VER so verification checks the correct module tree
                KERNEL_VER="${MODULE_KERNEL_VER}-pve"
                # Skip the normal install path below — module is already in the target tree
                KVM_MODULE_SRC=""  # Signal to skip remaining install
            else
                warn "Automatic kernel install failed."
                warn "Proceeding with install into current kernel — module may not load."
            fi
        fi
    fi

    # Install into the CURRENT running kernel (normal path, or fallback if downgrade failed)
    if [[ -n "$KVM_MODULE_SRC" ]]; then
        KVM_DEST="/lib/modules/${KERNEL_VER}/kernel/arch/x86/kvm/kvm.ko"

        # Remove compressed version if present
        if [[ -f "${KVM_DEST}.zst" ]]; then
            info "Removing compressed stock kvm.ko.zst ..."
            rm -f "${KVM_DEST}.zst"
        fi

        info "Copying patched kvm.ko to ${KVM_DEST} ..."
        cp "$KVM_MODULE_SRC" "$KVM_DEST"
        chmod 644 "$KVM_DEST"

        info "Rebuilding module dependencies ..."
        depmod -a

        # Attempt to reload the module (may fail if VMs are running)
        if lsmod | grep -q "^kvm "; then
            warn "KVM module is currently loaded (VMs may be running)."
            warn "The patched module will take effect after next reboot or after"
            warn "stopping all VMs and running: rmmod kvm_intel kvm && modprobe kvm"
        else
            info "Loading patched KVM module ..."
            modprobe kvm && ok "Patched KVM module loaded" || warn "Failed to load — will work after reboot"
        fi

        ok "Patched KVM module installed for ${CPU_VENDOR}"
    fi
fi

###############################################################################
# STEP 9: Place ACPI table files
###############################################################################
echo ""
info "═══ Step 9/12: Place ACPI Table Files ═══"

for aml in "${ACPI_FILES[@]}"; do
    # Prefer Debian release ACPI files (may be newer), fall back to PVE release
    if [[ -f "${DEBIAN_DIR}/${aml}" ]]; then
        src="${DEBIAN_DIR}/${aml}"
    else
        src="${WORK_DIR}/${aml}"
    fi
    dest="${ACPI_DIR}/${aml}"
    if [[ -f "$src" ]]; then
        cp "$src" "$dest"
        chmod 644 "$dest"
        ok "Placed ${aml} → ${dest} ($(stat -c%s "$dest") bytes)"
    else
        warn "ACPI file ${aml} not found in ${WORK_DIR} or ${DEBIAN_DIR} — skipping"
    fi
done

###############################################################################
# STEP 10: Intel Ultra iGPU Passthrough Setup (optional)
###############################################################################
echo ""
if [[ "$ENABLE_IGPU" == true ]]; then
    info "═══ Step 10/12: Intel Ultra iGPU Passthrough Setup ═══"

    # Download the iGPU ROM
    if [[ "$SKIP_DOWNLOAD" != true ]]; then
        mkdir -p "$IGPU_ROM_DIR"
        ROM_DEST="${IGPU_ROM_DIR}/${IGPU_ROM_FILE}"
        NEED_DL=true

        if [[ -f "$ROM_DEST" ]] && [[ -n "${CHECKSUMS[$IGPU_ROM_FILE]:-}" ]]; then
            ROM_ACTUAL=$(sha256sum "$ROM_DEST" | awk '{print $1}')
            if [[ "$ROM_ACTUAL" == "${CHECKSUMS[$IGPU_ROM_FILE]}" ]]; then
                ok "iGPU ROM already installed and verified: ${ROM_DEST}"
                NEED_DL=false
            else
                warn "Existing ROM has wrong checksum — re-downloading."
            fi
        fi

        if [[ "$NEED_DL" == true ]]; then
            info "Downloading Intel Ultra iGPU ROM: ${IGPU_ROM_FILE} ..."
            wget -q --show-progress -O "$ROM_DEST" "${IGPU_ROM_URL}/${IGPU_ROM_FILE}" \
                || fail "Failed to download iGPU ROM"
            verify_checksum "$ROM_DEST" "${CHECKSUMS[$IGPU_ROM_FILE]}"
            ok "iGPU ROM installed: ${ROM_DEST} ($(stat -c%s "$ROM_DEST") bytes)"
        fi
    else
        if [[ -f "${IGPU_ROM_DIR}/${IGPU_ROM_FILE}" ]]; then
            ok "iGPU ROM present: ${IGPU_ROM_DIR}/${IGPU_ROM_FILE}"
        else
            warn "iGPU ROM not found and --skip-download is set"
        fi
    fi

    # Configure Intel IOMMU in GRUB
    GRUB_FILE="/etc/default/grub"
    if [[ -f "$GRUB_FILE" ]]; then
        if ! grep -q "intel_iommu=on" "$GRUB_FILE"; then
            info "Enabling Intel IOMMU in GRUB ..."
            cp "$GRUB_FILE" "${BACKUP_DIR}/grub.default.igpu.bak" 2>/dev/null || true
            sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\([^"]*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 intel_iommu=on"/' "$GRUB_FILE"
            if command -v update-grub &>/dev/null; then
                update-grub 2>&1 | tail -3
            fi
            NEEDS_REBOOT=true
            ok "Intel IOMMU enabled (reboot required)"
        else
            ok "Intel IOMMU already enabled in GRUB"
        fi
    fi

    # Blacklist i915 and snd_hda_intel for VFIO passthrough
    IGPU_BLACKLIST_FILE="/etc/modprobe.d/pve-realpc-igpu.conf"
    if [[ ! -f "$IGPU_BLACKLIST_FILE" ]]; then
        cat > "$IGPU_BLACKLIST_FILE" <<'IGPUEOF'
# Blacklist Intel GPU and audio drivers to allow VFIO passthrough
# Created by pve-realpc-setup.sh --igpu
blacklist i915
blacklist snd_hda_intel
options vfio_iommu_type1 allow_unsafe_interrupts=1
IGPUEOF
        ok "Created ${IGPU_BLACKLIST_FILE} (blacklist i915 + snd_hda_intel)"

        # Rebuild initramfs so VFIO claims the devices at boot
        info "Rebuilding initramfs for VFIO changes ..."
        update-initramfs -u -k all 2>&1 | tail -3
        ok "Initramfs updated"
        NEEDS_REBOOT=true
    else
        ok "iGPU blacklist already configured: ${IGPU_BLACKLIST_FILE}"
    fi
else
    info "═══ Step 10/12: Intel Ultra iGPU Passthrough Setup ═══"
    info "Skipped (use --igpu to enable Intel Ultra iGPU passthrough)"
fi

###############################################################################
# STEP 11: Pin packages (prevent apt upgrade from overwriting)
###############################################################################
echo ""
info "═══ Step 11/12: APT Package Pinning ═══"

PIN_FILE="/etc/apt/preferences.d/pve-realpc-hold"
if [[ "$SKIP_PIN" == true ]]; then
    warn "Skipping APT pinning (--skip-pin)"
else
    cat > "$PIN_FILE" <<'PINEOF'
# Prevent apt from overwriting anti-detection QEMU and OVMF packages
# Remove this file or run: apt-mark unhold pve-qemu-kvm pve-edk2-firmware-ovmf
# to allow normal upgrades again.

Package: pve-qemu-kvm
Pin: version *
Pin-Priority: -1

Package: pve-edk2-firmware-ovmf
Pin: version *
Pin-Priority: -1
PINEOF

    # Also use dpkg hold
    apt-mark hold pve-qemu-kvm pve-edk2-firmware-ovmf 2>/dev/null || true
    ok "Packages pinned — apt will not overwrite patched QEMU/OVMF"
    info "To unpin: rm ${PIN_FILE} && apt-mark unhold pve-qemu-kvm pve-edk2-firmware-ovmf"
fi

###############################################################################
# Verification
###############################################################################
echo ""
info "═══ Step 12/12: Verification ═══"

# Check QEMU binary size (PVE/Strong build should be ~29MB+)
QEMU_BIN="/usr/bin/qemu-system-x86_64"
QEMU_SIZE=$(stat -c%s "$QEMU_BIN" 2>/dev/null || echo "0")
info "qemu-system-x86_64 size: ${QEMU_SIZE} bytes"
if (( QEMU_SIZE >= 29000000 )); then
    ok "QEMU binary size looks correct for PVE/Strong patched build"
else
    warn "QEMU binary seems small — PVE/Strong build may not have installed correctly"
fi

# Check OVMF exists
if [[ -f "/usr/share/pve-edk2-firmware/OVMF_CODE_4M.secboot.fd" ]] || \
   [[ -f "/usr/share/pve-edk2-firmware/OVMF_CODE_4M.fd" ]]; then
    ok "OVMF firmware files present"
else
    warn "OVMF firmware files not found at expected location"
fi

# Check patched ROM/BIOS files (from Debian release overlay)
info "Checking patched ROM/BIOS files ..."
ROM_OK=0
ROM_MISSING=0
for rom_file in "${DEBIAN_ALL_ROMS[@]}"; do
    found=false
    for rom_dir in "$QEMU_ROM_DIR" "$QEMU_ROM_DIR_ALT"; do
        if [[ -f "${rom_dir}/${rom_file}" ]]; then
            found=true
            break
        fi
    done
    if [[ "$found" == true ]]; then
        ok "ROM: ${rom_file} present"
        (( ROM_OK++ ))
    else
        warn "ROM: ${rom_file} MISSING — firmware string scan may still detect VM"
        (( ROM_MISSING++ ))
    fi
done
if (( ROM_MISSING == 0 )); then
    ok "All ${ROM_OK} patched ROM/BIOS files installed"
else
    warn "${ROM_MISSING} of $((ROM_OK + ROM_MISSING)) ROM files missing"
fi

# Spot-check: verify a patched BIOS doesn't contain "QEMU" or "Bochs" strings
for check_rom in "bios-256k.bin" "vgabios-stdvga.bin"; do
    for rom_dir in "$QEMU_ROM_DIR" "$QEMU_ROM_DIR_ALT"; do
        if [[ -f "${rom_dir}/${check_rom}" ]]; then
            if strings "${rom_dir}/${check_rom}" 2>/dev/null | grep -qi "QEMU\|Bochs\|SeaBIOS"; then
                warn "UNPATCHED: ${rom_dir}/${check_rom} still contains VM strings!"
            else
                ok "Verified: ${check_rom} is clean (no VM strings)"
            fi
            break
        fi
    done
done

# Check ACPI files
for aml in "${ACPI_FILES[@]}"; do
    if [[ -f "${ACPI_DIR}/${aml}" ]]; then
        ok "ACPI: ${aml} present ($(stat -c%s "${ACPI_DIR}/${aml}") bytes)"
    else
        warn "ACPI: ${aml} missing"
    fi
done

# Check KVM module (KERNEL_VER is updated to the target kernel after downgrade)
if [[ -f "/lib/modules/${KERNEL_VER}/kernel/arch/x86/kvm/kvm.ko" ]]; then
    KVM_SIZE=$(stat -c%s "/lib/modules/${KERNEL_VER}/kernel/arch/x86/kvm/kvm.ko")
    ok "Patched kvm.ko present for kernel ${KERNEL_VER} (${KVM_SIZE} bytes)"
else
    warn "Patched kvm.ko NOT found in /lib/modules/${KERNEL_VER}/kernel/arch/x86/kvm/"
fi

# Check MAC prefix
if grep -q "mac_prefix: ${MAC_PREFIX}" "$DATACENTER_CFG" 2>/dev/null; then
    ok "Datacenter MAC prefix: ${MAC_PREFIX}"
fi

# Check iGPU ROM
if [[ "$ENABLE_IGPU" == true ]]; then
    if [[ -f "${IGPU_ROM_DIR}/${IGPU_ROM_FILE}" ]]; then
        ok "iGPU ROM: ${IGPU_ROM_FILE} present ($(stat -c%s "${IGPU_ROM_DIR}/${IGPU_ROM_FILE}") bytes)"
    else
        warn "iGPU ROM: ${IGPU_ROM_FILE} missing from ${IGPU_ROM_DIR}/"
    fi
    if [[ -f "/etc/modprobe.d/pve-realpc-igpu.conf" ]]; then
        ok "iGPU blacklist (i915 + snd_hda_intel) configured"
    fi
fi

# Summary — use printf for consistent column alignment
echo ""
_bx()  { printf "${1}║  %-61s║${NC}\n" "$2"; }
_bxe() { printf "${GREEN}║%-63s║${NC}\n" ""; }
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
printf "${GREEN}║   %-60s║${NC}\n" "PVE Anti-VM-Detection Setup Complete!"
echo -e "${GREEN}╠═══════════════════════════════════════════════════════════════╣${NC}"
_bxe
_bx "$GREEN" "Strong QEMU + OVMF installed (PVE debs, anti-detection)"
_bx "$GREEN" "Patched ROM/BIOS/VGA overlaid (Debian ${DEBIAN_TAG})"
_bx "$GREEN" "PVE binary preserved (PVE integration + sensor passthrough)"
_bx "$GREEN" "Patched KVM module installed (${CPU_VENDOR})"
_bx "$GREEN" "ACPI tables placed in /root/"
_bx "$GREEN" "MAC prefix set to ${MAC_PREFIX}"
_bx "$GREEN" "Packages pinned against apt upgrades"
if [[ "$ENABLE_IGPU" == true ]]; then
_bx "$GREEN" "Intel Ultra iGPU ROM installed (/usr/share/kvm/)"
_bx "$GREEN" "IOMMU enabled + i915/snd_hda_intel blacklisted"
fi
_bxe
if [[ "$NEEDS_REBOOT" == true ]]; then
_bx "$YELLOW" "⚠  REBOOT REQUIRED — kernel was changed to match module"
_bx "$YELLOW" "   Run 'reboot' now, then deploy VMs after reboot"
else
_bx "$GREEN" "Next: Run pve-realpc-deploy-vm.sh to create a VM"
fi
_bxe
_bx "$GREEN" "Backups saved to: ${BACKUP_DIR}"
_bx "$GREEN" "To restore stock: apt-mark unhold pve-qemu-kvm"
_bx "$GREEN" "                  apt reinstall pve-qemu-kvm"
_bx "$GREEN" "                  apt reinstall pve-edk2-firmware-ovmf"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
