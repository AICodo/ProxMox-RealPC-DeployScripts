#!/usr/bin/env bash
###############################################################################
# pve-realpc-deploy-vm.sh — Deploy a Perfect Anti-Detection Windows VM
#
# Creates a fully configured Proxmox VM with all anti-detection measures:
#   - OVMF + Q35 machine type
#   - SATA disk with custom serial (no virtio/scsi)
#   - e1000 NIC with realistic MAC prefix
#   - Full SMBIOS spoofing (types 0,1,2,3,4,8,9,17)
#   - Custom ACPI tables (ssdt.aml, ssdt-ec.aml, hpet.aml)
#   - CPU: host with hypervisor=off, kvm=off, TSC pinning, invtsc
#   - CPU power management passthrough (-overcommit cpu-pm=on)
#   - RTC drift fix, CPU affinity, balloon disabled
#   - Optional: ssdt-battery.aml for laptop CPUs / NVIDIA error 43 fix
#
# Usage:
#   bash pve-realpc-deploy-vm.sh                    # Interactive / defaults
#   bash pve-realpc-deploy-vm.sh --vmid 200 --name win10-stealth --cores 8
#   bash pve-realpc-deploy-vm.sh --help
#
# Prerequisites: Run pve-realpc-setup.sh first!
###############################################################################
set -euo pipefail
IFS=$'\n\t'

# ─── Defaults (override with flags) ─────────────────────────────────────────
VMID=""                          # Auto-detect next available if empty
VM_NAME="win10"
CORES=8                          # Physical cores to assign (1 socket × N cores × 1 thread)
MEMORY=16384                     # Only 4096, 8192, or 16384 look realistic
DISK_SIZE="256G"                 # ≥128G to appear realistic
DISK_STORAGE="local-lvm"        # Where to create the VM disk
ISO_STORAGE="local"             # Where ISO files are stored
ISO_FILE=""                      # Auto-detect if empty
BRIDGE="vmbr0"                   # Network bridge
CPU_TYPE="desktop"               # "desktop" = ssdt.aml (no battery), "laptop" = ssdt-battery.aml
VGA="std"                        # "std" initially, "none" for GPU passthrough
AFFINITY=""                      # e.g., "0-7" — auto-calculated if empty
TSC_FREQ=""                      # Auto-detect from /proc/cpuinfo if empty
SMBIOS_BOARD_MFG="Maxsun"
SMBIOS_BOARD_PRODUCT="MS-Terminator B760M"
SMBIOS_BOARD_VERSION="VER:H3.7G(2022/11/29)"
SMBIOS_BIOS_VENDOR="American Megatrends International LLC."
SMBIOS_BIOS_VERSION="H3.7G"
SMBIOS_BIOS_DATE="02/21/2023"
SMBIOS_BIOS_RELEASE="3.7"
SMBIOS_CPU_MFG="Intel(R) Corporation"
SMBIOS_CPU_VERSION=""            # Auto-detect if empty
DISK_SERIAL=""                   # Random 20-char if empty
MEM_SERIAL=""                    # Random 8-char hex if empty
MEM_ASSET="9876543210"
FIREWALL=1
OSTYPE="l26"                     # l26 hides "win" from PCI config; use win10 if you prefer

# ─── Parse Arguments ────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --vmid)         VMID="$2";              shift 2 ;;
        --name)         VM_NAME="$2";           shift 2 ;;
        --cores)        CORES="$2";             shift 2 ;;
        --memory)       MEMORY="$2";            shift 2 ;;
        --disk-size)    DISK_SIZE="$2";         shift 2 ;;
        --disk-storage) DISK_STORAGE="$2";      shift 2 ;;
        --iso-storage)  ISO_STORAGE="$2";       shift 2 ;;
        --iso)          ISO_FILE="$2";          shift 2 ;;
        --bridge)       BRIDGE="$2";            shift 2 ;;
        --type)         CPU_TYPE="$2";          shift 2 ;;  # desktop | laptop
        --vga)          VGA="$2";               shift 2 ;;
        --affinity)     AFFINITY="$2";          shift 2 ;;
        --tsc-freq)     TSC_FREQ="$2";          shift 2 ;;
        --ostype)       OSTYPE="$2";            shift 2 ;;
        --board-mfg)    SMBIOS_BOARD_MFG="$2";     shift 2 ;;
        --board-product) SMBIOS_BOARD_PRODUCT="$2"; shift 2 ;;
        --disk-serial)  DISK_SERIAL="$2";       shift 2 ;;
        --firewall)     FIREWALL="$2";          shift 2 ;;
        --help|-h)
            cat <<'HELPEOF'
