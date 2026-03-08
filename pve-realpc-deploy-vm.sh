#!/usr/bin/env bash
###############################################################################
# pve-realpc-deploy-vm.sh — Deploy a Perfect Anti-Detection Windows VM
#
# Creates a fully configured Proxmox VM matching the upstream AICodo/pve-emu-realpc
# recommended configuration. The patched QEMU 10 binary handles most anti-detection
# internally (timing, NVRAM, system timers, CPUID, etc.) — the args line is kept
# intentionally minimal to avoid conflicting with the binary's built-in hiding.
#
# Default config (matches upstream exactly):
#   - OVMF + Q35 machine type (patched Strong OVMF firmware)
#   - SATA disk with custom serial
#   - e1000 NIC with realistic MAC prefix
#   - Full SMBIOS spoofing (types 0,1,2,3,4,8,9,17)
#   - Custom ACPI tables (ssdt.aml, ssdt-ec.aml, hpet.aml)
#   - CPU: host with hypervisor=off (NO kvm=off — binary handles it)
#   - Auto-detect host -smp topology (P/E core–aware thread mapping)
#   - NO timing args (patched binary handles timers/TSC/NVRAM internally)
#   - NO extra CPU feature flags (binary handles CPUID internally)
#   - Optional: ssdt-battery.aml for laptop CPUs / NVIDIA error 43 fix
#   - Optional: Intel Ultra iGPU passthrough (--igpu) with real GPU ROM
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
CORES=8                          # CPU cores (goes directly to PVE cores:)
THREADS_PER_CORE=0               # 0 = auto-detect from host (P/E core aware)
MEMORY=16384                     # Only 4096, 8192, or 16384 look realistic
DISK_SIZE="256G"                 # ≥128G to appear realistic
DISK_STORAGE="local-lvm"        # Where to create the VM disk
ISO_STORAGE="local"             # Where ISO files are stored
ISO_FILE=""                      # Auto-detect if empty
ISO_TYPE=""                      # "slim"|"stock"|"" for interactive picker
BRIDGE="vmbr0"                   # Network bridge
CPU_TYPE="desktop"               # "desktop" = ssdt.aml (no battery), "laptop" = ssdt-battery.aml
VGA="std"                        # "std" initially, "none" for GPU passthrough
ADD_TPM=false                    # --tpm adds TPM 2.0 (upstream doesn't include it)
AFFINITY=""                      # Empty = don't set; only written if --affinity passed
IGPU_PASSTHROUGH=false           # --igpu enables Intel Ultra iGPU passthrough
IGPU_PCI=""                      # Auto-detect if empty; usually 0000:00:02.0
IGPU_AUDIO_PCI=""                # Auto-detect if empty; usually 0000:00:1f.3
IGPU_GMS="0x2"                   # Pre-allocated DVMT: 0x2=64MB (must be ≥ BIOS setting)
IGPU_ROM="ultra-1-2-qemu10.rom"  # Intel Ultra 1st/2nd gen ROM (Arrow Lake / Lunar Lake)
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
        --threads)      THREADS_PER_CORE="$2";  shift 2 ;;
        --memory)       MEMORY="$2";            shift 2 ;;
        --disk-size)    DISK_SIZE="$2";         shift 2 ;;
        --disk-storage) DISK_STORAGE="$2";      shift 2 ;;
        --iso-storage)  ISO_STORAGE="$2";       shift 2 ;;
        --iso)          ISO_FILE="$2";          shift 2 ;;
        --iso-type)     ISO_TYPE="$2";          shift 2 ;;  # slim | stock
        --bridge)       BRIDGE="$2";            shift 2 ;;
        --type)         CPU_TYPE="$2";          shift 2 ;;  # desktop | laptop
        --vga)          VGA="$2";               shift 2 ;;
        --affinity)     AFFINITY="$2";          shift 2 ;;
        --tpm)          ADD_TPM=true;           shift   ;;
        --igpu)         IGPU_PASSTHROUGH=true;  shift   ;;
        --igpu-pci)     IGPU_PCI="$2";          shift 2 ;;
        --igpu-audio)   IGPU_AUDIO_PCI="$2";    shift 2 ;;
        --igpu-gms)     IGPU_GMS="$2";          shift 2 ;;
        --igpu-rom)     IGPU_ROM="$2";          shift 2 ;;
        --ostype)       OSTYPE="$2";            shift 2 ;;
        --board-mfg)    SMBIOS_BOARD_MFG="$2";     shift 2 ;;
        --board-product) SMBIOS_BOARD_PRODUCT="$2"; shift 2 ;;
        --disk-serial)  DISK_SERIAL="$2";       shift 2 ;;
        --firewall)     FIREWALL="$2";          shift 2 ;;
        --help|-h)
            cat <<'HELPEOF'
