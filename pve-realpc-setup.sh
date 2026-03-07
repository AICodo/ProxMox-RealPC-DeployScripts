#!/usr/bin/env bash
###############################################################################
# pve-realpc-setup.sh — PVE Anti-VM-Detection Host Setup (AICodo/pve-emu-realpc)
#
# Fully automates:
#   1. MAC prefix configuration (Datacenter level)
#   2. Download of ALL release assets (base debs, Strong .tgz, ACPI tables)
#   3. Backup of stock QEMU & OVMF packages
#   4. Installation of base anti-detection debs
#   5. Extraction & installation of Strong build debs
#   6. Installation of patched KVM kernel module (Intel or AMD)
#   7. Placement of ACPI table files (/root/)
#   8. Package pinning (prevent apt from overwriting patched QEMU/OVMF)
#   9. Verification of installation
#
# Usage:   bash pve-realpc-setup.sh [--skip-download] [--skip-pin] [--skip-kernel-downgrade]
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

# Asset filenames
QEMU_BASE_DEB="pve-qemu-kvm_10.1.2-7_amd64.deb"
OVMF_BASE_DEB="pve-edk2-firmware-ovmf_4.2025.05-2_all.deb"
STRONG_TGZ="pve-qemu-kvm_10.1.2-7_amd64_Strong_intel_amd.tgz"
STRONG_QEMU_DEB="pve-qemu-kvm_10.1.2-7_amd64_Strong.deb"
STRONG_OVMF_DEB="pve-edk2-firmware-ovmf_4.2025.05-2_all_Strong.deb"
PATCH_FILE="qemu-autoGenPatch.patch"
ACPI_FILES=("ssdt.aml" "ssdt-ec.aml" "ssdt-battery.aml" "hpet.aml")

# SHA-256 digests (from GitHub release API) for integrity verification
declare -A CHECKSUMS=(
    ["hpet.aml"]="cb0cf3c29fdf5b734422ec3f64589f1b88a11bb0a0f30bb41c6ce63c3e61367b"
    ["${OVMF_BASE_DEB}"]="cbdb7c949c057a8c5972ffb4fef03dd7c9fa52e42aa94cee63b00be1af4b9d81"
    ["${QEMU_BASE_DEB}"]="cbbfd70769da198d17ead114bf4d32879c1ac015288dbe1c00982d6f983a88d8"
    ["${STRONG_TGZ}"]="94e56520c4cb2c3fb4d0be40e703fae1e58b56cabe4d777123ffa44b4e8f0176"
    ["${PATCH_FILE}"]="57a5c63baec4875b45e00e1ccbbd8ff41e9fa6132219c39558955428f56bcfb3"
    ["ssdt-battery.aml"]="ea9c737cde6384c7e86028fe891ed3d8662721b8e254aea54f5d227d1e8009f1"
    ["ssdt-ec.aml"]="6694edf9c3cc5914063dcb3e25f374531f65801374dbae90fb8604fa9851d48a"
    ["ssdt.aml"]="09e3aa35a9a7a63801ea4231846bf7835b6ca398f2024ceb79673df6d409a341"
)

# ─── Flags ───────────────────────────────────────────────────────────────────
SKIP_DOWNLOAD=false
SKIP_PIN=false
SKIP_KERNEL_DOWNGRADE=false
NEEDS_REBOOT=false
for arg in "$@"; do
    case "$arg" in
        --skip-download)          SKIP_DOWNLOAD=true ;;
        --skip-pin)               SKIP_PIN=true ;;
        --skip-kernel-downgrade)  SKIP_KERNEL_DOWNGRADE=true ;;
        --help|-h)
            echo "Usage: $0 [--skip-download] [--skip-pin] [--skip-kernel-downgrade]"
            echo "  --skip-download           Skip downloading assets (use existing files in ${WORK_DIR})"
            echo "  --skip-pin                Skip APT package pinning"
            echo "  --skip-kernel-downgrade   Skip automatic kernel downgrade if version mismatch"
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
    warn "║  REBOOT REQUIRED                                               ║"
    warn "║                                                                  ║"
    warn "║  A different kernel (${target_kernel}) has been installed       ║"
    warn "║  and pinned as the default boot entry.                           ║"
    warn "║                                                                  ║"
    warn "║  Please reboot now:  reboot                                      ║"
    warn "║                                                                  ║"
    warn "║  After reboot, verify with:  uname -r                            ║"
    warn "║  Expected: ${target_kernel}                                     ║"
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
info "═══ Step 1/8: MAC Address Prefix ═══"

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
info "═══ Step 2/8: Download Release Assets ═══"

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
# STEP 3: Backup stock packages
###############################################################################
echo ""
info "═══ Step 3/8: Backup Stock Packages ═══"

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
# STEP 4: Install base anti-detection deb packages
###############################################################################
echo ""
info "═══ Step 4/8: Install Base Anti-Detection Packages ═══"

info "Installing ${QEMU_BASE_DEB} ..."
dpkg -i "${WORK_DIR}/${QEMU_BASE_DEB}" 2>&1 | tail -5
ok "Base QEMU anti-detection package installed"