Usage: pve-realpc-deploy-vm.sh [OPTIONS]

VM Configuration:
  --vmid NUM           VM ID (default: next available)
  --name NAME          VM name (default: win10)
  --cores NUM          CPU cores (default: 8)
  --memory MB          Memory in MB: 4096|8192|16384 (default: 16384)
  --disk-size SIZE     Disk size, e.g. 256G (default: 256G)
  --disk-storage NAME  Storage pool for disks (default: local-lvm)
  --iso-storage NAME   Storage pool for ISOs (default: local)
  --iso FILENAME       ISO filename (default: auto-detect Windows ISO)
  --bridge NAME        Network bridge (default: vmbr0)
  --vga TYPE           VGA type: std|none|virtio (default: std)
  --ostype TYPE        OS type: l26|win10|win11 (default: l26)
  --affinity RANGE     CPU affinity, e.g. 0-7 (default: auto)
  --tsc-freq HZ        TSC frequency in Hz (default: auto-detect)
  --firewall 0|1       Enable firewall (default: 1)

Identity Spoofing:
  --type desktop|laptop  Desktop (no battery) or laptop (virtual battery)
  --board-mfg NAME       Motherboard manufacturer (default: Maxsun)
  --board-product NAME   Motherboard product (default: MS-Terminator B760M)
  --disk-serial SERIAL   20-char disk serial (default: random)

Examples:
  ./pve-realpc-deploy-vm.sh
  ./pve-realpc-deploy-vm.sh --vmid 200 --cores 8 --memory 16384
  ./pve-realpc-deploy-vm.sh --type laptop --vga none
HELPEOF
            exit 0
            ;;
        *) echo "Unknown argument: $1. Use --help for usage."; exit 1 ;;
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

random_hex() {
    local len=$1
    od -An -tx1 -N64 /dev/urandom | tr -d ' \n' | head -c "$len" | tr '[:lower:]' '[:upper:]'
}

random_serial_20() {
    # Generate a realistic 20-char alphanumeric serial
    od -An -tx1 -N64 /dev/urandom | tr -d ' \n' | head -c 20 | tr '[:lower:]' '[:upper:]'
}

###############################################################################
# Pre-flight
###############################################################################
require_root

# Validate memory is realistic
case "$MEMORY" in
    4096|8192|16384) ;;
    *) warn "Memory ${MEMORY}MB is non-standard. Realistic values: 4096, 8192, 16384. Proceeding anyway." ;;
esac

# Validate ACPI files exist
for aml in ssdt.aml ssdt-ec.aml hpet.aml; do
    [[ -f "/root/${aml}" ]] || fail "Missing /root/${aml} — run pve-realpc-setup.sh first!"
done
if [[ "$CPU_TYPE" == "laptop" ]]; then
    [[ -f "/root/ssdt-battery.aml" ]] || fail "Missing /root/ssdt-battery.aml for laptop mode — run pve-realpc-setup.sh first!"
fi

# Validate patched QEMU is installed
QEMU_SIZE=$(stat -c%s /usr/bin/qemu-system-x86_64 2>/dev/null || echo "0")
if (( QEMU_SIZE < 29000000 )); then
    warn "qemu-system-x86_64 seems to be stock (${QEMU_SIZE} bytes). Run pve-realpc-setup.sh first!"
fi

###############################################################################
# Auto-detect values
###############################################################################

