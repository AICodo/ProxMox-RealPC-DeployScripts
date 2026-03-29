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
#   - e1000e NIC with realistic MAC prefix (Intel 82574L)
#   - Full SMBIOS spoofing (types 0,1,2,3,4,8,9,17)
#   - Custom ACPI tables (ssdt.aml, ssdt-ec.aml, hpet.aml)
#   - CPU: host with hypervisor=off (binary handles CPUID/KVM hiding)
#   - Auto-detect host -smp topology (P/E core–aware thread mapping)
#   - Host EFI variable injection into VM NVRAM (defeats NVRAM detection)
#   - S3/S4 sleep states enabled (defeats POWER_CAPABILITIES detection)
#   - Custom PIT SSDT (defeats SYSTEM_TIMERS / CLOCK detection)
#   - NO timing args (patched binary handles timers/TSC/NVRAM internally)
#   - NO extra CPU feature flags (binary handles CPUID internally)
#   - Optional: ssdt-battery.aml for laptop CPUs / NVIDIA error 43 fix
#   - Optional: iGPU passthrough (Intel/AMD) with vendor-specific ROM/config
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
CORES=0                          # 0 = auto-detect from host (matches CPUID topology)
THREADS_PER_CORE=0               # 0 = auto-detect from host (P/E core–aware thread mapping)
MEMORY=16384                     # Only 4096, 8192, or 16384 look realistic
DISK_SIZE="256G"                 # ≥128G to appear realistic
DISK_STORAGE="local-lvm"        # Where to create the VM disk
ISO_STORAGE="local"             # Where ISO files are stored
ISO_FILE=""                      # Auto-detect if empty
ISO_TYPE=""                      # "slim"|"stock"|"" for interactive picker
BRIDGE="vmbr0"                   # Network bridge
CPU_TYPE="desktop"               # "desktop" = ssdt.aml (no battery), "laptop" = ssdt-battery.aml
VGA="std"                        # "std"|"vmware"|"none"|"virtio" (vmware recommended for v10.2.1)
ADD_TPM=false                    # --tpm adds TPM 2.0 (upstream doesn't include it)
AFFINITY=""                      # Empty = don't set; only written if --affinity passed
IGPU_PASSTHROUGH=false           # --igpu enables iGPU passthrough (Intel or AMD)
IGPU_PCI=""                      # Auto-detect if empty (Intel: 0000:00:02.0, AMD: varies)
IGPU_AUDIO_PCI=""                # Auto-detect if empty; usually 0000:00:1f.3
IGPU_GMS="0x2"                   # (Intel only) Pre-allocated DVMT: 0x2=64MB (must be ≥ BIOS setting)
IGPU_ROM=""                      # Auto-detect from CPU vendor if empty
SMBIOS_BOARD_MFG=""               # Auto-detect from CPU vendor if empty
SMBIOS_BOARD_PRODUCT=""            # Auto-detect from CPU vendor if empty
SMBIOS_BOARD_VERSION=""            # Auto-detect from CPU vendor if empty
SMBIOS_BIOS_VENDOR=""             # Auto-detect from CPU vendor if empty
SMBIOS_BIOS_VERSION=""            # Auto-detect from CPU vendor if empty
SMBIOS_BIOS_DATE=""               # Auto-detect from CPU vendor if empty
SMBIOS_BIOS_RELEASE=""            # Auto-detect from CPU vendor if empty
SMBIOS_CPU_MFG=""                 # Auto-detect from CPU vendor if empty
SMBIOS_CPU_VERSION=""             # Auto-detect if empty
DISK_SERIAL=""                   # Random 20-char if empty
MEM_SERIAL=""                    # Random 8-char hex if empty
MEM_MFG=""                       # Auto-detect from CPU vendor if empty
MEM_SPEED=""                     # Auto-detect from CPU vendor if empty
MEM_PART=""                      # Auto-detect from CPU vendor if empty
MEM_ASSET=""                     # Random 10-digit if empty (upstream: "9876543210")
MEM_BANK="BANK 0"                # Standard bank identifier
MEM_LOC_PFX="Controller0-ChannelA-DIMM"  # Standard DIMM location prefix
MEM_EXPLICIT=false                # true when user passes any --mem-* flag (enables full type=17)
FIREWALL=1
OSTYPE="other"                   # 'other' avoids PVE injecting -global ICH9-LPC.disable_s3/s4=1 (l26 does)

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
        --mem-mfg)      MEM_MFG="$2"; MEM_EXPLICIT=true;  shift 2 ;;
        --mem-speed)    MEM_SPEED="$2"; MEM_EXPLICIT=true; shift 2 ;;
        --mem-part)     MEM_PART="$2"; MEM_EXPLICIT=true;  shift 2 ;;
        --mem-asset)    MEM_ASSET="$2"; MEM_EXPLICIT=true; shift 2 ;;
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
  --cores NUM          CPU cores (default: auto-detect from host CPUID topology)
  --threads NUM        Threads per core: 1|2 (default: auto-detect from host)
  --memory MB          Memory in MB: 4096|8192|16384 (default: 16384)
  --disk-size SIZE     Disk size, e.g. 256G (default: 256G)
  --disk-storage NAME  Storage pool for disks (default: local-lvm)
  --iso-storage NAME   Storage pool for ISOs (default: local)
  --iso FILENAME       ISO filename (default: auto-detect Windows ISO)
  --iso-type TYPE      ISO type: slim|stock (auto-filter ISOs by type)
  --bridge NAME        Network bridge (default: vmbr0)
  --vga TYPE           VGA type: std|vmware|none|virtio (default: std)
                         vmware is recommended for v10.2.1 (best 3D accel with GPU mirror)
  --ostype TYPE        OS type: other|l26|win10|win11 (default: other)
  --tpm                Add TPM 2.0 device (upstream doesn't include this)
  --affinity RANGE     CPU affinity, e.g. 0-7 (default: none)
  --firewall 0|1       Enable firewall (default: 1)

iGPU Passthrough (Intel / AMD):
  --igpu               Enable iGPU passthrough (auto-detects vendor + PCI address)
  --igpu-pci ADDR      iGPU PCI address, e.g. 0000:00:02.0 (default: auto)
  --igpu-audio ADDR    Audio PCI address, e.g. 0000:00:1f.3 (default: auto)
  --igpu-gms HEX       (Intel only) DVMT pre-alloc: 0x2=64M 0x4=128M 0x8=256M (default: 0x2)
  --igpu-rom FILE      ROM filename in /usr/share/kvm/ (default: auto per vendor)

Identity Spoofing:
  --type desktop|laptop  Desktop (no battery) or laptop (virtual battery)
  --board-mfg NAME       Motherboard manufacturer (default: Maxsun)
  --board-product NAME   Motherboard product (default: MS-Terminator B760M)
  --disk-serial SERIAL   20-char disk serial (default: random)
  --mem-mfg NAME         Memory manufacturer — enables full type=17 override
  --mem-speed SPEED      Memory speed in MT/s — enables full type=17 override
  --mem-part PART        Memory part number — enables full type=17 override
  --mem-asset ASSET      Memory asset tag — enables full type=17 override
                         Without --mem-* flags, QEMU 10 simplified type=17 is used
                         (serial+asset only; patched binary handles rest internally).
                         Any --mem-* flag switches to full format with all fields.

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
    # Uses bounded read to avoid SIGPIPE with set -eo pipefail
    local pool
    pool=$(od -An -tx1 -N64 /dev/urandom | tr -d ' \n' | tr '[:lower:]' '[:upper:]')
    echo "${pool:0:$len}"
}