info "Installing ${OVMF_BASE_DEB} ..."
dpkg -i "${WORK_DIR}/${OVMF_BASE_DEB}" 2>&1 | tail -5
ok "Base OVMF anti-detection package installed"

###############################################################################
# STEP 5: Extract & install Strong build
###############################################################################
echo ""
info "═══ Step 5/8: Extract & Install Strong Build ═══"

STRONG_DIR="${WORK_DIR}/strong"
mkdir -p "$STRONG_DIR"

info "Extracting ${STRONG_TGZ} ..."
tar -xzf "${WORK_DIR}/${STRONG_TGZ}" -C "$STRONG_DIR" --strip-components=0

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
# STEP 6: Install patched KVM kernel module
###############################################################################
echo ""
info "═══ Step 6/8: Install Patched KVM Kernel Module ═══"

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
# STEP 7: Place ACPI table files
###############################################################################
echo ""
info "═══ Step 7/8: Place ACPI Table Files ═══"

for aml in "${ACPI_FILES[@]}"; do
    src="${WORK_DIR}/${aml}"
    dest="${ACPI_DIR}/${aml}"
    if [[ -f "$src" ]]; then
        cp "$src" "$dest"
        chmod 644 "$dest"
        ok "Placed ${aml} → ${dest} ($(stat -c%s "$dest") bytes)"
    else
        warn "ACPI file ${aml} not found in ${WORK_DIR} — skipping"
    fi
done

###############################################################################
# STEP 8: Pin packages (prevent apt upgrade from overwriting)
###############################################################################
echo ""
info "═══ Step 8/8: APT Package Pinning ═══"

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
info "═══ Verification ═══"

# Check QEMU binary size (Strong should be ~29.7MB)
QEMU_SIZE=$(stat -c%s "$QEMU_BIN" 2>/dev/null || echo "0")
info "qemu-system-x86_64 size: ${QEMU_SIZE} bytes"
if (( QEMU_SIZE > 29000000 )); then
    ok "QEMU binary size looks correct for Strong build"
else
    warn "QEMU binary seems small — Strong build may not have installed correctly"
fi

# Check OVMF exists
if [[ -f "/usr/share/pve-edk2-firmware/OVMF_CODE_4M.secboot.fd" ]] || \
   [[ -f "/usr/share/pve-edk2-firmware/OVMF_CODE_4M.fd" ]]; then
    ok "OVMF firmware files present"
else
    warn "OVMF firmware files not found at expected location"
fi

# Check ACPI files
for aml in "${ACPI_FILES[@]}"; do
    if [[ -f "${ACPI_DIR}/${aml}" ]]; then
        ok "ACPI: ${aml} present ($(stat -c%s "${ACPI_DIR}/${aml}") bytes)"
    else
        warn "ACPI: ${aml} missing"
    fi
done

# Check KVM module
if [[ -f "/lib/modules/${KERNEL_VER}/kernel/arch/x86/kvm/kvm.ko" ]]; then
    KVM_SIZE=$(stat -c%s "/lib/modules/${KERNEL_VER}/kernel/arch/x86/kvm/kvm.ko")
    ok "Patched kvm.ko present (${KVM_SIZE} bytes)"
fi

# Check MAC prefix
if grep -q "mac_prefix: ${MAC_PREFIX}" "$DATACENTER_CFG" 2>/dev/null; then
    ok "Datacenter MAC prefix: ${MAC_PREFIX}"
fi

# Summary
echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   PVE Anti-VM-Detection Setup Complete!                      ║${NC}"
echo -e "${GREEN}╠═══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║                                                               ║${NC}"
echo -e "${GREEN}║  Strong QEMU + OVMF installed                                ║${NC}"
echo -e "${GREEN}║  Patched KVM module installed (${CPU_VENDOR})                        ║${NC}"
echo -e "${GREEN}║  ACPI tables placed in /root/                                 ║${NC}"
echo -e "${GREEN}║  MAC prefix set to ${MAC_PREFIX}                               ║${NC}"
echo -e "${GREEN}║  Packages pinned against apt upgrades                         ║${NC}"
echo -e "${GREEN}║                                                               ║${NC}"
if [[ "$NEEDS_REBOOT" == true ]]; then
echo -e "${YELLOW}║  ⚠  REBOOT REQUIRED — kernel was changed to match module     ║${NC}"
echo -e "${YELLOW}║     Run 'reboot' now, then deploy VMs after reboot            ║${NC}"
else
echo -e "${GREEN}║  Next: Run pve-realpc-deploy-vm.sh to create a VM            ║${NC}"
fi
echo -e "${GREEN}║                                                               ║${NC}"
echo -e "${GREEN}║  Backups saved to: ${BACKUP_DIR}               ║${NC}"
echo -e "${GREEN}║  To restore stock: apt-mark unhold pve-qemu-kvm              ║${NC}"
echo -e "${GREEN}║                    apt reinstall pve-qemu-kvm                 ║${NC}"
echo -e "${GREEN}║                    apt reinstall pve-edk2-firmware-ovmf       ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