# Auto-detect next available VMID
if [[ -z "$VMID" ]]; then
    VMID=$(pvesh get /cluster/nextid 2>/dev/null || echo "100")
    info "Auto-selected VMID: ${VMID}"
fi

# Validate VMID is not already in use
if qm status "$VMID" &>/dev/null; then
    fail "VM ${VMID} already exists. Use --vmid to specify a different ID."
fi

# Auto-detect Windows ISO
if [[ -z "$ISO_FILE" ]]; then
    ISO_PATH="/var/lib/vz/template/iso"
    if [[ "$ISO_STORAGE" != "local" ]]; then
        # Try to resolve the storage path
        ISO_PATH=$(pvesm path "${ISO_STORAGE}:iso/" 2>/dev/null | sed 's|/iso/$||' || echo "/var/lib/vz/template/iso")
        # Fallback
        [[ -d "$ISO_PATH" ]] || ISO_PATH="/var/lib/vz/template/iso"
    fi

    # Search for Windows ISOs
    if [[ -d "$ISO_PATH" ]]; then
        ISO_FILE=$(find "$ISO_PATH" -maxdepth 1 -name "*.iso" -iname "*windows*" -printf '%f\n' 2>/dev/null | head -1)
        if [[ -z "$ISO_FILE" ]]; then
            # Broader search — any ISO
            ISO_FILE=$(find "$ISO_PATH" -maxdepth 1 -name "*.iso" -printf '%f\n' 2>/dev/null | head -1)
        fi
    fi

    if [[ -z "$ISO_FILE" ]]; then
        warn "No ISO found in ${ISO_PATH}. VM will be created without a CD-ROM ISO."
        warn "You can attach one later via: qm set ${VMID} -ide2 ${ISO_STORAGE}:iso/YOUR_ISO.iso,media=cdrom"
    else
        info "Auto-detected ISO: ${ISO_FILE}"
    fi
fi

# Auto-detect TSC frequency — must be BASE clock, NOT turbo/boost.
# TSC ticks at the invariant base frequency on modern Intel CPUs.
if [[ -z "$TSC_FREQ" ]]; then
    # Best source: kernel's own TSC detection from dmesg
    TSC_MHZ=$(dmesg 2>/dev/null | grep -oP 'tsc: Detected \K[0-9.]+' | head -1)
    if [[ -n "$TSC_MHZ" ]]; then
        TSC_FREQ=$(awk "BEGIN {printf \"%.0f\", ${TSC_MHZ} * 1000000}")
        info "TSC frequency from kernel: ${TSC_FREQ} Hz (${TSC_MHZ} MHz)"
    else
        # Fallback: lscpu "CPU base MHz" or "Model name @ X.XGHz"
        BASE_MHZ=$(lscpu 2>/dev/null | grep -i "CPU min MHz" | awk '{print $NF}' | cut -d. -f1)
        # CPU min MHz is often the idle freq, not base — try model name instead
        if [[ -z "$BASE_MHZ" ]] || [[ "$BASE_MHZ" == "0" ]]; then
            BASE_MHZ=$(grep -m1 "model name" /proc/cpuinfo | grep -oP '@ \K[0-9.]+' | awk '{printf "%.0f", $1*1000}')
        fi
        # Last resort: "CPU MHz" (current frequency, close enough on idle)
        if [[ -z "$BASE_MHZ" ]] || [[ "$BASE_MHZ" == "0" ]]; then
            BASE_MHZ=$(lscpu 2>/dev/null | grep -i "^CPU MHz" | head -1 | awk '{print $NF}' | cut -d. -f1)
        fi
        if [[ -n "$BASE_MHZ" ]] && [[ "$BASE_MHZ" != "0" ]]; then
            TSC_FREQ=$(( BASE_MHZ * 1000000 ))
            info "Auto-detected TSC frequency: ${TSC_FREQ} Hz (${BASE_MHZ} MHz)"
        else
            warn "Could not auto-detect TSC frequency. Omitting tsc-frequency flag."
            warn "You can set it manually with --tsc-freq 3900000000 (your base clock in Hz)"
            TSC_FREQ=""
        fi
    fi