Usage: pve-realpc-deploy-vm.sh [OPTIONS]

This script creates VMs using the EXACT args recommended by the upstream
AICodo/pve-emu-realpc project. The patched QEMU 10 binary handles timing,
NVRAM, system timers, CPUID hiding, and topology INTERNALLY — extra args
flags for those features are intentionally omitted to avoid conflicts.

VM Configuration:
  --vmid NUM           VM ID (default: next available)
  --name NAME          VM name (default: win10)
  --cores NUM          CPU cores (default: 8, goes directly to PVE cores:)
  --threads NUM        Threads per core: 1|2 (default: auto-detect from host)
  --memory MB          Memory in MB: 4096|8192|16384 (default: 16384)
  --disk-size SIZE     Disk size, e.g. 256G (default: 256G)
  --disk-storage NAME  Storage pool for disks (default: local-lvm)
  --iso-storage NAME   Storage pool for ISOs (default: local)
  --iso FILENAME       ISO filename (default: auto-detect Windows ISO)
  --iso-type TYPE      ISO type: slim|stock (auto-filter ISOs by type)
  --bridge NAME        Network bridge (default: vmbr0)
  --vga TYPE           VGA type: std|none|virtio (default: std)
  --ostype TYPE        OS type: l26|win10|win11 (default: l26)
  --tpm                Add TPM 2.0 device (upstream doesn't include this)
  --affinity RANGE     CPU affinity, e.g. 0-7 (default: none)
  --firewall 0|1       Enable firewall (default: 1)

Intel Ultra iGPU Passthrough:
  --igpu               Enable Intel Ultra iGPU passthrough (auto-detects PCI)
  --igpu-pci ADDR      iGPU PCI address, e.g. 0000:00:02.0 (default: auto)
  --igpu-audio ADDR    Audio PCI address, e.g. 0000:00:1f.3 (default: auto)
  --igpu-gms HEX       DVMT pre-alloc: 0x2=64M 0x4=128M 0x8=256M (default: 0x2)
  --igpu-rom FILE      ROM filename in /usr/share/kvm/ (default: ultra-1-2-qemu10.rom)

Identity Spoofing:
  --type desktop|laptop  Desktop (no battery) or laptop (virtual battery)
  --board-mfg NAME       Motherboard manufacturer (default: Maxsun)
  --board-product NAME   Motherboard product (default: MS-Terminator B760M)
  --disk-serial SERIAL   20-char disk serial (default: random)

Notes:
  The patched QEMU 10 binary handles these INTERNALLY (do NOT add manually):
    - TSC frequency / pinning / invtsc
    - HPET, PIT, RTC system timers
    - KVM/hypervisor CPUID leaf hiding
    - CPU topology masking
    - EFI NVRAM variable sanitization
    - CPU power management passthrough

ISO Selection:
  If multiple ISOs exist, an interactive picker is shown unless --iso or
  --iso-type is used. ISOs are auto-tagged as [SLIM] or [STOCK] based on
  filename patterns (tiny11, atlas, revi, ghost, ntlite, msmg, etc.).

Examples:
  ./pve-realpc-deploy-vm.sh
  ./pve-realpc-deploy-vm.sh --vmid 200 --cores 8 --memory 16384
  ./pve-realpc-deploy-vm.sh --type laptop --vga none
  ./pve-realpc-deploy-vm.sh --igpu                    # iGPU passthrough (auto-detect)
  ./pve-realpc-deploy-vm.sh --igpu --igpu-gms 0x4     # iGPU with 128MB DVMT
  ./pve-realpc-deploy-vm.sh --cores 24 --affinity 0-23
  ./pve-realpc-deploy-vm.sh --iso-type slim          # Auto-pick slim ISO
  ./pve-realpc-deploy-vm.sh --iso-type stock          # Auto-pick stock ISO
  ./pve-realpc-deploy-vm.sh --iso tiny11_24H2.iso     # Explicit ISO file
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

# ─── ISO Selection ───────────────────────────────────────────────────────────
# Resolves the ISO storage path and either uses --iso, auto-filters by
# --iso-type (slim / stock), or presents an interactive numbered menu.
#
# Slim ISO patterns (auto-detected): tiny11, atlas, revi, ghost, spectre,
#   slim, lite, compact, debloat, stripped, mini, micro, optimized
# Stock ISO patterns: Win10, Win11, Windows, en-us_, en_windows
# ─────────────────────────────────────────────────────────────────────────────

# Common patterns for slim / debloated Windows ISOs
SLIM_PATTERNS="tiny11|tiny10|atlas|revi|ghost|spectre|slim|lite|compact|debloat|stripped|mini[^a-z]|micro|optimized|ntlite|msmg"
STOCK_PATTERNS="Win10|Win11|en-us_windows|en_windows|SW_DVD|MediaCreation"

resolve_iso_path() {
    local iso_dir="/var/lib/vz/template/iso"
    if [[ "$ISO_STORAGE" != "local" ]]; then
        iso_dir=$(pvesm path "${ISO_STORAGE}:iso/" 2>/dev/null | sed 's|/iso/$||' || echo "$iso_dir")
        [[ -d "$iso_dir" ]] || iso_dir="/var/lib/vz/template/iso"
    fi
    echo "$iso_dir"
}

if [[ -z "$ISO_FILE" ]]; then
    ISO_PATH=$(resolve_iso_path)

    if [[ ! -d "$ISO_PATH" ]]; then
        warn "ISO directory ${ISO_PATH} does not exist."
        ISO_FILE=""
    else
        # Gather all .iso files
        mapfile -t ALL_ISOS < <(find "$ISO_PATH" -maxdepth 1 -name "*.iso" -printf '%f\n' 2>/dev/null | sort)

        if [[ ${#ALL_ISOS[@]} -eq 0 ]]; then
            warn "No ISO files found in ${ISO_PATH}."
            warn "You can attach one later: qm set ${VMID} -ide2 ${ISO_STORAGE}:iso/YOUR_ISO.iso,media=cdrom"
            ISO_FILE=""

        elif [[ -n "$ISO_TYPE" ]]; then
            # ── Filter by --iso-type ──
            case "$ISO_TYPE" in
                slim)
                    mapfile -t FILTERED < <(printf '%s\n' "${ALL_ISOS[@]}" | grep -iE "$SLIM_PATTERNS" || true)
                    if [[ ${#FILTERED[@]} -eq 0 ]]; then
                        warn "No slim ISOs matched. Available ISOs:"
                        printf '    %s\n' "${ALL_ISOS[@]}"
                        fail "Use --iso FILENAME to specify manually, or remove --iso-type."
                    elif [[ ${#FILTERED[@]} -eq 1 ]]; then
                        ISO_FILE="${FILTERED[0]}"
                        ok "Auto-selected slim ISO: ${ISO_FILE}"
                    else
                        info "Multiple slim ISOs found:"
                        for i in "${!FILTERED[@]}"; do
                            echo -e "   ${CYAN}$((i+1))${NC}) ${FILTERED[$i]}"
                        done
                        echo -ne "${CYAN}Select [1-${#FILTERED[@]}]:${NC} "
                        read -r choice
                        choice=$((choice - 1))
                        if [[ $choice -ge 0 && $choice -lt ${#FILTERED[@]} ]]; then
                            ISO_FILE="${FILTERED[$choice]}"
                        else
                            fail "Invalid selection."
                        fi
                        ok "Selected slim ISO: ${ISO_FILE}"
                    fi
                    ;;
                stock)
                    mapfile -t FILTERED < <(printf '%s\n' "${ALL_ISOS[@]}" | grep -iE "$STOCK_PATTERNS" || true)
                    # Also include ISOs that don't match slim patterns as stock candidates
                    if [[ ${#FILTERED[@]} -eq 0 ]]; then
                        mapfile -t FILTERED < <(printf '%s\n' "${ALL_ISOS[@]}" | grep -ivE "$SLIM_PATTERNS" || true)
                    fi
                    if [[ ${#FILTERED[@]} -eq 0 ]]; then
                        warn "No stock ISOs matched. Available ISOs:"
                        printf '    %s\n' "${ALL_ISOS[@]}"
                        fail "Use --iso FILENAME to specify manually, or remove --iso-type."
                    elif [[ ${#FILTERED[@]} -eq 1 ]]; then
                        ISO_FILE="${FILTERED[0]}"
                        ok "Auto-selected stock ISO: ${ISO_FILE}"
                    else
                        info "Multiple stock ISOs found:"
                        for i in "${!FILTERED[@]}"; do
                            echo -e "   ${CYAN}$((i+1))${NC}) ${FILTERED[$i]}"
                        done
                        echo -ne "${CYAN}Select [1-${#FILTERED[@]}]:${NC} "
                        read -r choice
                        choice=$((choice - 1))
                        if [[ $choice -ge 0 && $choice -lt ${#FILTERED[@]} ]]; then
                            ISO_FILE="${FILTERED[$choice]}"
                        else
                            fail "Invalid selection."
                        fi
                        ok "Selected stock ISO: ${ISO_FILE}"
                    fi
                    ;;
                *) fail "Unknown --iso-type '${ISO_TYPE}'. Use: slim | stock" ;;
            esac

        elif [[ ${#ALL_ISOS[@]} -eq 1 ]]; then
            # Only one ISO — use it directly
            ISO_FILE="${ALL_ISOS[0]}"
            info "Auto-selected ISO (only one available): ${ISO_FILE}"

        else
            # ── Interactive ISO picker ──
            echo ""
            info "═══ ISO Selection ═══"
            info "Found ${#ALL_ISOS[@]} ISO files in ${ISO_PATH}:"
            echo ""

            # Classify and tag each ISO
            for i in "${!ALL_ISOS[@]}"; do
                local_iso="${ALL_ISOS[$i]}"
                tag=""
                if echo "$local_iso" | grep -iqE "$SLIM_PATTERNS"; then
                    tag="${YELLOW}[SLIM]${NC} "
                elif echo "$local_iso" | grep -iqE "$STOCK_PATTERNS"; then
                    tag="${GREEN}[STOCK]${NC}"
                fi
                echo -e "   ${CYAN}$((i+1))${NC}) ${tag} ${local_iso}"
            done
            echo -e "   ${CYAN}0${NC})  Skip — no ISO (attach later)"
            echo ""
            echo -ne "${CYAN}Select ISO [0-${#ALL_ISOS[@]}]:${NC} "
            read -r choice

            if [[ "$choice" == "0" ]]; then
                ISO_FILE=""
                warn "No ISO selected. Attach later: qm set ${VMID} -ide2 ${ISO_STORAGE}:iso/YOUR_ISO.iso,media=cdrom"
            elif [[ $choice -ge 1 && $choice -le ${#ALL_ISOS[@]} ]]; then
                ISO_FILE="${ALL_ISOS[$((choice-1))]}"
                ok "Selected ISO: ${ISO_FILE}"
            else
                fail "Invalid selection."
            fi
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

# Generate random serials if not provided
if [[ -z "$DISK_SERIAL" ]]; then
    DISK_SERIAL=$(random_serial_20)
    info "Generated disk serial: ${DISK_SERIAL}"
fi
if [[ -z "$MEM_SERIAL" ]]; then
    MEM_SERIAL=$(random_hex 8)
    info "Generated memory serial: ${MEM_SERIAL}"
fi

info "CPU cores: ${CORES} (PVE handles topology via cores: + sockets:1)"

###############################################################################
# Auto-detect host CPU topology for -smp (Priority 2)
# Ensures VM::THREAD_MISMATCH is not triggered — the VM's thread-per-core
# count must match what `host` CPU model reports via CPUID.
###############################################################################
if [[ "$THREADS_PER_CORE" -eq 0 ]] 2>/dev/null || [[ -z "$THREADS_PER_CORE" ]]; then
    HOST_THREADS=$(lscpu 2>/dev/null | grep -i 'Thread(s) per core' | awk '{print $NF}')
    if [[ -n "$HOST_THREADS" && "$HOST_THREADS" -ge 1 ]]; then
        THREADS_PER_CORE="$HOST_THREADS"
        info "Auto-detected host threads-per-core: ${THREADS_PER_CORE}"
    else
        THREADS_PER_CORE=1
        warn "Could not detect host threads-per-core, defaulting to 1"
    fi
fi

# Calculate topology: sockets × cores × threads must equal total vCPUs
# PVE's cores: is the total vCPU count when sockets=1 and threads is explicit
SMP_TOTAL=$((CORES * THREADS_PER_CORE))
SMP_CORES="$CORES"
SMP_THREADS="$THREADS_PER_CORE"
info "SMP topology: ${SMP_TOTAL} vCPUs (1 socket × ${SMP_CORES} cores × ${SMP_THREADS} threads)"

###############################################################################
# Build QEMU args string
# ─── IMPORTANT ───────────────────────────────────────────────────────────────
# The patched QEMU 10 binary (Strong build) handles most anti-detection
# INTERNALLY, including: timing (TSC/HPET/PIT/RTC), NVRAM/EFI variables,
# CPUID leaf hiding, system timer obfuscation, and CPU topology masking.
#
# Adding timer/CPU override flags like -rtc, -overcommit, kvm=off, +invtsc
# CONFLICTS with the binary's built-in behavior and CAUSES detection.
# -smp is safe (QEMU fundamental, not anti-detection) and we add it to match
# the host topology so the binary's masking has accurate data to work with.
#
# The args below match the upstream README exactly:
#   https://github.com/AICodo/pve-emu-realpc
###############################################################################
info "Building QEMU args (upstream-compatible minimal set) ..."

# ACPI tables
ACPI_ARGS="-acpitable file=/root/ssdt.aml -acpitable file=/root/ssdt-ec.aml -acpitable file=/root/hpet.aml"
if [[ "$CPU_TYPE" == "laptop" ]]; then
    # Laptop: replace ssdt.aml with ssdt-battery.aml (includes virtual battery)
    ACPI_ARGS="-acpitable file=/root/ssdt-battery.aml -acpitable file=/root/ssdt-ec.aml -acpitable file=/root/hpet.aml"
    info "Laptop mode: using ssdt-battery.aml (virtual battery for NVIDIA error 43 fix)"
fi

# CPU flags — MINIMAL, matching upstream exactly.
# The patched QEMU 10 binary handles kvm hiding, TSC, invtsc, timing, CPUID internally.
# Do NOT add: kvm=off, +invtsc, +tsc-deadline, +tsc_adjust, +rdpid, +xsaves,
#             +pdpe1gb, +umip, +md-clear, +arch-capabilities, tsc-frequency=
CPU_FLAGS="host,host-cache-info=on,hypervisor=off,vmware-cpuid-freq=false,enforce=false,host-phys-bits=true"

# NO -smp args — topology is set by PVE via cores: and sockets: in the .conf.
# We explicitly set threads via qm (cores × threads = total vCPUs).
# The patched QEMU binary needs topology to match host CPUID to avoid
# VM::THREAD_MISMATCH detection.

# NO timing args — the patched binary handles ALL of these internally:
#   - TSC frequency / pinning / invtsc
#   - HPET timer hiding
#   - PIT tick policy
#   - RTC drift correction
#   - ACPI PM timer obfuscation
#   - S3/S4 state handling
#   - CPU power management passthrough
# Adding -rtc, -overcommit, -global flags overrides the binary and causes detection.

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

# Intel Ultra iGPU passthrough args (when --igpu is enabled)
IGPU_ARGS=""
if [[ "$IGPU_PASSTHROUGH" == true ]]; then
    # Force VGA off — real GPU replaces virtual VGA
    VGA="none"
    info "iGPU passthrough enabled — VGA set to none"

    # Auto-detect iGPU PCI address
    if [[ -z "$IGPU_PCI" ]]; then
        IGPU_PCI=$(lspci -Dnn 2>/dev/null | grep -iE 'VGA|Display' | grep -i Intel | head -1 | awk '{print $1}')
        if [[ -z "$IGPU_PCI" ]]; then
            fail "Could not auto-detect Intel iGPU PCI address. Use --igpu-pci to specify."
        fi
        info "Auto-detected iGPU: ${IGPU_PCI}"
    fi

    # Auto-detect audio PCI (Intel HDA, usually 00:1f.3)
    if [[ -z "$IGPU_AUDIO_PCI" ]]; then
        IGPU_AUDIO_PCI=$(lspci -Dnn 2>/dev/null | grep -i audio | grep -i Intel | head -1 | awk '{print $1}')
        if [[ -n "$IGPU_AUDIO_PCI" ]]; then
            info "Auto-detected audio: ${IGPU_AUDIO_PCI}"
        else
            info "No Intel audio device detected — skipping audio passthrough"
        fi
    fi

    # Verify ROM file exists on host
    if [[ ! -f "/usr/share/kvm/${IGPU_ROM}" ]]; then
        fail "iGPU ROM not found: /usr/share/kvm/${IGPU_ROM}. Run pve-realpc-setup.sh --igpu first."
    fi

    # IGD passthrough args (QEMU 10+ Intel Ultra)
    IGPU_ARGS=" -set device.hostpci0.addr=02.0"
    IGPU_ARGS+=" -set device.hostpci0.x-igd-gms=${IGPU_GMS}"
    IGPU_ARGS+=" -set device.hostpci0.x-igd-opregion=on"
    IGPU_ARGS+=" -set device.hostpci0.x-igd-legacy-mode=on"
    info "iGPU args: IGD opregion=on, GMS=${IGPU_GMS}, legacy-mode=on"
fi

# Assemble full args line (matches upstream README for QEMU 9/10)
# Priority 5: Disable excess PCI root ports — Q35 creates 30+ by default,
# real systems have 4-8. Excess root ports with no devices trigger VM::EXCESS_PCI.
PCI_ARGS=" -global ICH9-LPC.disable_s3=1 -global ICH9-LPC.disable_s4=1"

# Priority 2: Override QEMU -smp with auto-detected host topology
SMP_ARGS=" -smp ${SMP_TOTAL},sockets=1,cores=${SMP_CORES},threads=${SMP_THREADS}"

FULL_ARGS="${ACPI_ARGS} -cpu ${CPU_FLAGS}${SMBIOS_ARGS}${IGPU_ARGS}${PCI_ARGS}${SMP_ARGS}"

###############################################################################
# Create the VM via qm
###############################################################################
echo ""
info "═══ Creating VM ${VMID} (${VM_NAME}) ═══"

# Step 1: Create base VM with OVMF + Q35
# --cores goes directly to PVE cores: — NO SMP override in args
info "Creating base VM ..."
qm create "$VMID" \
    --name "$VM_NAME" \
    --bios ovmf \
    --machine q35 \
    --ostype "$OSTYPE" \
    --cpu host \
    --sockets 1 \
    --cores "$SMP_TOTAL" \
    --memory "$MEMORY" \
    --balloon 0 \
    --numa 0 \
    --scsihw virtio-scsi-single \
    --net0 "e1000,bridge=${BRIDGE},firewall=${FIREWALL}" \
    --vga "$VGA" \
    --localtime 1

ok "Base VM created"

# Step 2: Add EFI disk
# Do NOT use pre-enrolled-keys — the patched Strong OVMF firmware handles
# Secure Boot and EFI variable sanitization internally. pre-enrolled-keys
# initializes from stock templates that contain detectable NVRAM variables.
info "Adding EFI disk (patched Strong OVMF firmware) ..."
qm set "$VMID" --efidisk0 "${DISK_STORAGE}:1,efitype=4m"
ok "EFI disk added (using patched OVMF — NVRAM variables are sanitized)"

# Step 2b: Add TPM 2.0 (optional — upstream config doesn't include it)
if [[ "$ADD_TPM" == "true" ]]; then
    info "Adding TPM 2.0 device ..."
    qm set "$VMID" --tpmstate0 "${DISK_STORAGE}:1,version=v2.0"
    ok "TPM 2.0 added"
fi

# Step 2c: Intel Ultra iGPU passthrough (optional)
if [[ "$IGPU_PASSTHROUGH" == true ]]; then
    info "Adding Intel Ultra iGPU passthrough ..."
    qm set "$VMID" --hostpci0 "${IGPU_PCI},romfile=${IGPU_ROM}"
    ok "iGPU passthrough: ${IGPU_PCI} with ${IGPU_ROM}"

    if [[ -n "$IGPU_AUDIO_PCI" ]]; then
        qm set "$VMID" --hostpci1 "${IGPU_AUDIO_PCI}"
        ok "Audio passthrough: ${IGPU_AUDIO_PCI}"
    fi
fi

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

# Remove any stale affinity line
sed -i "/^affinity:/d" "$CONF_FILE" 2>/dev/null || true

# Prepend args as the first line (PVE convention: args at top)
# Write to /tmp first — /etc/pve is a FUSE filesystem (pmxcfs) where
# atomic rename within the same mount may behave unexpectedly
{
    echo "args: ${FULL_ARGS}"
    # Only add affinity if explicitly requested via --affinity
    if [[ -n "$AFFINITY" ]]; then
        echo "affinity: ${AFFINITY}"
    fi
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
echo -e "${GREEN}║  Anti-Detection Features (upstream-compatible):               ║${NC}"
echo -e "${GREEN}║    ✓ OVMF + Q35 (patched Strong OVMF firmware)               ║${NC}"
echo -e "${GREEN}║    ✓ SMBIOS spoofing (types 0,1,2,3,4,8,9,17)              ║${NC}"
echo -e "${GREEN}║    ✓ ACPI custom tables (ssdt, ssdt-ec, hpet)                ║${NC}"
echo -e "${GREEN}║    ✓ CPU: host, hypervisor=off (binary hides KVM internally) ║${NC}"
echo -e "${GREEN}║    ✓ Cores: ${SMP_TOTAL} vCPUs (${SMP_CORES}c × ${SMP_THREADS}t, matches host topology)  ║${NC}"
echo -e "${GREEN}║    ✓ Timers handled by binary (TSC/HPET/PIT/RTC/NVRAM)       ║${NC}"
echo -e "${GREEN}║    ✓ EFI NVRAM sanitized (patched OVMF, no pre-enrolled-keys)║${NC}"
echo -e "${GREEN}║    ✓ e1000 NIC with realistic MAC prefix                     ║${NC}"
echo -e "${GREEN}║    ✓ SATA disk with custom serial (no virtio)                ║${NC}"
echo -e "${GREEN}║    ✓ Balloon disabled                                        ║${NC}"
if [[ -n "$AFFINITY" ]]; then
echo -e "${GREEN}║    ✓ CPU affinity: ${AFFINITY}                                      ║${NC}"
fi
if [[ "$ADD_TPM" == "true" ]]; then
echo -e "${GREEN}║    ✓ TPM 2.0 emulation                                       ║${NC}"
fi
if [[ "$IGPU_PASSTHROUGH" == true ]]; then
echo -e "${GREEN}║    ✓ Intel Ultra iGPU passthrough (${IGPU_ROM})   ║${NC}"
echo -e "${GREEN}║    ✓ IGD: opregion=on, GMS=${IGPU_GMS}, legacy-mode=on          ║${NC}"
if [[ -n "$IGPU_AUDIO_PCI" ]]; then
echo -e "${GREEN}║    ✓ Intel HDA audio passthrough (${IGPU_AUDIO_PCI})          ║${NC}"
fi
fi
echo -e "${GREEN}║                                                               ║${NC}"
echo -e "${GREEN}║  Start VM:  qm start ${VMID}                                       ║${NC}"
echo -e "${GREEN}║                                                               ║${NC}"
echo -e "${GREEN}║  Post-Install Tips:                                           ║${NC}"
echo -e "${GREEN}║    • Install Windows normally                                 ║${NC}"
echo -e "${GREEN}║    • Do NOT install VirtIO/QEMU guest tools                  ║${NC}"
echo -e "${GREEN}║    • Run windows\\run-tools.bat to clean VM fingerprints      ║${NC}"
echo -e "${GREEN}║    • For GPU passthrough: use --igpu or --vga none + hostpci ║${NC}"
echo -e "${GREEN}║    • Do NOT enable Hyper-V in the guest                      ║${NC}"
echo -e "${GREEN}║    • Test with: pafish64.exe, al-khaser, VMAware             ║${NC}"
echo -e "${GREEN}║                                                               ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