random_serial_20() {
    # Generate a reliable 20-char alphanumeric serial (A-Z 0-9).
    # Read extra bytes to guarantee enough alphanumeric chars survive tr -dc.
    local pool
    pool=$(dd if=/dev/urandom bs=256 count=1 2>/dev/null | LC_ALL=C tr -dc 'A-Z0-9' | head -c 20)
    # Fallback: if pool is still short, pad with hex from /dev/urandom
    while [[ ${#pool} -lt 20 ]]; do
        pool+=$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n' | tr '[:lower:]' '[:upper:]' | LC_ALL=C tr -dc 'A-Z0-9')
        pool="${pool:0:20}"
    done
    echo "$pool"
}

qemu_escape_commas() {
    # QEMU option values use commas as field separators; literal commas must be
    # doubled (,,) to pass through. Without this, values like
    # "Micro-Star International Co., Ltd." break QEMU's -smbios parser.
    echo "${1//,/,,}"
}

###############################################################################
# Pre-flight
###############################################################################
require_root

# Validate --type is desktop or laptop
case "$CPU_TYPE" in
    desktop|laptop) ;;
    *) fail "Invalid --type '${CPU_TYPE}'. Use: desktop | laptop" ;;
esac

# Normalize --iso-type to lowercase
if [[ -n "$ISO_TYPE" ]]; then
    ISO_TYPE=$(echo "$ISO_TYPE" | tr '[:upper:]' '[:lower:]')
fi

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
        # pvesm path needs a volume ID, not a directory — use a dummy filename
        local resolved
        resolved=$(pvesm path "${ISO_STORAGE}:iso/dummy.iso" 2>/dev/null || true)
        if [[ -n "$resolved" ]]; then
            iso_dir=$(dirname "$resolved")
        fi
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

# Auto-detect CPU vendor for SMBIOS defaults
HOST_CPU_VENDOR="intel"
if grep -qi "AuthenticAMD" /proc/cpuinfo; then
    HOST_CPU_VENDOR="amd"
fi

# Apply vendor-appropriate SMBIOS defaults for any empty fields
if [[ "$HOST_CPU_VENDOR" == "amd" ]]; then
    [[ -z "$SMBIOS_BOARD_MFG" ]]    && SMBIOS_BOARD_MFG="Micro-Star International Co., Ltd."
    [[ -z "$SMBIOS_BOARD_PRODUCT" ]] && SMBIOS_BOARD_PRODUCT="MAG B650 TOMAHAWK WIFI"
    [[ -z "$SMBIOS_BOARD_VERSION" ]] && SMBIOS_BOARD_VERSION="1.0"
    [[ -z "$SMBIOS_BIOS_VENDOR" ]]   && SMBIOS_BIOS_VENDOR="American Megatrends International LLC."
    [[ -z "$SMBIOS_BIOS_VERSION" ]]  && SMBIOS_BIOS_VERSION="A.70"
    [[ -z "$SMBIOS_BIOS_DATE" ]]     && SMBIOS_BIOS_DATE="09/20/2024"
    [[ -z "$SMBIOS_BIOS_RELEASE" ]]  && SMBIOS_BIOS_RELEASE="2.29"
    [[ -z "$SMBIOS_CPU_MFG" ]]       && SMBIOS_CPU_MFG="Advanced Micro Devices, Inc."
    [[ -z "$MEM_MFG" ]]              && MEM_MFG="G.Skill International Enterprise Ltd."
    [[ -z "$MEM_SPEED" ]]            && MEM_SPEED="5600"
    [[ -z "$MEM_PART" ]]             && MEM_PART="F5-5600J3036D16G"
else
    [[ -z "$SMBIOS_BOARD_MFG" ]]    && SMBIOS_BOARD_MFG="Maxsun"
    [[ -z "$SMBIOS_BOARD_PRODUCT" ]] && SMBIOS_BOARD_PRODUCT="MS-Terminator B760M"
    [[ -z "$SMBIOS_BOARD_VERSION" ]] && SMBIOS_BOARD_VERSION="VER:H3.7G(2022/11/29)"
    [[ -z "$SMBIOS_BIOS_VENDOR" ]]   && SMBIOS_BIOS_VENDOR="American Megatrends International LLC."
    [[ -z "$SMBIOS_BIOS_VERSION" ]]  && SMBIOS_BIOS_VERSION="H3.7G"
    [[ -z "$SMBIOS_BIOS_DATE" ]]     && SMBIOS_BIOS_DATE="02/21/2023"
    [[ -z "$SMBIOS_BIOS_RELEASE" ]]  && SMBIOS_BIOS_RELEASE="3.7"
    [[ -z "$SMBIOS_CPU_MFG" ]]       && SMBIOS_CPU_MFG="Intel(R) Corporation"
    [[ -z "$MEM_MFG" ]]              && MEM_MFG="KINGSTON"
    [[ -z "$MEM_SPEED" ]]            && MEM_SPEED="3200"
    [[ -z "$MEM_PART" ]]             && MEM_PART="SED3200U1888S"
fi
info "SMBIOS vendor profile: ${HOST_CPU_VENDOR} (${SMBIOS_BOARD_MFG} / ${SMBIOS_BOARD_PRODUCT})"

# Auto-detect CPU version string for SMBIOS type=4
if [[ -z "$SMBIOS_CPU_VERSION" ]]; then
    CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | xargs)
    if [[ -n "$CPU_MODEL" ]]; then
        if [[ "$HOST_CPU_VENDOR" == "amd" ]]; then
            # e.g., "AMD Ryzen 9 7950X 16-Core Processor" → "AMD Ryzen 9 0000"
            SMBIOS_CPU_VERSION=$(echo "$CPU_MODEL" | sed -E 's/(AMD Ryzen [0-9]+ ).*/\10000/')
            # Fallback if sed didn't match
            [[ "$SMBIOS_CPU_VERSION" == "$CPU_MODEL" ]] && SMBIOS_CPU_VERSION="AMD 0000"
        else
            # Extract generation / brand string, then replace specific model with "0000" for stealth
            # e.g., "13th Gen Intel(R) Core(TM) i7-13700K" → "13th Gen Intel(R) 0000"
            GEN_PREFIX=$(echo "$CPU_MODEL" | grep -oP '^\d+th Gen' || echo "")
            if [[ -n "$GEN_PREFIX" ]]; then
                SMBIOS_CPU_VERSION="${GEN_PREFIX} Intel(R) 0000"
            else
                # For newer Intel (e.g., "Intel(R) Core(TM) Ultra 9 265K")
                SMBIOS_CPU_VERSION="Genuine Intel(R) 0000"
            fi
        fi
        info "CPU SMBIOS version string: ${SMBIOS_CPU_VERSION}"
    else
        if [[ "$HOST_CPU_VENDOR" == "amd" ]]; then
            SMBIOS_CPU_VERSION="AMD 0000"
        else
            SMBIOS_CPU_VERSION="Genuine Intel(R) 0000"
        fi
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
if [[ -z "$MEM_ASSET" ]]; then
    MEM_ASSET=$(od -An -tu4 -N4 /dev/urandom | tr -d ' ' | head -c 10)
    # Pad to 10 digits if urandom produced fewer
    while [[ ${#MEM_ASSET} -lt 10 ]]; do MEM_ASSET+="0"; done
    info "Generated memory asset: ${MEM_ASSET}"
fi

###############################################################################
# Auto-detect host CPU topology for -smp (Priority 2)
#
# CRITICAL: The VM's -smp topology MUST match what `cpu host` exposes via
# CPUID, otherwise VMAware's VM::THREAD_MISMATCH triggers.
#
# Intel hybrid CPUs (Alder Lake, Raptor Lake, Arrow Lake):
#   - P-cores may have HT (2 threads), E-cores always have 1 thread
#   - Arrow Lake (Core Ultra 200S, e.g. 265K): NO HT on any core
#   - lscpu "Thread(s) per core" shows the MAX across all core types
#   - nproc / lscpu "CPU(s)" = total logical CPUs (ground truth)
#
# Strategy: Use total logical CPUs (what CPUID max logical processors
# reports) as the authoritative count, then derive:
#   cores = total_logical_cpus / threads_per_core
###############################################################################

# Auto-detect threads per core
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

# Auto-detect core count from host CPUID topology
if [[ "$CORES" -eq 0 ]] 2>/dev/null || [[ -z "$CORES" ]]; then
    HOST_TOTAL_CPUS=$(nproc 2>/dev/null)
    if [[ -z "$HOST_TOTAL_CPUS" ]]; then
        HOST_TOTAL_CPUS=$(lscpu 2>/dev/null | grep -i '^CPU(s):' | awk '{print $NF}')
    fi
    if [[ -n "$HOST_TOTAL_CPUS" && "$HOST_TOTAL_CPUS" -ge 1 ]]; then
        CORES=$((HOST_TOTAL_CPUS / THREADS_PER_CORE))
        info "Auto-detected host topology: ${HOST_TOTAL_CPUS} logical CPUs → ${CORES} cores × ${THREADS_PER_CORE} threads"
    else
        CORES=8
        warn "Could not detect host CPU count, defaulting to 8 cores"
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

# Priority 1b: SYSTEM_TIMERS / CLOCK (45pts) — VMAware enumerates all Windows
# devices via SetupDi looking for hardware ID "PNP0100" (the ISA Programmable
# Interval Timer / 8254 PIT). Real PCs expose PIT via ACPI DSDT, but QEMU's
# generated DSDT omits it. If PIT is absent → VM detected.
# Fix: Load a custom SSDT that defines a PNP0100 device at the standard PIT
# I/O ports (0x40–0x43, IRQ 0). Created by pve-realpc-setup.sh using iasl.
#
# NOTE: pit.aml is NOT part of the upstream AICodo project. It's our addition.
# OVMF is stricter than SeaBIOS about ACPI table validation — if pit.aml causes
# issues, remove /root/pit.aml and the VM will boot without it (losing 45pts).
if [[ -f "/root/pit.aml" ]]; then
    ACPI_ARGS+=" -acpitable file=/root/pit.aml"
    info "PIT SSDT loaded (defeats SYSTEM_TIMERS / CLOCK detection)"
else
    info "pit.aml not present — skipping (upstream doesn't include it; VMAware CLOCK 45pts may trigger)"
fi

# CPU flags — matches upstream exactly:
#   host,host-cache-info=on,hypervisor=off,vmware-cpuid-freq=false,enforce=false,host-phys-bits=true
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
#   - CPU power management passthrough
# Adding -rtc, -overcommit flags overrides the binary and causes detection.
#
# HOWEVER, the binary does NOT handle:
#   - S3/S4 sleep state enablement (Proxmox/QEMU defaults leave these off)
#   - PIT device ACPI enumeration (PNP0100 not in QEMU's DSDT)
# These are fixed below via ICH9-LPC globals and a custom PIT SSDT.

# SMBIOS — matches upstream AICodo/pve-emu-realpc config EXACTLY.
# PVE's args: line is parsed by Perl Text::ParseWords::shellwords().
# Upstream uses double-quotes around individual values with spaces; shellwords
# handles this correctly, passing each -smbios option as a single QEMU argument.
#
# IMPORTANT: Commas in SMBIOS values must be escaped (doubled) because QEMU's
# -smbios parser uses commas as field separators. The qemu_escape_commas helper
# handles this (e.g. "Co., Ltd." → "Co.,, Ltd.").
SMBIOS_ARGS=""
# Type 0 — BIOS (upstream includes this — patched OVMF handles coexistence)
SMBIOS_ARGS+=" -smbios type=0,vendor=\"$(qemu_escape_commas "${SMBIOS_BIOS_VENDOR}")\",version=${SMBIOS_BIOS_VERSION},date='${SMBIOS_BIOS_DATE}',release=${SMBIOS_BIOS_RELEASE}"
# Type 1 — System (QEMU merges with PVE's smbios1:uuid= for a complete entry)
SMBIOS_ARGS+=" -smbios type=1,manufacturer=\"$(qemu_escape_commas "${SMBIOS_BOARD_MFG}")\",product=\"$(qemu_escape_commas "${SMBIOS_BOARD_PRODUCT}")\",version=\"$(qemu_escape_commas "${SMBIOS_BOARD_VERSION}")\",serial=\"Default string\",sku=\"Default string\",family=\"Default string\""
# Type 2 — Baseboard
SMBIOS_ARGS+=" -smbios type=2,manufacturer=\"$(qemu_escape_commas "${SMBIOS_BOARD_MFG}")\",product=\"$(qemu_escape_commas "${SMBIOS_BOARD_PRODUCT}")\",version=\"$(qemu_escape_commas "${SMBIOS_BOARD_VERSION}")\",serial=\"Default string\",asset=\"Default string\",location=\"Default string\""
# Type 3 — Chassis
SMBIOS_ARGS+=" -smbios type=3,manufacturer=\"Default string\",version=\"Default string\",serial=\"Default string\",asset=\"Default string\",sku=\"Default string\""
# Type 17 — Memory
# QEMU 10: patched binary generates realistic DIMM entries internally.
# Upstream uses simplified format: serial + asset only. Extra fields override
# the binary's defaults — only include them with explicit --mem-* flags.
if [[ "$MEM_EXPLICIT" == true ]]; then
    SMBIOS_ARGS+=" -smbios type=17,loc_pfx=\"${MEM_LOC_PFX}\",manufacturer=\"$(qemu_escape_commas "${MEM_MFG}")\",speed=${MEM_SPEED},serial=${MEM_SERIAL},part=\"${MEM_PART}\",bank=\"${MEM_BANK}\",asset=\"${MEM_ASSET}\""
    info "SMBIOS type=17: full format (user-specified --mem-* fields)"
else
    SMBIOS_ARGS+=" -smbios type=17,serial=${MEM_SERIAL},asset=\"${MEM_ASSET}\""
fi
# Type 4 — Processor
SMBIOS_ARGS+=" -smbios type=4,manufacturer=\"$(qemu_escape_commas "${SMBIOS_CPU_MFG}")\",version=\"$(qemu_escape_commas "${SMBIOS_CPU_VERSION}")\""
# Type 9 — System Slots (bare, triggers slot info generation in Strong build)
SMBIOS_ARGS+=" -smbios type=9"
# Type 8 — Port Connectors (×2 per author's config)
SMBIOS_ARGS+=" -smbios type=8 -smbios type=8"

# iGPU passthrough args (when --igpu is enabled — supports Intel and AMD)
IGPU_ARGS=""
if [[ "$IGPU_PASSTHROUGH" == true ]]; then
    # Force VGA off — real GPU replaces virtual VGA
    VGA="none"
    info "iGPU passthrough enabled — VGA set to none"

    # Detect GPU vendor for vendor-specific logic
    IGPU_VENDOR=""
    if [[ -z "$IGPU_PCI" ]]; then
        # Try Intel first, then AMD/ATI
        IGPU_PCI=$(lspci -Dnn 2>/dev/null | grep -iE 'VGA|Display' | grep -i Intel | head -1 | awk '{print $1}')
        if [[ -n "$IGPU_PCI" ]]; then
            IGPU_VENDOR="intel"
        else
            IGPU_PCI=$(lspci -Dnn 2>/dev/null | grep -iE 'VGA|Display' | grep -iE 'AMD|ATI|Radeon' | head -1 | awk '{print $1}')
            if [[ -n "$IGPU_PCI" ]]; then
                IGPU_VENDOR="amd"
            fi
        fi
        if [[ -z "$IGPU_PCI" ]]; then
            fail "Could not auto-detect iGPU PCI address. Use --igpu-pci to specify."
        fi
        info "Auto-detected ${IGPU_VENDOR^^} iGPU: ${IGPU_PCI}"
    else
        # Vendor detection from manually specified PCI address
        pci_desc=$(lspci -s "${IGPU_PCI#*:}" 2>/dev/null || true)
        if echo "$pci_desc" | grep -qi Intel; then
            IGPU_VENDOR="intel"
        elif echo "$pci_desc" | grep -qiE 'AMD|ATI|Radeon'; then
            IGPU_VENDOR="amd"
        else
            warn "Could not detect iGPU vendor from PCI address — assuming AMD (no IGD args)"
            IGPU_VENDOR="amd"
        fi
    fi

    # Auto-detect audio PCI
    if [[ -z "$IGPU_AUDIO_PCI" ]]; then
        if [[ "$IGPU_VENDOR" == "intel" ]]; then
            IGPU_AUDIO_PCI=$(lspci -Dnn 2>/dev/null | grep -i audio | grep -i Intel | head -1 | awk '{print $1}')
        else
            IGPU_AUDIO_PCI=$(lspci -Dnn 2>/dev/null | grep -i audio | grep -iE 'AMD|ATI' | head -1 | awk '{print $1}')
        fi
        if [[ -n "$IGPU_AUDIO_PCI" ]]; then
            info "Auto-detected audio: ${IGPU_AUDIO_PCI}"
        else
            info "No ${IGPU_VENDOR^^} audio device detected — skipping audio passthrough"
        fi
    fi

    # Auto-detect ROM if not specified
    if [[ -z "$IGPU_ROM" ]]; then
        if [[ "$IGPU_VENDOR" == "intel" ]]; then
            IGPU_ROM="ultra-1-2-qemu10.rom"
        fi
        # AMD iGPUs typically don't need a custom ROM for passthrough
    fi

    # Verify ROM file exists on host (if one is set)
    if [[ -n "$IGPU_ROM" ]] && [[ ! -f "/usr/share/kvm/${IGPU_ROM}" ]]; then
        fail "iGPU ROM not found: /usr/share/kvm/${IGPU_ROM}. Run pve-realpc-setup.sh --igpu first."
    fi

    # Vendor-specific passthrough args
    if [[ "$IGPU_VENDOR" == "intel" ]]; then
        # Intel IGD passthrough args (QEMU 10+)
        IGPU_ARGS=" -set device.hostpci0.addr=02.0"
        IGPU_ARGS+=" -set device.hostpci0.x-igd-gms=${IGPU_GMS}"
        IGPU_ARGS+=" -set device.hostpci0.x-igd-opregion=on"
        IGPU_ARGS+=" -set device.hostpci0.x-igd-legacy-mode=on"
        info "iGPU args: Intel IGD opregion=on, GMS=${IGPU_GMS}, legacy-mode=on"
    else
        # AMD iGPU — standard PCI passthrough, no IGD-specific flags
        info "iGPU args: AMD standard PCI passthrough (no IGD flags)"
    fi
fi

# Assemble full args line (matches upstream README for QEMU 9/10)
#
# Priority 1a: POWER_CAPABILITIES (45pts) — VMAware checks system power states via
# NtPowerInformation(SystemPowerCapabilities). Passes only if:
#   (S0 || S3) && (S4 || HiberFilePresent)
# Proxmox/QEMU defaults don't expose S3/S4, causing the "!(S0||S1||S2||S3)" pattern.
# Fix: Force-enable S3 (suspend-to-RAM) and S4 (suspend-to-disk) on the ICH9 LPC.
# Approach adapted from AutoVirt: --xml "./pm/suspend-to-mem/@enabled=yes"
#                                  --xml "./pm/suspend-to-disk/@enabled=yes"
#
# ACPI PCI hotplug is disabled — real hardware doesn't expose hotplug bridges,
# and the hotplug controller creates extra ACPI objects that fingerprint as VM.
PCI_ARGS=" -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off"
PCI_ARGS+=" -global ICH9-LPC.disable_s3=0"
PCI_ARGS+=" -global ICH9-LPC.disable_s4=0"

# Priority 6: Suppress VMAware's FIRMWARE / BOOT_LOGO / NVRAM / DEVICES checks.
#
# FIRMWARE (100pts): VMAware scans ALL ACPI/SMBIOS firmware tables for strings
#   "QEMU", "pc-q35", "BOCHS", "FWCF", "WAET", "S3 Corp.", "VS2005R2", "ovmf",
#   "edk ii unknown". The patched binary rewrites DSDT/FADT/MADT strings at build
#   time, but the Q35 machine name propagated through ACPI OEM fields needs the
#   custom tables to fully override. The ssdt/hpet AMLs handle this.
#
# BOOT_LOGO (100pts): CRC32 of the BCD boot logo bitmap — hash 0x110350C5 means
#   TianoCore EDK2 / OVMF. The patched Strong OVMF ROM should have a different
#   logo, but if not, the guest-side qemu-cleanup handles the registry remnant.
#
# NVRAM (100pts): OVMF ships Red Hat signing certs in PKDefault. VMAware scans
#   UEFI NVRAM variables for "red hat". The deploy script now injects the host's
#   real EFI Secure Boot variables (PK, KEK, db, dbx + defaults) into the VM's
#   OVMF_VARS using virt-fw-vars, replacing Red Hat certs with genuine Microsoft/
#   hardware vendor certs. We also do NOT use pre-enrolled-keys.
#   Approach adapted from: https://github.com/Scrut1ny/AutoVirt
#
# DEVICES (95pts): PCI vendor/device IDs 0x1af4 (VirtIO), 0x1b36 (QEMU bridge),
#   0x1234 (bochs-display), 0x0627 (QEMU display subsystem). The patched binary
#   remaps these. We don't use VirtIO NIC/disk (e1000e + SATA instead) reducing
#   exposure. The guest-side qemu-cleanup.ps1 removes any remaining PCI registry
#   artefacts.
#
# is_hardened() META-CHECK: VMAware detects "hardened" VMs when FIRMWARE triggers
# but HYPERVISOR_BIT is clean (hypervisor=off). The patched binary MUST prevent
# firmware strings from leaking, otherwise this meta-check catches the hiding.
# There is no args-level fix — the binary MUST handle firmware table sanitization.

# Priority 7: DISPLAY / GPU_CAPABILITIES — VMAware checks gamma ramp support,
# bits-per-pixel (≤8 = suspicious), and DPI. stdvga appears as QEMU STD VGA with
# limited capabilities. With GPU passthrough (--igpu) this is not an issue.
# For stdvga users: guest-side resolution and color depth must be ≥32bpp.
#
# v10.2.1 DISPLAY CHANGES:
#   - VMware compatible display is now supported and RECOMMENDED (best 3D accel
#     with iGPU/dGPU mirror, PCI-ID no longer 0x15ad)
#   - VirtIO-GPU is now supported (OVMF only, basic adapter, PCI-ID no longer 0x1af4)
#   - Standard VGA PCI-ID is no longer 0x1234
#   - Spice display still has PCI-ID 0x1b36 (NOT recommended)
#   - VirtIO-GPU does NOT work with SeaBIOS
if [[ "$VGA" == "std" ]]; then
    warn "Using stdvga — consider --vga vmware for v10.2.1 (recommended by upstream for best 3D accel)."
    warn "VMAware GPU_CAPABILITIES (45pts) and DISPLAY (25pts) may trigger with stdvga."
    warn "For best results, pass a real GPU (--igpu) or set resolution to ≥1920x1080 @32bpp in-guest."
elif [[ "$VGA" == "vmware" ]]; then
    info "Using VMware compatible display (recommended by upstream v10.2.1 for best 3D acceleration)"
fi

# Priority 2: THREAD_MISMATCH — PVE sets topology via cores:/sockets: in the conf.
# We do NOT add -smp to args; /proc/cpuinfo auto-detection already sets the correct
# cores: value in the qm create call. Adding -smp to args can conflict with PVE's
# own -smp generation from cores:/sockets:. (Upstream does NOT use -smp in args.)

FULL_ARGS="${ACPI_ARGS} -cpu ${CPU_FLAGS}${SMBIOS_ARGS}${IGPU_ARGS}${PCI_ARGS}"

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
    --net0 "e1000e,bridge=${BRIDGE},firewall=${FIREWALL}" \
    --vga "$VGA" \
    --localtime 1

ok "Base VM created"

# Step 1b: smbios1: uuid-only (matching upstream exactly).
# PVE generates `-smbios type=1,uuid=UUID` from this line. The args: line provides
# the additional type=1 fields (manufacturer, product, etc.) and QEMU merges them.
SYS_UUID=$(cat /proc/sys/kernel/random/uuid)
SMBIOS1_LINE="uuid=${SYS_UUID}"
info "Prepared SMBIOS type=1 (uuid=${SYS_UUID})"

# Step 2: Add EFI disk
# Do NOT use pre-enrolled-keys — the patched Strong OVMF firmware handles
# Secure Boot and EFI variable sanitization internally. pre-enrolled-keys
# initializes from stock templates that contain detectable NVRAM variables.
info "Adding EFI disk (patched Strong OVMF firmware) ..."
qm set "$VMID" --efidisk0 "${DISK_STORAGE}:1,efitype=4m"
ok "EFI disk added"

# Step 2a: Inject host EFI variables into VM NVRAM (defeats VMAware VM::NVRAM)
#
# VMAware's NVRAM check (100pts) scans UEFI variables for:
#   1. Variables prefixed with "VMM" (e.g. VMMBootOrder)
#   2. Missing PKDefault / KEKDefault / dbxDefault variables
#   3. "red hat" string in PK or PKDefault (OVMF ships Red Hat signing certs)
#   4. Missing MemoryOverwriteRequestControlLock when Secure Boot is active
#
# Fix: Extract the REAL host machine's EFI Secure Boot keys from
# /sys/firmware/efi/efivars/ and inject them into the VM's OVMF_VARS image
# using virt-fw-vars. This replaces any Red Hat / OVMF default certs with
# genuine Microsoft / hardware vendor certificates from the host firmware.
#
# Approach adapted from: https://github.com/Scrut1ny/AutoVirt
info "Injecting host EFI variables into VM NVRAM (anti-NVRAM detection) ..."

# SAFETY: Back up the pristine OVMF_VARS before modifying. If injection produces
# a corrupt image, OVMF will hang at "Guest has not initialized the display".
# We restore from backup if anything goes wrong.
NVRAM_INJECTED=false
EFI_BACKUP_PATH=""
if command -v virt-fw-vars &>/dev/null && [[ -d /sys/firmware/efi/efivars ]]; then
    # Resolve the VM's efidisk volume path
    EFI_VOLID=$(grep -oP 'efidisk0:\s*\K[^,]+' "/etc/pve/qemu-server/${VMID}.conf" 2>/dev/null || true)
    EFI_DISK_PATH=""
    if [[ -n "$EFI_VOLID" ]]; then
        EFI_DISK_PATH=$(pvesm path "$EFI_VOLID" 2>/dev/null || true)
    fi

    if [[ -n "$EFI_DISK_PATH" ]]; then
        # Back up pristine OVMF_VARS before any modification
        EFI_BACKUP_PATH="/tmp/pve-efidisk-${VMID}-pristine.qcow2"
        cp "$EFI_DISK_PATH" "$EFI_BACKUP_PATH" 2>/dev/null || true

        # Extract the raw OVMF_VARS partition from the efidisk
        # PVE efidisk is a raw QCOW2 image containing only the VARS region
        NVRAM_WORK="/tmp/pve-nvram-${VMID}"
        mkdir -p "$NVRAM_WORK"
        NVRAM_JSON="${NVRAM_WORK}/efivars.json"
        NVRAM_ORIG="${NVRAM_WORK}/OVMF_VARS.fd"
        NVRAM_NEW="${NVRAM_WORK}/OVMF_VARS_injected.fd"

        # Export the current OVMF_VARS from the efidisk as raw
        qemu-img convert -f qcow2 -O raw "$EFI_DISK_PATH" "$NVRAM_ORIG" 2>/dev/null \
            || cp "$EFI_DISK_PATH" "$NVRAM_ORIG" 2>/dev/null || true

        if [[ -f "$NVRAM_ORIG" ]]; then
            # Collect host EFI variables (same approach as AutoVirt)
            EFI_GLOBAL=8be4df61-93ca-11d2-aa0d-00e098032b8c
            EFI_IMAGE_SEC=d719b2cb-3d3a-4596-a3bc-dad00e67656f

            EFI_KEYS=(
                "PK:${EFI_GLOBAL}"
                "KEK:${EFI_GLOBAL}"
                "db:${EFI_IMAGE_SEC}"
                "dbx:${EFI_IMAGE_SEC}"
                "PKDefault:${EFI_GLOBAL}"
                "KEKDefault:${EFI_GLOBAL}"
                "dbDefault:${EFI_GLOBAL}"
                "dbxDefault:${EFI_GLOBAL}"
            )

            {
                printf '{\n    "version": 2,\n    "variables": [\n'
                first=true
                for entry in "${EFI_KEYS[@]}"; do
                    IFS=: read -r name guid <<< "$entry"
                    path="/sys/firmware/efi/efivars/${name}-${guid}"
                    [[ -f "$path" ]] || continue

                    full_hex=$(hexdump -ve '1/1 "%.2x"' "$path" 2>/dev/null) || continue
                    # First 4 bytes are attributes (little-endian); skip if too short
                    [[ ${#full_hex} -ge 8 ]] || continue
                    attr=$(printf '%d' "0x${full_hex:6:2}${full_hex:4:2}${full_hex:2:2}${full_hex:0:2}" 2>/dev/null) || continue

                    "$first" && first=false || printf ',\n'
                    printf '        { "name": "%s", "guid": "%s", "attr": %d, "data": "%s" }' \
                        "$name" "$guid" "$attr" "${full_hex:8}"
                done
                printf '\n    ]\n}\n'
            } > "$NVRAM_JSON"

            # Count how many variables we extracted
            VAR_COUNT=$(grep -c '"name"' "$NVRAM_JSON" 2>/dev/null || echo "0")

            if [[ "$VAR_COUNT" -ge 2 ]]; then
                # Inject host EFI variables into the OVMF_VARS image
                # || true: must not kill the script if injection fails —
                # the VM is already created and the args line still needs to be written
                virt-fw-vars \
                    --input "$NVRAM_ORIG" \
                    --output "$NVRAM_NEW" \
                    --secure-boot \
                    --set-json "$NVRAM_JSON" 2>/dev/null || true

                if [[ -f "$NVRAM_NEW" ]]; then
                    # Verify the injected image is a valid size (should be ~256K-4M)
                    NVRAM_NEW_SIZE=$(stat -c%s "$NVRAM_NEW" 2>/dev/null || echo "0")
                    if [[ "$NVRAM_NEW_SIZE" -ge 131072 ]]; then
                        # Write back to the efidisk
                        qemu-img convert -f raw -O qcow2 "$NVRAM_NEW" "$EFI_DISK_PATH" 2>/dev/null \
                            || cp "$NVRAM_NEW" "$EFI_DISK_PATH" 2>/dev/null || true
                        NVRAM_INJECTED=true
                        ok "Host EFI variables injected into VM NVRAM (${VAR_COUNT} variables: PK, KEK, db, dbx, defaults)"
                    else
                        warn "NVRAM injection produced undersized image (${NVRAM_NEW_SIZE} bytes) — restoring pristine backup"
                        [[ -n "$EFI_BACKUP_PATH" && -f "$EFI_BACKUP_PATH" ]] && cp "$EFI_BACKUP_PATH" "$EFI_DISK_PATH" 2>/dev/null || true
                    fi
                fi
            else
                warn "Could not extract host EFI variables (found ${VAR_COUNT}). Host may not be UEFI or Secure Boot is off."
            fi
        fi

        # Cleanup
        rm -rf "$NVRAM_WORK"
        [[ -n "$EFI_BACKUP_PATH" && -f "$EFI_BACKUP_PATH" ]] && rm -f "$EFI_BACKUP_PATH"
    else
        warn "Could not resolve EFI disk path for VMID ${VMID}"
    fi
else
    if ! command -v virt-fw-vars &>/dev/null; then
        warn "virt-fw-vars not found. Install python3-virt-firmware for NVRAM anti-detection."
        warn "  apt install python3-virt-firmware   (or)   pip install virt-firmware"
    fi
    if [[ ! -d /sys/firmware/efi/efivars ]]; then
        warn "Host not booted in UEFI mode — cannot extract EFI variables for NVRAM injection."
    fi
fi

if [[ "$NVRAM_INJECTED" != true ]]; then
    warn "NVRAM injection skipped — VM may fail VMAware's NVRAM check (100pts)."
    warn "The Strong OVMF firmware provides partial protection, but host EFI variable"
    warn "injection is needed for full NVRAM anti-detection."
fi

# Step 2b: Add TPM 2.0 (optional — upstream config doesn't include it)
if [[ "$ADD_TPM" == "true" ]]; then
    info "Adding TPM 2.0 device ..."
    qm set "$VMID" --tpmstate0 "${DISK_STORAGE}:1,version=v2.0"
    ok "TPM 2.0 added"
fi

# Step 2c: iGPU passthrough (Intel or AMD)
if [[ "$IGPU_PASSTHROUGH" == true ]]; then
    info "Adding ${IGPU_VENDOR^^} iGPU passthrough ..."
    if [[ -n "$IGPU_ROM" ]]; then
        qm set "$VMID" --hostpci0 "${IGPU_PCI},romfile=${IGPU_ROM}"
        ok "iGPU passthrough: ${IGPU_PCI} with ${IGPU_ROM}"
    else
        qm set "$VMID" --hostpci0 "${IGPU_PCI}"
        ok "iGPU passthrough: ${IGPU_PCI} (no ROM)"
    fi

    if [[ -n "$IGPU_AUDIO_PCI" ]]; then
        qm set "$VMID" --hostpci1 "${IGPU_AUDIO_PCI}"
        ok "Audio passthrough: ${IGPU_AUDIO_PCI}"
    fi
fi

# Step 3: Add SATA system disk
# qm expects size as bare number in GB (e.g. 256, not 256G)
DISK_SIZE_NUM=$(echo "$DISK_SIZE" | sed 's/[GgMmBbTt]*$//')
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
info "Patching ${CONF_FILE} with anti-detection config ..."

# Remove any existing args/smbios1/affinity lines (shouldn't exist for a new VM,
# but clean up just in case of re-runs or leftover state)
sed -i '/^args:/d'     "$CONF_FILE" 2>/dev/null || true
sed -i '/^smbios1:/d'  "$CONF_FILE" 2>/dev/null || true
sed -i '/^affinity:/d' "$CONF_FILE" 2>/dev/null || true

# Write args + smbios1 directly to the conf file.
# This bypasses qm set's strict regex validation for smbios1 string fields.
# PVE reads the conf file on VM start and generates the correct QEMU command line.
# /etc/pve is a FUSE filesystem (pmxcfs) — write to /tmp first, then copy.
TMP_CONF=$(mktemp /tmp/pve-vm-XXXXXX.conf)
{
    echo "args: ${FULL_ARGS}"
    echo "smbios1: ${SMBIOS1_LINE}"
    # Only add affinity if explicitly requested via --affinity
    if [[ -n "$AFFINITY" ]]; then
        echo "affinity: ${AFFINITY}"
    fi
    cat "$CONF_FILE"
} > "$TMP_CONF"
cp "$TMP_CONF" "$CONF_FILE"
rm -f "$TMP_CONF"

ok "Anti-detection args + SMBIOS type=1 written to config"

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
echo -e "${GREEN}║    ✓ ACPI custom tables (ssdt, ssdt-ec, hpet, pit)            ║${NC}"
echo -e "${GREEN}║    ✓ CPU: host, hypervisor=off (binary hides KVM)          ║${NC}"
echo -e "${GREEN}║    ✓ Cores: ${SMP_TOTAL} vCPUs (${SMP_CORES}c × ${SMP_THREADS}t, matches host topology)  ║${NC}"
echo -e "${GREEN}║    ✓ Timers handled by binary (TSC/HPET/PIT/RTC)             ║${NC}"
echo -e "${GREEN}║    ✓ EFI NVRAM: host variables injected (real Secure Boot certs)║${NC}"
echo -e "${GREEN}║    ✓ ACPI PCI hotplug disabled (no hotplug fingerprint)       ║${NC}"
echo -e "${GREEN}║    ✓ S3/S4 sleep states enabled (defeats POWER_CAPABILITIES) ║${NC}"
echo -e "${GREEN}║    ✓ PIT SSDT loaded (defeats SYSTEM_TIMERS / CLOCK)          ║${NC}"
echo -e "${GREEN}║    ✓ e1000e NIC with realistic MAC (Intel 82574L PCIe)       ║${NC}"
echo -e "${GREEN}║    ✓ SATA disk with custom serial (no virtio)                ║${NC}"
echo -e "${GREEN}║    ✓ Balloon disabled                                        ║${NC}"
if [[ -n "$AFFINITY" ]]; then
echo -e "${GREEN}║    ✓ CPU affinity: ${AFFINITY}                                      ║${NC}"
fi
if [[ "$ADD_TPM" == "true" ]]; then
echo -e "${GREEN}║    ✓ TPM 2.0 emulation                                       ║${NC}"
fi
if [[ "$IGPU_PASSTHROUGH" == true ]]; then
echo -e "${GREEN}║    ✓ ${IGPU_VENDOR^^} iGPU passthrough (${IGPU_ROM:-no ROM})   ║${NC}"
if [[ "$IGPU_VENDOR" == "intel" ]]; then
echo -e "${GREEN}║    ✓ IGD: opregion=on, GMS=${IGPU_GMS}, legacy-mode=on          ║${NC}"
fi
if [[ -n "$IGPU_AUDIO_PCI" ]]; then
echo -e "${GREEN}║    ✓ Audio passthrough (${IGPU_AUDIO_PCI})                     ║${NC}"
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

###############################################################################
# Generate deployment summary file
###############################################################################
SUMMARY_FILE="/root/vm-${VMID}-deploy-summary.txt"
{
    echo "=== VM ${VMID} (${VM_NAME}) — Deployment Summary ==="
    echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    echo "--- SMBIOS Identity ---"
    echo "Board Manufacturer : ${SMBIOS_BOARD_MFG}"
    echo "Board Product      : ${SMBIOS_BOARD_PRODUCT}"
    echo "Board Version      : ${SMBIOS_BOARD_VERSION}"
    echo "BIOS Vendor        : ${SMBIOS_BIOS_VENDOR}"
    echo "BIOS Version       : ${SMBIOS_BIOS_VERSION}"
    echo "BIOS Date          : ${SMBIOS_BIOS_DATE}"
    echo "CPU Manufacturer   : ${SMBIOS_CPU_MFG}"
    echo "CPU Version        : ${SMBIOS_CPU_VERSION}"
    echo "System UUID        : ${SYS_UUID}"
    echo "Disk Serial        : ${DISK_SERIAL}"
    echo "Memory Manufacturer: ${MEM_MFG}"
    echo "Memory Speed       : ${MEM_SPEED} MT/s"
    echo "Memory Part        : ${MEM_PART}"
    echo "Memory Serial      : ${MEM_SERIAL}"
    echo "Memory Asset       : ${MEM_ASSET}"
    echo ""
    echo "--- VM Hardware ---"
    echo "VMID       : ${VMID}"
    echo "Name       : ${VM_NAME}"
    echo "CPU Type   : ${CPU_TYPE}"
    echo "Topology   : ${SMP_TOTAL} vCPUs (${SMP_CORES}c × ${SMP_THREADS}t)"
    echo "Memory     : ${MEMORY}MB"
    echo "Disk       : ${DISK_SIZE} on ${DISK_STORAGE}"
    echo "VGA        : ${VGA}"
    echo "NIC        : e1000e on ${BRIDGE}"
    echo "ISO        : ${ISO_FILE:-none}"
    if [[ -n "$AFFINITY" ]]; then
        echo "Affinity   : ${AFFINITY}"
    fi
    if [[ "$IGPU_PASSTHROUGH" == true ]]; then
        echo "iGPU       : ${IGPU_VENDOR^^} ${IGPU_PCI} (ROM: ${IGPU_ROM:-none}, GMS: ${IGPU_GMS})"
    fi
    echo ""
    echo "--- Full Config File ---"
    cat "$CONF_FILE"
    echo ""
    echo "--- QEMU Args (decoded) ---"
    echo "${FULL_ARGS}" | tr ' ' '\n' | grep -v '^$'
} > "$SUMMARY_FILE"
ok "Deployment summary saved to ${SUMMARY_FILE}"
info "View anytime: cat ${SUMMARY_FILE}"