fi

# Auto-detect CPU version string for SMBIOS type=4
if [[ -z "$SMBIOS_CPU_VERSION" ]]; then
    CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | xargs)
    if [[ -n "$CPU_MODEL" ]]; then
        # Extract generation / brand string, then replace specific model with "0000" for stealth
        # e.g., "13th Gen Intel(R) Core(TM) i7-13700K" → "13th Gen Intel(R) 0000"
        GEN_PREFIX=$(echo "$CPU_MODEL" | grep -oP '^\d+th Gen' || echo "")
        if [[ -n "$GEN_PREFIX" ]]; then
            SMBIOS_CPU_VERSION="${GEN_PREFIX} Intel(R) 0000"
        else
            # For newer Intel (e.g., "Intel(R) Core(TM) Ultra 9 265K")
            SMBIOS_CPU_VERSION="Genuine Intel(R) 0000"
        fi
        info "CPU SMBIOS version string: ${SMBIOS_CPU_VERSION}"
    else
        SMBIOS_CPU_VERSION="Genuine Intel(R) 0000"
    fi
fi

# Auto-calculate CPU affinity
if [[ -z "$AFFINITY" ]]; then
    # Pin to the first N physical cores
    LAST_CORE=$(( CORES - 1 ))
    AFFINITY="0-${LAST_CORE}"
    info "CPU affinity: ${AFFINITY}"
fi

# Generate random serials if not provided
if [[ -z "$DISK_SERIAL" ]]; then
    DISK_SERIAL=$(random_serial_20)
    info "Generated disk serial: ${DISK_SERIAL}"
fi
if [[ -z "$MEM_SERIAL" ]]; then
    MEM_SERIAL=$(random_hex 8)
    info "Generated memory serial: ${MEM_SERIAL}"
fi

###############################################################################
# Build QEMU args string
###############################################################################
info "Building QEMU args ..."

# ACPI tables
ACPI_ARGS="-acpitable file=/root/ssdt.aml -acpitable file=/root/ssdt-ec.aml -acpitable file=/root/hpet.aml"
if [[ "$CPU_TYPE" == "laptop" ]]; then
    # Laptop: replace ssdt.aml with ssdt-battery.aml (includes virtual battery)
    ACPI_ARGS="-acpitable file=/root/ssdt-battery.aml -acpitable file=/root/ssdt-ec.aml -acpitable file=/root/hpet.aml"
    info "Laptop mode: using ssdt-battery.aml (virtual battery for NVIDIA error 43 fix)"
fi

# CPU flags
CPU_FLAGS="host,host-cache-info=on,hypervisor=off,kvm=off,vmware-cpuid-freq=false,enforce=false,host-phys-bits=true,+invtsc,+tsc-deadline"
if [[ -n "$TSC_FREQ" ]]; then
    CPU_FLAGS="${CPU_FLAGS},tsc-frequency=${TSC_FREQ}"
fi

# SMP
SMP_ARGS="-smp ${CORES},sockets=1,cores=${CORES},threads=1"

# SMBIOS
SMBIOS_ARGS=""
# Type 0 — BIOS
SMBIOS_ARGS+=" -smbios type=0,vendor=\"${SMBIOS_BIOS_VENDOR}\",version=${SMBIOS_BIOS_VERSION},date='${SMBIOS_BIOS_DATE}',release=${SMBIOS_BIOS_RELEASE}"
# Type 1 — System
SMBIOS_ARGS+=" -smbios type=1,manufacturer=\"${SMBIOS_BOARD_MFG}\",product=\"${SMBIOS_BOARD_PRODUCT}\",version=\"${SMBIOS_BOARD_VERSION}\",serial=\"Default string\",sku=\"Default string\",family=\"Default string\""
# Type 2 — Baseboard
SMBIOS_ARGS+=" -smbios type=2,manufacturer=\"${SMBIOS_BOARD_MFG}\",product=\"${SMBIOS_BOARD_PRODUCT}\",version=\"${SMBIOS_BOARD_VERSION}\",serial=\"Default string\",asset=\"Default string\",location=\"Default string\""
# Type 3 — Chassis
SMBIOS_ARGS+=" -smbios type=3,manufacturer=\"Default string\",version=\"Default string\",serial=\"Default string\",asset=\"Default string\",sku=\"Default string\""
# Type 17 — Memory
SMBIOS_ARGS+=" -smbios type=17,serial=${MEM_SERIAL},asset=\"${MEM_ASSET}\""
# Type 4 — Processor
SMBIOS_ARGS+=" -smbios type=4,manufacturer=\"${SMBIOS_CPU_MFG}\",version=\"${SMBIOS_CPU_VERSION}\""
# Type 9 — System Slots (bare, triggers slot info generation in Strong build)
SMBIOS_ARGS+=" -smbios type=9"
# Type 8 — Port Connectors (×2 per author's config)
SMBIOS_ARGS+=" -smbios type=8 -smbios type=8"

# Timing / power
TIMING_ARGS="-overcommit cpu-pm=on -rtc base=localtime,driftfix=slew"

# Assemble full args line
FULL_ARGS="${ACPI_ARGS} -cpu ${CPU_FLAGS} ${SMP_ARGS} ${TIMING_ARGS}${SMBIOS_ARGS}"

###############################################################################
# Create the VM via qm
###############################################################################
echo ""
info "═══ Creating VM ${VMID} (${VM_NAME}) ═══"

# Step 1: Create base VM with OVMF + Q35
info "Creating base VM ..."
qm create "$VMID" \
    --name "$VM_NAME" \
    --bios ovmf \
    --machine q35 \
    --ostype "$OSTYPE" \
    --cpu host \
    --sockets 1 \
    --cores "$CORES" \
    --memory "$MEMORY" \
    --balloon 0 \
    --numa 0 \
    --scsihw lsi \
    --net0 "e1000,bridge=${BRIDGE},firewall=${FIREWALL}" \
    --vga "$VGA" \
    --localtime 1

ok "Base VM created"

# Step 2: Add EFI disk (4m = Secure Boot capable, pre-enrolled MS keys)
info "Adding EFI disk (Secure Boot capable) ..."
qm set "$VMID" --efidisk0 "${DISK_STORAGE}:1,efitype=4m,pre-enrolled-keys=1"
ok "EFI disk added with Secure Boot keys pre-enrolled"

# Step 2b: Add TPM 2.0 (real PCs have TPM — missing one is a detection vector)
info "Adding TPM 2.0 device ..."
qm set "$VMID" --tpmstate0 "${DISK_STORAGE}:1,version=v2.0"
ok "TPM 2.0 added"

# Step 3: Add SATA system disk
# qm expects size as bare number in GB (e.g. 256, not 256G)
DISK_SIZE_NUM=$(echo "$DISK_SIZE" | sed 's/[GgMm]$//')
info "Adding SATA system disk (${DISK_SIZE_NUM}GB) ..."
qm set "$VMID" --sata0 "${DISK_STORAGE}:${DISK_SIZE_NUM},ssd=1,serial=${DISK_SERIAL}"
ok "SATA disk added with serial ${DISK_SERIAL}"

# Step 4: Attach ISO if available
if [[ -n "$ISO_FILE" ]]; then
    info "Attaching ISO: ${ISO_FILE} ..."
    qm set "$VMID" --ide2 "${ISO_STORAGE}:iso/${ISO_FILE},media=cdrom"
    ok "ISO attached to ide2"
    # Boot from CD first for fresh Windows install, then disk
    qm set "$VMID" --boot "order=ide2;sata0;net0"
else
    qm set "$VMID" --boot "order=sata0;net0"
fi
ok "Boot order configured"

###############################################################################
# Write the args and extra config directly to the .conf file
# (qm doesn't support all the args flags we need via CLI)
###############################################################################
CONF_FILE="/etc/pve/qemu-server/${VMID}.conf"
info "Patching ${CONF_FILE} with anti-detection args ..."

# Check if args line already exists (it shouldn't for a new VM)
if grep -q "^args:" "$CONF_FILE" 2>/dev/null; then
    # Replace existing args line
    sed -i "/^args:/d" "$CONF_FILE"
fi

# Remove any existing affinity line
sed -i "/^affinity:/d" "$CONF_FILE" 2>/dev/null || true

# Prepend args as the first line (PVE convention: args at top)
# Write to /tmp first — /etc/pve is a FUSE filesystem (pmxcfs) where
# atomic rename within the same mount may behave unexpectedly
{
    echo "args: ${FULL_ARGS}"
    echo "affinity: ${AFFINITY}"
    cat "$CONF_FILE"
} > "/tmp/pve-vm-${VMID}.conf.tmp"
cp "/tmp/pve-vm-${VMID}.conf.tmp" "$CONF_FILE"
rm -f "/tmp/pve-vm-${VMID}.conf.tmp"

ok "Anti-detection args written to config"

###############################################################################
# Final verification — display the config
###############################################################################
echo ""
info "═══ VM ${VMID} Configuration ═══"
echo "────────────────────────────────────────────────────────────────"
cat "$CONF_FILE"
echo "────────────────────────────────────────────────────────────────"

echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   VM ${VMID} (${VM_NAME}) deployed successfully!                     ║${NC}"
echo -e "${GREEN}╠═══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║                                                               ║${NC}"
echo -e "${GREEN}║  Anti-Detection Features:                                     ║${NC}"
echo -e "${GREEN}║    ✓ OVMF + Q35 (Strong build firmware)                      ║${NC}"
echo -e "${GREEN}║    ✓ SMBIOS spoofing (types 0,1,2,3,4,8,9,17)               ║${NC}"
echo -e "${GREEN}║    ✓ ACPI custom tables (ssdt, ssdt-ec, hpet)                ║${NC}"
echo -e "${GREEN}║    ✓ Hypervisor + KVM signature hidden                       ║${NC}"
echo -e "${GREEN}║    ✓ TSC pinning + invtsc + tsc-deadline                     ║${NC}"
echo -e "${GREEN}║    ✓ CPU power management passthrough                        ║${NC}"
echo -e "${GREEN}║    ✓ RTC drift fix (localtime + slew)                        ║${NC}"
echo -e "${GREEN}║    ✓ e1000 NIC with realistic MAC prefix                     ║${NC}"
echo -e "${GREEN}║    ✓ SATA disk with custom serial (no virtio)                ║${NC}"
echo -e "${GREEN}║    ✓ LSI SCSI controller (no virtio-scsi)                    ║${NC}"
echo -e "${GREEN}║    ✓ Secure Boot (4m OVMF, pre-enrolled keys)                ║${NC}"
echo -e "${GREEN}║    ✓ TPM 2.0 emulation                                       ║${NC}"
echo -e "${GREEN}║    ✓ Balloon disabled                                        ║${NC}"
echo -e "${GREEN}║    ✓ CPU affinity: ${AFFINITY}                                      ║${NC}"
echo -e "${GREEN}║                                                               ║${NC}"
echo -e "${GREEN}║  Start VM:  qm start ${VMID}                                       ║${NC}"
echo -e "${GREEN}║                                                               ║${NC}"
echo -e "${GREEN}║  Post-Install Tips:                                           ║${NC}"
echo -e "${GREEN}║    • Install Windows normally                                 ║${NC}"
echo -e "${GREEN}║    • Do NOT install VirtIO/QEMU guest tools                  ║${NC}"
echo -e "${GREEN}║    • Clean registry: remove 1af4/1b36/0627 PCI entries       ║${NC}"
echo -e "${GREEN}║    • For GPU passthrough: change --vga none, add PCI device  ║${NC}"
echo -e "${GREEN}║    • Do NOT enable Hyper-V in the guest                      ║${NC}"
echo -e "${GREEN}║    • Test with: pafish64.exe, al-khaser, VMAware             ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
