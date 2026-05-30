#!/usr/bin/env bash

# Copyright (c) 2025-2026 Diobyte
# License: MIT
# Deploys a fully cloaked Windows VM on Proxmox VE with patched QEMU 11,
# OVMF, and KVM anti-detection — matching upstream AICodo/pve-emu-realpc.
#
# Prerequisites: Run pve-realpc-setup.sh first to install patched packages.

# ─── Colour & UI system ───────────────────────────────────────────────────────
YW=$(echo -e "\033[33m")
BL=$(echo -e "\033[36m")
RD=$(echo -e "\033[01;31m")
BGN=$(echo -e "\033[4;92m")
GN=$(echo -e "\033[1;92m")
DGN=$(echo -e "\033[32m")
MG=$(echo -e "\033[0;35m")
CL=$(echo -e "\033[m")
NC=$(echo -e "\033[m")
BOLD=$(echo -e "\033[1m")
DIM=$(echo -e "\033[2m")
BFR="\\r\\033[K"
HOLD=" "
TAB="  "

CM="${TAB}✔️${TAB}${CL}"
CROSS="${TAB}✖️${TAB}${CL}"
INFO="${TAB}💡${TAB}${CL}"
SEC="${TAB}🔒${TAB}${CL}"
CPU="${TAB}🧠${TAB}${CL}"
DISK="${TAB}💾${TAB}${CL}"
NET="${TAB}🌐${TAB}${CL}"
ID="${TAB}🆔${TAB}${CL}"
NAME="${TAB}🏷️${TAB}${CL}"
BOARD="${TAB}📋${TAB}${CL}"
ACPI="${TAB}⚡${TAB}${CL}"
GPU="${TAB}🎮${TAB}${CL}"
BOOT="${TAB}🔐${TAB}${CL}"
ARGS="${TAB}🛡️${TAB}${CL}"
CREATING="${TAB}🚀${TAB}${CL}"
DEFAULT="${TAB}⚙️${TAB}${CL}"
ADVANCED="${TAB}🧩${TAB}${CL}"

set -e
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
trap 'cleanup_vmid_on_exit' EXIT

function header_info() {
  clear
  cat <<'BANNER'

  ╔═══════════════════════════════════════════════════════════════════╗
  ║   ██████╗ ██╗   ██╗███████╗    ██████╗ ███████╗ █████╗ ██╗       ║
  ║   ██╔══██╗██║   ██║██╔════╝    ██╔══██╗██╔════╝██╔══██╗██║       ║
  ║   ██████╔╝██║   ██║█████╗      ██████╔╝█████╗  ███████║██║       ║
  ║   ██╔═══╝ ╚██╗ ██╔╝██╔══╝      ██╔══██╗██╔══╝  ██╔══██║██║       ║
  ║   ██║      ╚████╔╝ ███████╗    ██║  ██║███████╗██║  ██║███████╗   ║
  ║   ╚═╝       ╚═══╝  ╚══════╝    ╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝╚══════╝   ║
  ╠═══════════════════════════════════════════════════════════════════╣
  ║     Anti-VM-Detection VM Deployment  ·  QEMU 11  ·  OVMF          ║
  ╚═══════════════════════════════════════════════════════════════════╝

BANNER
}

# ─── UI helpers ───────────────────────────────────────────────────────────────
function msg_info()  { echo -ne "${TAB}${YW}${HOLD}${1}${HOLD}"; }
function msg_ok()    { echo -e "${BFR}${CM}${GN}${1}${CL}"; }
function msg_error() { echo -e "${BFR}${CROSS}${RD}${1}${CL}"; }
function msg_warn()  { echo -e "${BFR}${INFO}${YW}${1}${CL}"; }

function error_handler() {
  local exit_code="$?"
  local line_number="$1"
  local command="$2"
  local error_message="${RD}[ERROR]${CL} line ${RD}${line_number}${CL}: exit ${RD}${exit_code}${CL}: ${YW}${command}${CL}"
  echo -e "\n${error_message}\n"
  destroy_vmid
}

function exit_script() {
  clear
  echo -e "\n${CROSS}${RD}User exited script${CL}\n"
  exit
}

# ─── Guards ───────────────────────────────────────────────────────────────────
function check_root() {
  if [[ "$(id -u)" -ne 0 || $(ps -o comm= -p $PPID) == "sudo" ]]; then
    clear
    if [[ "$(id -u)" -ne 0 ]]; then
      msg_error "Please run this script as root (su -)."
    else
      msg_error "sudo detected — please log in as root directly (su -) instead of using sudo."
    fi
    sleep 2
    exit
  fi
}

function pve_check() {
  if ! command -v pveversion &>/dev/null; then
    msg_error "pveversion not found — this script requires Proxmox VE."
    exit 1
  fi
  local ver
  ver=$(pveversion 2>/dev/null | grep -oP 'pve-manager/\K[0-9]+')
  if [[ "$ver" != "8" && "$ver" != "9" ]]; then
    msg_warn "Detected PVE major version ${ver}. This script targets PVE 9."
    msg_warn "Proceed at your own risk."
    sleep 2
  fi
}

function arch_check() {
  if [[ "$(dpkg --print-architecture)" != "amd64" ]]; then
    msg_error "This script requires amd64 architecture."
    exit 1
  fi
}

function ssh_check() {
  if command -v pveversion &>/dev/null && [[ -n "${SSH_CLIENT:+x}" ]]; then
    if ! whiptail --backtitle "PVE RealPC Deploy" --defaultno \
      --title "SSH Detected" \
      --yesno "It's recommended to use the Proxmox shell instead of SSH. Proceed anyway?" 10 62; then
      exit_script
    fi
  fi
}

# ─── VMID helpers ─────────────────────────────────────────────────────────────
function get_valid_nextid() {
  local try_id
  try_id=$(pvesh get /cluster/nextid 2>/dev/null || echo "100")
  while true; do
    if [[ -f "/etc/pve/qemu-server/${try_id}.conf" ]] || [[ -f "/etc/pve/lxc/${try_id}.conf" ]]; then
      try_id=$((try_id + 1)); continue
    fi
    if lvs --noheadings -o lv_name 2>/dev/null | grep -qE "(^|[-_])${try_id}($|[-_])"; then
      try_id=$((try_id + 1)); continue
    fi
    break
  done
  echo "$try_id"
}

CLEANUP_VMID=""
function destroy_vmid() {
  if [[ -n "${CLEANUP_VMID}" ]] && qm status "${CLEANUP_VMID}" &>/dev/null; then
    msg_warn "Destroying half-built VM ${CLEANUP_VMID}..."
    qm stop "${CLEANUP_VMID}" --skiplock 1 &>/dev/null || true
    qm destroy "${CLEANUP_VMID}" --purge 1 --destroy-unreferenced-disks 1 &>/dev/null || true
  fi
}

function cleanup_vmid_on_exit() {
  local rc=$?
  [[ -n "${CLEANUP_VMID}" ]] && destroy_vmid
  exit $rc
}

# ─── Entropy helpers ──────────────────────────────────────────────────────────
function random_hex() {
  local pool
  pool=$(od -An -tx1 -N64 /dev/urandom | tr -d ' \n' | tr '[:lower:]' '[:upper:]')
  echo "${pool:0:$1}"
}

function random_serial_20() {
  local pool
  pool=$(dd if=/dev/urandom bs=256 count=1 2>/dev/null | LC_ALL=C tr -dc 'A-Z0-9' | head -c 20)
  local _tries=0
  while [[ ${#pool} -lt 20 && _tries -lt 20 ]]; do
    pool+=$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n' | tr '[:lower:]' '[:upper:]' | LC_ALL=C tr -dc 'A-Z0-9')
    pool="${pool:0:20}"; ((_tries++))
  done
  while [[ ${#pool} -lt 20 ]]; do pool+='X'; done
  echo "$pool"
}

function qemu_escape_commas() { echo "${1//,/,,}"; }

# ─── Pre-flight validation ────────────────────────────────────────────────────
function validate_prerequisites() {
  msg_info "Checking prerequisites"

  # ACPI tables must exist
  for aml in ssdt.aml ssdt-ec.aml hpet.aml; do
    [[ -f "/root/${aml}" ]] || { msg_error "Missing /root/${aml} — run pve-realpc-setup.sh first!"; exit 1; }
  done
  if [[ "$VM_TYPE" == "laptop" ]]; then
    [[ -f "/root/ssdt-battery.aml" ]] || { msg_error "Missing /root/ssdt-battery.aml for laptop mode — run pve-realpc-setup.sh first!"; exit 1; }
  fi

  # QEMU binary size check (~30MB for patched, ~8MB for stock)
  local qemu_size
  qemu_size=$(stat -c%s /usr/bin/qemu-system-x86_64 2>/dev/null || echo "0")
  if (( qemu_size < 29000000 )); then
    msg_warn "qemu-system-x86_64 seems stock (${qemu_size} bytes). Run pve-realpc-setup.sh first!"
  fi

  msg_ok "Prerequisites validated"
}

# ─── Storage helpers ──────────────────────────────────────────────────────────
function storage_supports() {
  local name="$1" content="$2"
  pvesm status -content "$content" 2>/dev/null | awk -v n="$name" '$1 == n && $3 == "active" { found=1 } END { exit !found }'
}

function pick_storage() {
  local content="$1" default="$2" label="$3"
  local storage="${default}"
  if ! storage_supports "$storage" "$content"; then
    storage=$(pvesm status -content "$content" 2>/dev/null | awk 'NR>1 && $3 == "active" { print $1; exit }')
    if [[ -n "$storage" ]]; then
      msg_warn "Default ${label} storage '${default}' unavailable — using '${storage}'"
    else
      msg_error "No active storage with '${content}' content found. Pass --${label,,}-storage explicitly."
      exit 1
    fi
  fi
  echo "$storage"
}

# ─── ISO resolution ───────────────────────────────────────────────────────────
SLIM_PATTERNS="tiny11|tiny10|atlas|revi|ghost|spectre|slim|lite|compact|debloat|stripped|mini[^a-z]|micro|optimized|ntlite|msmg"
STOCK_PATTERNS="Win10|Win11|en-us_windows|en_windows|SW_DVD|MediaCreation"

function resolve_iso_path() {
  local iso_storage="$1"
  local iso_dir
  iso_dir=$(dirname "$(pvesm path "${iso_storage}:iso/dummy.iso" 2>/dev/null || true)" 2>/dev/null || true)
  if [[ -z "$iso_dir" || ! -d "$iso_dir" ]] && [[ "$iso_storage" == "local" ]]; then
    iso_dir="/var/lib/vz/template/iso"
  fi
  echo "$iso_dir"
}

function pick_iso() {
  local iso_dir="$1" iso_file="$2" iso_type="$3" vmid="$4" iso_storage="$5"

  mapfile -t ALL_ISOS < <(find "$iso_dir" -maxdepth 1 -name "*.iso" -printf '%f\n' 2>/dev/null | sort)

  if [[ ${#ALL_ISOS[@]} -eq 0 ]]; then
    msg_warn "No ISO files found in ${iso_dir}."
    msg_warn "Attach later: qm set ${vmid} -ide2 ${iso_storage}:iso/YOUR_ISO.iso,media=cdrom"
    echo ""
    return
  fi

  # --iso FILENAME passed explicitly
  if [[ -n "$iso_file" ]]; then
    echo "$iso_file"; return
  fi

  # Only one ISO — use it
  if [[ ${#ALL_ISOS[@]} -eq 1 && -z "$iso_type" ]]; then
    msg_ok "Auto-selected ISO: ${ALL_ISOS[0]}"
    echo "${ALL_ISOS[0]}"; return
  fi

  # Filter by type
  if [[ -n "$iso_type" ]]; then
    local -a FILTERED
    case "$iso_type" in
      slim)
        mapfile -t FILTERED < <(printf '%s\n' "${ALL_ISOS[@]}" | grep -iE "$SLIM_PATTERNS" || true)
        ;;
      stock)
        mapfile -t FILTERED < <(printf '%s\n' "${ALL_ISOS[@]}" | grep -iE "$STOCK_PATTERNS" || true)
        [[ ${#FILTERED[@]} -eq 0 ]] && mapfile -t FILTERED < <(printf '%s\n' "${ALL_ISOS[@]}" | grep -ivE "$SLIM_PATTERNS" || true)
        ;;
    esac
    if [[ ${#FILTERED[@]} -eq 1 ]]; then
      msg_ok "Auto-selected ${iso_type} ISO: ${FILTERED[0]}"
      echo "${FILTERED[0]}"; return
    elif [[ ${#FILTERED[@]} -gt 1 ]]; then
      # Multiple matches — present interactive picker of filtered ISOs
      echo ""
      msg_info "${iso_type^^} ISO Selection — ${#FILTERED[@]} matches"
      for i in "${!FILTERED[@]}"; do
        echo -e "   $((i+1))) ${FILTERED[$i]}"
      done
      echo -e "   0)  Skip — no ISO"
      while true; do
        read -rp "Select [0-${#FILTERED[@]}, Enter=skip]: " choice
        [[ -z "$choice" ]] && choice=0
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 0 && choice <= ${#FILTERED[@]} )); then
          if (( choice == 0 )); then
            msg_warn "No ISO selected. Attach later: qm set ${vmid} -ide2 ${iso_storage}:iso/YOUR_ISO.iso,media=cdrom"
            echo ""
          else
            msg_ok "Selected: ${FILTERED[$((choice-1))]}"
            echo "${FILTERED[$((choice-1))]}"
          fi
          return
        fi
        msg_warn "Enter 0..${#FILTERED[@]} (0 or Enter to skip)."
      done
    fi
    msg_error "No ${iso_type} ISOs matched. Use --iso FILENAME or remove --iso-type."; exit 1
  fi

  # Interactive picker
  echo ""
  msg_info "ISO Selection — found ${#ALL_ISOS[@]} files"
  for i in "${!ALL_ISOS[@]}"; do
    local tag=""
    if echo "${ALL_ISOS[$i]}" | grep -iqE "$SLIM_PATTERNS"; then
      tag="[SLIM] "
    elif echo "${ALL_ISOS[$i]}" | grep -iqE "$STOCK_PATTERNS"; then
      tag="[STOCK]"
    fi
    echo -e "   $((i+1))) ${YW}${tag}${CL}${ALL_ISOS[$i]}"
  done
  echo -e "   0)  Skip — no ISO"
  while true; do
    read -rp "Select ISO [0-${#ALL_ISOS[@]}, Enter=skip]: " choice
    [[ -z "$choice" ]] && choice=0
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 0 && choice <= ${#ALL_ISOS[@]} )); then
      if (( choice == 0 )); then
        msg_warn "No ISO selected. Attach later: qm set ${vmid} -ide2 ${iso_storage}:iso/YOUR_ISO.iso,media=cdrom"
        echo ""
      else
        msg_ok "Selected: ${ALL_ISOS[$((choice-1))]}"
        echo "${ALL_ISOS[$((choice-1))]}"
      fi
      return
    fi
    msg_warn "Enter 0..${#ALL_ISOS[@]} (0 or Enter to skip)."
  done
}

# ─── CPU / SMBIOS auto-detection ──────────────────────────────────────────────
function detect_cpu_vendor() {
  if grep -qi "GenuineIntel" /proc/cpuinfo; then echo "intel"
  elif grep -qi "AuthenticAMD" /proc/cpuinfo; then echo "amd"
  else echo "intel"; fi
}

function apply_smbios_profile() {
  local vendor="$1"
  if [[ "$vendor" == "amd" ]]; then
    SMBIOS_BOARD_MFG="${SMBIOS_BOARD_MFG:-Micro-Star International Co., Ltd.}"
    SMBIOS_BOARD_PRODUCT="${SMBIOS_BOARD_PRODUCT:-MAG B650 TOMAHAWK WIFI}"
    SMBIOS_BOARD_VERSION="${SMBIOS_BOARD_VERSION:-1.0}"
    SMBIOS_BIOS_VENDOR="${SMBIOS_BIOS_VENDOR:-American Megatrends International LLC.}"
    SMBIOS_BIOS_VERSION="${SMBIOS_BIOS_VERSION:-A.70}"
    SMBIOS_BIOS_DATE="${SMBIOS_BIOS_DATE:-09/20/2024}"
    SMBIOS_BIOS_RELEASE="${SMBIOS_BIOS_RELEASE:-2.29}"
    SMBIOS_CPU_MFG="${SMBIOS_CPU_MFG:-Advanced Micro Devices, Inc.}"
    MEM_MFG="${MEM_MFG:-G.Skill International Enterprise Ltd.}"
    MEM_SPEED="${MEM_SPEED:-5600}"
    MEM_PART="${MEM_PART:-F5-5600J3036D16G}"
  else
    SMBIOS_BOARD_MFG="${SMBIOS_BOARD_MFG:-Maxsun}"
    SMBIOS_BOARD_PRODUCT="${SMBIOS_BOARD_PRODUCT:-MS-Terminator B760M}"
    SMBIOS_BOARD_VERSION="${SMBIOS_BOARD_VERSION:-VER:H3.7G(2022/11/29)}"
    SMBIOS_BIOS_VENDOR="${SMBIOS_BIOS_VENDOR:-American Megatrends International LLC.}"
    SMBIOS_BIOS_VERSION="${SMBIOS_BIOS_VERSION:-H3.7G}"
    SMBIOS_BIOS_DATE="${SMBIOS_BIOS_DATE:-02/21/2023}"
    SMBIOS_BIOS_RELEASE="${SMBIOS_BIOS_RELEASE:-3.7}"
    SMBIOS_CPU_MFG="${SMBIOS_CPU_MFG:-Intel(R) Corporation}"
    MEM_MFG="${MEM_MFG:-KINGSTON}"
    MEM_SPEED="${MEM_SPEED:-3200}"
    MEM_PART="${MEM_PART:-SED3200U1888S}"
  fi
  echo -e "${BOARD}${BOLD}${DGN}Board: ${BGN}${SMBIOS_BOARD_MFG} ${SMBIOS_BOARD_PRODUCT}${CL}"
}

function detect_cpu_version() {
  local cpu_model vendor="$1"
  cpu_model=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | xargs 2>/dev/null || echo "")
  [[ -z "$cpu_model" ]] && { [[ "$vendor" == "amd" ]] && echo "AMD 0000" || echo "Genuine Intel(R) 0000"; return; }

  if [[ "$vendor" == "amd" ]]; then
    local ver
    ver=$(echo "$cpu_model" | sed -E 's/(AMD Ryzen Threadripper( PRO)? ).*/\10000/')
    [[ "$ver" == "$cpu_model" ]] && ver=$(echo "$cpu_model" | sed -E 's/(AMD Ryzen AI [0-9]+ ).*/\10000/')
    [[ "$ver" == "$cpu_model" ]] && ver=$(echo "$cpu_model" | sed -E 's/(AMD Ryzen (PRO )?[0-9]+ ).*/\10000/')
    [[ "$ver" == "$cpu_model" ]] && ver=$(echo "$cpu_model" | sed -E 's/(AMD EPYC ).*/\10000/')
    [[ "$ver" == "$cpu_model" ]] && ver=$(echo "$cpu_model" | sed -E 's/(AMD Athlon ).*/\10000/')
    [[ "$ver" == "$cpu_model" ]] && ver=$(echo "$cpu_model" | sed -E 's/(AMD A[0-9]+-).*/AMD 0000/')
    [[ "$ver" == "$cpu_model" ]] && ver="AMD 0000"
    echo "$ver"
  else
    local gen
    gen=$(echo "$cpu_model" | grep -oP '^\d+(st|nd|rd|th) Gen' || echo "")
    if [[ -n "$gen" ]]; then echo "${gen} Intel(R) 0000"
    elif echo "$cpu_model" | grep -qiP 'Core.*Ultra'; then
      local ultra
      ultra=$(echo "$cpu_model" | grep -oP 'Intel.*Ultra \d+' || echo "")
      [[ -n "$ultra" ]] && echo "${ultra} 0000" || echo "Genuine Intel(R) 0000"
    elif echo "$cpu_model" | grep -qiP 'Xeon'; then
      local xeon
      xeon=$(echo "$cpu_model" | sed -E 's/(Intel.*Xeon[^[:space:]]*).*/\1 0000/')
      [[ "$xeon" == "$cpu_model" ]] && xeon="Intel(R) Xeon(R) 0000"
      echo "$xeon"
    elif echo "$cpu_model" | grep -qP 'Intel.*N[0-9]'; then echo "Intel(R) N 0000"
    elif echo "$cpu_model" | grep -qiP 'Pentium|Celeron'; then
      local brand; brand=$(echo "$cpu_model" | grep -oiP 'Pentium|Celeron' | head -1)
      echo "Intel(R) ${brand}(R) 0000"
    elif echo "$cpu_model" | grep -qiP 'Core.*i[3579]-'; then echo "Intel(R) Core(TM) 0000"
    else echo "Genuine Intel(R) 0000"; fi
  fi
}

function detect_topology() {
  local cores="${1:-0}" threads="${2:-0}"

  # Threads per core
  if [[ -z "$threads" || "$threads" == "0" ]]; then
    if grep -qE 'Core\(TM\) Ultra' /proc/cpuinfo 2>/dev/null; then
      threads=1
      echo -e "${CPU}${BOLD}${DGN}Intel Core Ultra (no HT) — forcing threads=1${CL}" >&2
    else
      threads=$(lscpu 2>/dev/null | grep -i 'Thread(s) per core' | awk '{print $NF}')
      [[ -z "$threads" || "$threads" -lt 1 ]] && threads=1
    fi
    echo -e "${CPU}${BOLD}${DGN}Threads per core: ${BGN}${threads}${CL}" >&2
  fi

  # Core count
  if [[ -z "$cores" || "$cores" == "0" ]]; then
    local total
    total=$(nproc 2>/dev/null || lscpu 2>/dev/null | grep -i '^CPU(s):' | awk '{print $NF}')
    [[ -z "$total" || "$total" -lt 1 ]] && total=8
    cores=$((total / threads))
  fi

  local smp_total=$((cores * threads))
  echo -e "${CPU}${BOLD}${DGN}Topology: ${BGN}${smp_total} vCPUs (${cores}c × ${threads}t, 1 socket)${CL}" >&2
  echo "${cores}:${threads}:${smp_total}"
}

# ─── iGPU detection ───────────────────────────────────────────────────────────
function detect_igpu() {
  local igpu_pci="${1:-}" igpu_rom="${2:-}"
  local vendor="" audio=""

  if [[ -z "$igpu_pci" ]]; then
    local lspci_out
    lspci_out=$(lspci -Dnn 2>/dev/null | grep -iE 'VGA|Display' || true)
    # Prefer bus 00 (iGPU) over discrete GPU
    igpu_pci=$(echo "$lspci_out" | grep -i Intel | awk '$1 ~ /^0000:00:/ {print $1; exit}')
    if [[ -n "$igpu_pci" ]]; then vendor="intel"
    else
      igpu_pci=$(echo "$lspci_out" | grep -iE 'AMD|ATI|Radeon' | awk '$1 ~ /^0000:00:/ {print $1; exit}')
      [[ -z "$igpu_pci" ]] && igpu_pci=$(echo "$lspci_out" | grep -iE 'AMD|ATI|Radeon' | awk 'NR==1 {print $1; exit}')
      [[ -n "$igpu_pci" ]] && vendor="amd"
    fi
    [[ -z "$igpu_pci" ]] && { igpu_pci=$(echo "$lspci_out" | grep -i Intel | awk 'NR==1 {print $1; exit}'); [[ -n "$igpu_pci" ]] && vendor="intel"; }
    [[ -z "$igpu_pci" ]] && { msg_error "Could not auto-detect iGPU. Use --igpu-pci to specify."; exit 1; }
    echo -e "${GPU}${BOLD}${DGN}Auto-detected ${vendor^^} iGPU: ${BGN}${igpu_pci}${CL}" >&2
  else
    local desc; desc=$(lspci -s "${igpu_pci}" 2>/dev/null || true)
    if echo "$desc" | grep -qi Intel; then vendor="intel"
    elif echo "$desc" | grep -qiE 'AMD|ATI|Radeon'; then vendor="amd"
    else vendor="amd"; msg_warn "Unknown GPU vendor — assuming AMD"
    fi
  fi

  # Audio device
  if [[ "$vendor" == "intel" ]]; then
    audio=$(lspci -Dnn 2>/dev/null | grep -i audio | grep -i Intel | head -1 | awk '{print $1}')
  else
    audio=$(lspci -Dnn 2>/dev/null | grep -i audio | grep -iE 'AMD|ATI' | head -1 | awk '{print $1}')
  fi
  [[ -n "$audio" ]] && echo -e "${GPU}${BOLD}${DGN}Audio device: ${BGN}${audio}${CL}" >&2

  # ROM
  [[ -z "$igpu_rom" && "$vendor" == "intel" ]] && igpu_rom="ultra-1-2-qemu10.rom"

  echo "${vendor}:${igpu_pci}:${audio:-}:${igpu_rom:-}"
}

# ─── Configuration defaults ───────────────────────────────────────────────────
function default_config() {
  # Use := pattern — preserves values already set by CLI (parse_args runs first)
  VMID="${VMID:-$(get_valid_nextid)}"
  VM_NAME="${VM_NAME:-win10}"
  VM_TYPE="${VM_TYPE:-desktop}"
  CORES="${CORES:-0}"
  THREADS="${THREADS:-0}"
  MEMORY="${MEMORY:-16384}"
  DISK_SIZE="${DISK_SIZE:-256G}"
  DISK_STORAGE="${DISK_STORAGE:-local-lvm}"
  ISO_STORAGE="${ISO_STORAGE:-local}"
  ISO_FILE="${ISO_FILE:-}"
  ISO_TYPE="${ISO_TYPE:-}"
  BRIDGE="${BRIDGE:-vmbr0}"
  VGA="${VGA:-vmware}"
  OSTYPE="${OSTYPE:-other}"
  ADD_TPM="${ADD_TPM:-false}"
  AFFINITY="${AFFINITY:-}"
  IGPU_ENABLE="${IGPU_ENABLE:-false}"
  IGPU_PCI="${IGPU_PCI:-}"
  IGPU_AUDIO="${IGPU_AUDIO:-}"
  IGPU_GMS="${IGPU_GMS:-0x2}"
  IGPU_ROM="${IGPU_ROM:-}"
  FIREWALL="${FIREWALL:-1}"
  DISK_SERIAL="${DISK_SERIAL:-}"
  MEM_SERIAL="${MEM_SERIAL:-}"
  MEM_ASSET="${MEM_ASSET:-}"
  MEM_EXPLICIT="${MEM_EXPLICIT:-false}"
  SMBIOS_BOARD_MFG="${SMBIOS_BOARD_MFG:-}"
  SMBIOS_BOARD_PRODUCT="${SMBIOS_BOARD_PRODUCT:-}"
  SMBIOS_BOARD_VERSION="${SMBIOS_BOARD_VERSION:-}"
  SMBIOS_BIOS_VENDOR="${SMBIOS_BIOS_VENDOR:-}"
  SMBIOS_BIOS_VERSION="${SMBIOS_BIOS_VERSION:-}"
  SMBIOS_BIOS_DATE="${SMBIOS_BIOS_DATE:-}"
  SMBIOS_BIOS_RELEASE="${SMBIOS_BIOS_RELEASE:-}"
  SMBIOS_CPU_MFG="${SMBIOS_CPU_MFG:-}"
  SMBIOS_CPU_VERSION="${SMBIOS_CPU_VERSION:-}"
  MEM_MFG="${MEM_MFG:-}"
  MEM_SPEED="${MEM_SPEED:-}"
  MEM_PART="${MEM_PART:-}"
  DRY_RUN="${DRY_RUN:-false}"
  DUMP_ARGS="${DUMP_ARGS:-false}"
  echo -e "${ID}${BOLD}${DGN}VM ID: ${BGN}${VMID}${CL}"
  echo -e "${NAME}${BOLD}${DGN}Name: ${BGN}${VM_NAME}${CL}"
  echo -e "${CPU}${BOLD}${DGN}Type: ${BGN}${VM_TYPE}${CL}"
  echo -e "${CREATING}${BOLD}${DGN}All other settings auto-detected from host${CL}"
}

# ─── Arg parsing ──────────────────────────────────────────────────────────────
function parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --vmid)         VMID="$2";              shift 2 ;;
      --name)         VM_NAME="$2";           shift 2 ;;
      --cores)        CORES="$2";             shift 2 ;;
      --threads)      THREADS="$2";           shift 2 ;;
      --memory)       MEMORY="$2";            shift 2 ;;
      --disk-size)    DISK_SIZE="$2";         shift 2 ;;
      --disk-storage) DISK_STORAGE="$2";      shift 2 ;;
      --iso-storage)  ISO_STORAGE="$2";       shift 2 ;;
      --iso)          ISO_FILE="$2";          shift 2 ;;
      --iso-type)     ISO_TYPE="$2";          shift 2 ;;
      --bridge)       BRIDGE="$2";            shift 2 ;;
      --type)         VM_TYPE="$2";           shift 2 ;;
      --vga)          VGA="$2";               shift 2 ;;
      --ostype)       OSTYPE="$2";            shift 2 ;;
      --mem-mfg)      MEM_MFG="$2"; MEM_EXPLICIT=true;  shift 2 ;;
      --mem-speed)    MEM_SPEED="$2"; MEM_EXPLICIT=true; shift 2 ;;
      --mem-part)     MEM_PART="$2"; MEM_EXPLICIT=true;  shift 2 ;;
      --mem-asset)    MEM_ASSET="$2"; MEM_EXPLICIT=true; shift 2 ;;
      --affinity)     AFFINITY="$2";          shift 2 ;;
      --tpm)          ADD_TPM=true;           shift   ;;
      --igpu)         IGPU_ENABLE=true;       shift   ;;
      --igpu-pci)     IGPU_PCI="$2";          shift 2 ;;
      --igpu-audio)   IGPU_AUDIO="$2";        shift 2 ;;
      --igpu-gms)     IGPU_GMS="$2";          shift 2 ;;
      --igpu-rom)     IGPU_ROM="$2";          shift 2 ;;
      --board-mfg)    SMBIOS_BOARD_MFG="$2";  shift 2 ;;
      --board-product) SMBIOS_BOARD_PRODUCT="$2"; shift 2 ;;
      --disk-serial)  DISK_SERIAL="$2";       shift 2 ;;
      --firewall)     FIREWALL="$2";          shift 2 ;;
      --help|-h)
        cat <<'HELPEOF'
Usage: pve-realpc-deploy-vm.sh [OPTIONS]

Deploys a fully cloaked Windows VM with patched QEMU 11/OVMF/KVM
anti-detection — matching upstream AICodo/pve-emu-realpc exactly.

VM Configuration:
  --vmid NUM           VM ID (default: next available)
  --name NAME          VM name (default: win10)
  --cores NUM          CPU cores (default: auto-detect from host)
  --threads NUM        Threads per core (default: auto-detect)
  --memory MB          Memory: 4096|8192|16384 (default: 16384)
  --disk-size SIZE     Disk size, e.g. 256G (default: 256G)
  --disk-storage NAME  Storage pool for disks (default: local-lvm)
  --iso-storage NAME   Storage pool for ISOs (default: local)
  --iso FILENAME       ISO filename (default: interactive picker)
  --iso-type TYPE      ISO filter: slim|stock
  --bridge NAME        Network bridge (default: vmbr0)
  --vga TYPE           VGA: std|vmware|none|virtio (default: vmware)
  --ostype TYPE        OS type (default: other — preserves S3/S4)
  --tpm                Add TPM 2.0 device
  --affinity RANGE     CPU affinity, e.g. 0-7
  --firewall 0|1       Enable firewall (default: 1)

iGPU Passthrough:
  --igpu               Enable iGPU passthrough (auto-detect vendor)
  --igpu-pci ADDR      iGPU PCI address (default: auto)
  --igpu-audio ADDR    Audio PCI address (default: auto)
  --igpu-gms HEX       Intel DVMT pre-alloc: 0x2=64M (default: 0x2)
  --igpu-rom FILE      ROM in /usr/share/kvm/ (default: auto)

Identity Spoofing:
  --type desktop|laptop  Desktop or laptop (virtual battery)
  --board-mfg NAME       Motherboard manufacturer
  --board-product NAME   Motherboard product
  --disk-serial SERIAL   20-char disk serial (default: random)
  --mem-mfg NAME         Memory manufacturer (enables full type=17)
  --mem-speed SPEED      Memory speed MT/s (enables full type=17)
  --mem-part PART        Memory part number (enables full type=17)
  --mem-asset ASSET      Memory asset tag (enables full type=17)

Meta:
  --dry-run             Show config and args without creating VM
  --dump-args           Print assembled QEMU args line and exit

Examples:
  bash pve-realpc-deploy-vm.sh
  bash pve-realpc-deploy-vm.sh --vmid 200 --cores 8 --memory 16384
  bash pve-realpc-deploy-vm.sh --iso-type slim --type laptop
  bash pve-realpc-deploy-vm.sh --igpu --igpu-gms 0x4
  bash pve-realpc-deploy-vm.sh --cores 24 --affinity 0-23
  bash pve-realpc-deploy-vm.sh --dry-run --cores 8 --vga std
HELPEOF
        exit 0
        ;;
      --dry-run)     DRY_RUN=true;           shift   ;;
      --dump-args)   DUMP_ARGS=true;         shift   ;;
      *) echo "Unknown: $1. Use --help."; exit 1 ;;
    esac
  done
}

# ─── Interactive flow ─────────────────────────────────────────────────────────
function start_script() {
  # Skip interactive if any meaningful CLI flags were passed (non-interactive mode)
  local cli_flags=0
  [[ "${CORES:-0}" != "0" ]] && ((cli_flags++))
  [[ "${MEMORY:-0}" != "0" && "${MEMORY:-0}" != "16384" ]] && ((cli_flags++))
  [[ -n "${ISO_FILE:-}" || -n "${ISO_TYPE:-}" ]] && ((cli_flags++))
  [[ -n "${VGA:-}" && "${VGA:-}" != "vmware" ]] && ((cli_flags++))
  [[ -n "${VM_NAME:-}" && "${VM_NAME:-}" != "win10" ]] && ((cli_flags++))
  [[ -n "${DISK_SIZE:-}" && "${DISK_SIZE:-}" != "256G" ]] && ((cli_flags++))
  if (( cli_flags >= 1 )); then
    echo -e "${DEFAULT}${BOLD}${BL}Using CLI-supplied settings${CL}"
    default_config
    return
  fi

  if whiptail --backtitle "PVE RealPC Deploy" --title "Setup Mode" \
    --yesno "This will create a Windows VM with full anti-VM-detection cloaking.\n\nQEMU 11 · OVMF · SMBIOS spoofing · ACPI · NVRAM injection\n\nUse Default settings?" --yes-button "Default" --no-button "Advanced" 14 70; then
    echo -e "${DEFAULT}${BOLD}${BL}Using Default Settings${CL}"
    default_config
  else
    echo -e "${ADVANCED}${BOLD}${MG}Using Advanced Settings${CL}"
    advanced_config
  fi
}

function advanced_config() {
  while true; do
    # --- VMID ---
    local default_vmid; default_vmid=$(get_valid_nextid)
    if VMID=$(whiptail --backtitle "PVE RealPC Deploy" --title "VM ID" \
      --inputbox "Virtual Machine ID" 8 58 "$default_vmid" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
      [[ -z "$VMID" ]] && VMID="$default_vmid"
      if qm status "$VMID" &>/dev/null || pct status "$VMID" &>/dev/null; then
        whiptail --title "ID In Use" --msgbox "ID $VMID is already in use by a VM or container." 8 50
        continue
      fi
      echo -e "${ID}${BOLD}${DGN}VM ID: ${BGN}${VMID}${CL}"
    else exit_script; fi

    # --- Name ---
    VM_NAME="${VM_NAME:-win10}"
    if VM_NAME=$(whiptail --backtitle "PVE RealPC Deploy" --title "VM Name" \
      --inputbox "VM Name" 8 58 "$VM_NAME" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
      [[ -z "$VM_NAME" ]] && VM_NAME="win10"
      echo -e "${NAME}${BOLD}${DGN}Name: ${BGN}${VM_NAME}${CL}"
    else exit_script; fi

    # --- Cores ---
    local total; total=$(nproc 2>/dev/null || echo "8")
    while true; do
      if CORES=$(whiptail --backtitle "PVE RealPC Deploy" --title "CPU Cores" \
        --inputbox "CPU Cores (physical cores, not threads)" 8 58 "$total" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
        if [[ "$CORES" =~ ^[1-9][0-9]*$ ]]; then break; fi
        whiptail --title "Invalid" --msgbox "Cores must be a positive integer." 8 40
      else exit_script; fi
    done
    echo -e "${CPU}${BOLD}${DGN}Cores: ${BGN}${CORES}${CL}"

    # --- Threads ---
    while true; do
      if THREADS=$(whiptail --backtitle "PVE RealPC Deploy" --title "Threads per Core" \
        --inputbox "Threads per core (1 or 2)" 8 58 "2" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
        if [[ "$THREADS" == "1" || "$THREADS" == "2" ]]; then break; fi
        whiptail --title "Invalid" --msgbox "Threads must be 1 or 2." 8 40
      else exit_script; fi
    done
    echo -e "${CPU}${BOLD}${DGN}Threads per core: ${BGN}${THREADS}${CL}"

    # --- Memory ---
    while true; do
      if MEMORY=$(whiptail --backtitle "PVE RealPC Deploy" --title "Memory" \
        --inputbox "RAM in MB (4096, 8192, or 16384 for realism)" 8 58 "16384" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
        if [[ "$MEMORY" =~ ^[0-9]+$ ]] && (( MEMORY >= 1024 )); then break; fi
        whiptail --title "Invalid" --msgbox "Memory must be >= 1024 MB." 8 40
      else exit_script; fi
    done
    echo -e "${DISK}${BOLD}${DGN}Memory: ${BGN}${MEMORY}MB${CL}"

    # --- Disk size ---
    DISK_SIZE="${DISK_SIZE:-256G}"
    if DISK_SIZE=$(whiptail --backtitle "PVE RealPC Deploy" --title "Disk Size" \
      --inputbox "Disk size (e.g. 256G, 1T)" 8 58 "$DISK_SIZE" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
      echo -e "${DISK}${BOLD}${DGN}Disk: ${BGN}${DISK_SIZE}${CL}"
    else exit_script; fi

    # --- VGA ---
    VGA="${VGA:-vmware}"
    if VGA=$(whiptail --backtitle "PVE RealPC Deploy" --title "VGA Type" --radiolist \
      "Display adapter" 12 58 4 \
      "vmware" "VMware Compatible (recommended)" ON \
      "std"    "Standard VGA" OFF \
      "virtio" "VirtIO-GPU" OFF \
      "none"   "None (GPU passthrough)" OFF \
      3>&1 1>&2 2>&3); then
      echo -e "${GPU}${BOLD}${DGN}VGA: ${BGN}${VGA}${CL}"
    else exit_script; fi

    # --- Type ---
    VM_TYPE="${VM_TYPE:-desktop}"
    if VM_TYPE=$(whiptail --backtitle "PVE RealPC Deploy" --title "System Type" --radiolist \
      "Desktop = no battery, Laptop = virtual battery (NVIDIA error 43 fix)" 10 58 2 \
      "desktop" "Desktop" ON \
      "laptop"  "Laptop" OFF \
      3>&1 1>&2 2>&3); then
      echo -e "${BOARD}${BOLD}${DGN}Type: ${BGN}${VM_TYPE}${CL}"
    else exit_script; fi

    # --- Bridge ---
    BRIDGE="${BRIDGE:-vmbr0}"
    if BRIDGE=$(whiptail --backtitle "PVE RealPC Deploy" --title "Network Bridge" \
      --inputbox "Bridge interface" 8 58 "$BRIDGE" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
      [[ -z "$BRIDGE" ]] && BRIDGE="vmbr0"
      echo -e "${NET}${BOLD}${DGN}Bridge: ${BGN}${BRIDGE}${CL}"
    else exit_script; fi

    # --- Firewall ---
    if whiptail --backtitle "PVE RealPC Deploy" --title "Firewall" \
      --yesno "Enable PVE firewall on the NIC?" 8 58; then
      FIREWALL=1; echo -e "${SEC}${BOLD}${DGN}Firewall: ${BGN}On${CL}"
    else
      FIREWALL=0; echo -e "${SEC}${BOLD}${DGN}Firewall: ${BGN}Off${CL}"
    fi

    # --- iGPU ---
    if whiptail --backtitle "PVE RealPC Deploy" --title "iGPU Passthrough" \
      --yesno "Enable iGPU passthrough?\n\nAuto-detects Intel or AMD iGPU.\n(Overrides VGA to 'none'.)" --defaultno 10 58; then
      IGPU_ENABLE=true
      echo -e "${GPU}${BOLD}${DGN}iGPU: ${BGN}Enabled${CL}"
    else
      echo -e "${GPU}${BOLD}${DGN}iGPU: ${BGN}Disabled${CL}"
    fi

    # --- OSType ---
    OSTYPE="${OSTYPE:-other}"
    if OSTYPE=$(whiptail --backtitle "PVE RealPC Deploy" --title "OS Type" --radiolist \
      "Guest OS type (recommended: other — preserves S3/S4 sleep)" 14 58 4 \
      "other"  "Other (default — no S3/S4 injection)" ON \
      "win11"  "Windows 11" OFF \
      "win10"  "Windows 10" OFF \
      "l26"    "Linux 2.6 (upstream uses this)" OFF \
      3>&1 1>&2 2>&3); then
      echo -e "${BOOT}${BOLD}${DGN}OS Type: ${BGN}${OSTYPE}${CL}"
    else exit_script; fi

    # --- Disk storage ---
    DISK_STORAGE="${DISK_STORAGE:-local-lvm}"
    if DISK_STORAGE=$(whiptail --backtitle "PVE RealPC Deploy" --title "Disk Storage" \
      --inputbox "Storage pool for VM disks" 8 58 "$DISK_STORAGE" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
      [[ -z "$DISK_STORAGE" ]] && DISK_STORAGE="local-lvm"
      echo -e "${DISK}${BOLD}${DGN}Disk Storage: ${BGN}${DISK_STORAGE}${CL}"
    else exit_script; fi

    # --- ISO storage ---
    ISO_STORAGE="${ISO_STORAGE:-local}"
    if ISO_STORAGE=$(whiptail --backtitle "PVE RealPC Deploy" --title "ISO Storage" \
      --inputbox "Storage pool for ISO files" 8 58 "$ISO_STORAGE" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
      [[ -z "$ISO_STORAGE" ]] && ISO_STORAGE="local"
      echo -e "${DISK}${BOLD}${DGN}ISO Storage: ${BGN}${ISO_STORAGE}${CL}"
    else exit_script; fi

    # --- TPM ---
    if whiptail --backtitle "PVE RealPC Deploy" --title "TPM 2.0" \
      --yesno "Add TPM 2.0 device?\n\n(Not included in upstream defaults — optional.)" --defaultno 8 58; then
      ADD_TPM=true; echo -e "${SEC}${BOLD}${DGN}TPM: ${BGN}Enabled${CL}"
    else
      ADD_TPM=false; echo -e "${SEC}${BOLD}${DGN}TPM: ${BGN}Disabled${CL}"
    fi

    # --- Confirm ---
    if whiptail --backtitle "PVE RealPC Deploy" --title "Ready" \
      --yesno "Create VM ${VMID} (${VM_NAME}) with these settings?\n\n  ${CORES} cores × ${THREADS} threads  ·  ${MEMORY}MB RAM  ·  ${DISK_SIZE} disk\n  VGA: ${VGA}  ·  Type: ${VM_TYPE}  ·  Bridge: ${BRIDGE}  ·  Firewall: $([ "$FIREWALL" = 1 ] && echo On || echo Off)\n  iGPU: $(${IGPU_ENABLE} && echo Enabled || echo Disabled)  ·  TPM: $(${ADD_TPM} && echo Yes || echo No)  ·  OS: ${OSTYPE}" \
      --yes-button "Create" --no-button "Redo" 16 70; then
      break
    fi
  done
}

# ─── Build QEMU args ──────────────────────────────────────────────────────────
function build_args() {
  # Builds FULL_ARGS, IGPU_ARGS, PCI_ARGS, ACPI_ARGS, CPU_FLAGS as globals

  # ACPI tables
  ACPI_ARGS="-acpitable file=/root/ssdt.aml -acpitable file=/root/ssdt-ec.aml -acpitable file=/root/hpet.aml"
  if [[ "$VM_TYPE" == "laptop" ]]; then
    ACPI_ARGS="-acpitable file=/root/ssdt-battery.aml -acpitable file=/root/ssdt-ec.aml -acpitable file=/root/hpet.aml"
    echo -e "${ACPI}${BOLD}${DGN}Laptop mode — ssdt-battery.aml (virtual battery)${CL}"
  fi
  [[ -f "/root/pit.aml" ]] && ACPI_ARGS+=" -acpitable file=/root/pit.aml"

  # CPU flags — match upstream exactly
  CPU_FLAGS="host,host-cache-info=on,hypervisor=off,vmware-cpuid-freq=false,enforce=false,host-phys-bits=true"
  echo -e "${SEC}${BOLD}${DGN}CPU: ${BGN}${CPU_FLAGS}${CL}"

  # SMBIOS
  local smb=""
  smb+=" -smbios type=0,vendor=\"$(qemu_escape_commas "${SMBIOS_BIOS_VENDOR}")\",version=${SMBIOS_BIOS_VERSION},date='${SMBIOS_BIOS_DATE}',release=${SMBIOS_BIOS_RELEASE}"
  smb+=" -smbios type=1,manufacturer=\"$(qemu_escape_commas "${SMBIOS_BOARD_MFG}")\",product=\"$(qemu_escape_commas "${SMBIOS_BOARD_PRODUCT}")\",version=\"$(qemu_escape_commas "${SMBIOS_BOARD_VERSION}")\",serial=\"Default string\",sku=\"Default string\",family=\"Default string\""
  smb+=" -smbios type=2,manufacturer=\"$(qemu_escape_commas "${SMBIOS_BOARD_MFG}")\",product=\"$(qemu_escape_commas "${SMBIOS_BOARD_PRODUCT}")\",version=\"$(qemu_escape_commas "${SMBIOS_BOARD_VERSION}")\",serial=\"Default string\",asset=\"Default string\",location=\"Default string\""
  smb+=" -smbios type=3,manufacturer=\"Default string\",version=\"Default string\",serial=\"Default string\",asset=\"Default string\",sku=\"Default string\""
  if [[ "$MEM_EXPLICIT" == true ]]; then
    smb+=" -smbios type=17,loc_pfx=\"Controller0-ChannelA-DIMM\",manufacturer=\"$(qemu_escape_commas "${MEM_MFG}")\",speed=${MEM_SPEED},serial=${MEM_SERIAL},part=\"${MEM_PART}\",bank=\"BANK 0\",asset=\"${MEM_ASSET}\""
  else
    smb+=" -smbios type=17,serial=${MEM_SERIAL},asset=\"${MEM_ASSET}\""
  fi
  smb+=" -smbios type=4,manufacturer=\"$(qemu_escape_commas "${SMBIOS_CPU_MFG}")\",version=\"$(qemu_escape_commas "${SMBIOS_CPU_VERSION}")\""
  smb+=" -smbios type=9"
  smb+=" -smbios type=8 -smbios type=8"

  echo -e "${SEC}${BOLD}${DGN}SMBIOS: types 0,1,2,3,4,8,9,17 (+ auto 7,20,26,27 in QEMU 11)${CL}"

  # iGPU args
  IGPU_ARGS=""
  if [[ "$IGPU_ENABLE" == true ]]; then
    if [[ "$VGA" != "none" ]]; then
      msg_warn "iGPU enabled — overriding --vga '${VGA}' to 'none' (physical GPU replaces virtual)"
    fi
    VGA="none"
    local igpu_info
    igpu_info=$(detect_igpu "$IGPU_PCI" "$IGPU_ROM")
    IFS=: read -r IGPU_VENDOR IGPU_PCI IGPU_AUDIO IGPU_ROM <<< "$igpu_info"

    if [[ -n "$IGPU_ROM" ]] && [[ ! -f "/usr/share/kvm/${IGPU_ROM}" ]]; then
      msg_error "iGPU ROM not found: /usr/share/kvm/${IGPU_ROM}. Run pve-realpc-setup.sh --igpu first."; exit 1
    fi

    if [[ "$IGPU_VENDOR" == "intel" ]]; then
      IGPU_ARGS=" -set device.hostpci0.addr=02.0"
      IGPU_ARGS+=" -set device.hostpci0.x-igd-gms=${IGPU_GMS}"
      IGPU_ARGS+=" -set device.hostpci0.x-igd-opregion=on"
      IGPU_ARGS+=" -set device.hostpci0.x-igd-legacy-mode=on"
      echo -e "${GPU}${BOLD}${DGN}Intel IGD: opregion=on GMS=${IGPU_GMS}${CL}"
    else
      echo -e "${GPU}${BOLD}${DGN}AMD iGPU — standard PCI passthrough${CL}"
    fi
  fi

  # PCI globals: S3/S4 sleep + hotplug disable
  PCI_ARGS=" -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off"
  PCI_ARGS+=" -global ICH9-LPC.disable_s3=0"
  PCI_ARGS+=" -global ICH9-LPC.disable_s4=0"
  echo -e "${SEC}${BOLD}${DGN}S3/S4 sleep enabled · ACPI hotplug disabled${CL}"

  FULL_ARGS="${ACPI_ARGS} -cpu ${CPU_FLAGS}${smb}${IGPU_ARGS}${PCI_ARGS}"
}

# ─── NVRAM injection ──────────────────────────────────────────────────────────
function inject_nvram() {
  local vmid="$1"
  NVRAM_INJECTED=false

  if ! command -v virt-fw-vars &>/dev/null || [[ ! -d /sys/firmware/efi/efivars ]]; then
    if ! command -v virt-fw-vars &>/dev/null; then
      msg_warn "virt-fw-vars not found — install python3-virt-firmware for NVRAM protection"
    fi
    if [[ ! -d /sys/firmware/efi/efivars ]]; then
      msg_warn "Host not UEFI-booted — cannot extract EFI variables"
    fi
    return
  fi

  msg_info "Injecting host EFI variables into VM NVRAM"

  local efidisk_path efidisk_vol
  efidisk_vol=$(grep -oP 'efidisk0:\s*\K[^,]+' "/etc/pve/qemu-server/${vmid}.conf" 2>/dev/null || true)
  [[ -z "$efidisk_vol" ]] && { msg_warn "Could not resolve EFI disk path"; return; }
  efidisk_path=$(pvesm path "$efidisk_vol" 2>/dev/null || true)
  [[ -z "$efidisk_path" ]] && { msg_warn "Could not resolve EFI disk path"; return; }

  local backup="/root/pve-realpc/efidisk-${vmid}-pristine.qcow2"
  cp "$efidisk_path" "$backup" 2>/dev/null || true

  local work="/tmp/pve-nvram-${vmid}"
  mkdir -p "$work"
  local json="${work}/efivars.json" orig="${work}/OVMF_VARS.fd" new="${work}/OVMF_VARS_injected.fd"

  local fmt; fmt=$(qemu-img info --output=json "$efidisk_path" 2>/dev/null | grep -oP '"format":\s*"\K[^"]+' || echo "qcow2")
  qemu-img convert -f "$fmt" -O raw "$efidisk_path" "$orig" 2>/dev/null || cp "$efidisk_path" "$orig" 2>/dev/null || true

  if [[ -f "$orig" ]]; then
    local g1=8be4df61-93ca-11d2-aa0d-00e098032b8c g2=d719b2cb-3d3a-4596-a3bc-dad00e67656f
    {
      printf '{\n    "version": 2,\n    "variables": [\n'
      local first=true
      for entry in "PK:${g1}" "KEK:${g1}" "db:${g2}" "dbx:${g2}" "PKDefault:${g1}" "KEKDefault:${g1}" "dbDefault:${g1}" "dbxDefault:${g1}"; do
        IFS=: read -r name guid <<< "$entry"
        local path="/sys/firmware/efi/efivars/${name}-${guid}"
        [[ -f "$path" ]] || continue
        local full_hex; full_hex=$(hexdump -ve '1/1 "%.2x"' "$path" 2>/dev/null) || continue
        [[ ${#full_hex} -ge 8 ]] || continue
        local attr; attr=$(printf '%d' "0x${full_hex:6:2}${full_hex:4:2}${full_hex:2:2}${full_hex:0:2}" 2>/dev/null) || continue
        "$first" && first=false || printf ',\n'
        printf '        { "name": "%s", "guid": "%s", "attr": %d, "data": "%s" }' "$name" "$guid" "$attr" "${full_hex:8}"
      done
      printf '\n    ]\n}\n'
    } > "$json"

    local count; count=$(grep -c '"name"' "$json" 2>/dev/null || echo "0")
    if [[ "$count" -ge 2 ]]; then
      virt-fw-vars --input "$orig" --output "$new" --secure-boot --set-json "$json" 2>/dev/null || true
      if [[ -f "$new" ]]; then
        local nsz osz; nsz=$(stat -c%s "$new" 2>/dev/null || echo "0"); osz=$(stat -c%s "$orig" 2>/dev/null || echo "0")
        if [[ "$nsz" -ge 131072 ]] && [[ "$nsz" -le $((osz + 4096)) ]] && [[ "$nsz" -ge $((osz - 4096)) ]] \
           && virt-fw-vars --input "$new" --print >/dev/null 2>&1; then
          if qemu-img convert -f raw -O "$fmt" "$new" "${efidisk_path}.new" 2>/dev/null; then
            mv -f "${efidisk_path}.new" "$efidisk_path"
            NVRAM_INJECTED=true
            msg_ok "Host EFI variables injected (${count} keys: PK, KEK, db, dbx, defaults)"
          else rm -f "${efidisk_path}.new"; fi
        else
          msg_warn "NVRAM injection failed validation — keeping pristine image"
          cp "$backup" "$efidisk_path" 2>/dev/null || true
        fi
      fi
    else
      msg_warn "Only ${count} EFI variables extracted — host Secure Boot may be off"
    fi
  fi
  rm -rf "$work"
  if [[ -f "$backup" ]]; then
    msg_ok "Pristine OVMF_VARS preserved at ${backup} (delete after first boot)"
  fi

  if [[ "$NVRAM_INJECTED" != true ]]; then
    msg_warn "NVRAM injection skipped — VM may fail VMAware NVRAM check (100pts)"
  fi
}

# ─── Disk size parser ─────────────────────────────────────────────────────────
function parse_disk_size_gb() {
  local input="${1,,}"
  case "$input" in
    *tib) echo $(( ${input%tib} * 1024 )) ;;
    *tb)  echo $(( ${input%tb}  * 1024 )) ;;
    *t)   echo $(( ${input%t}   * 1024 )) ;;
    *gib) echo "${input%gib}" ;;
    *gb)  echo "${input%gb}"  ;;
    *g)   echo "${input%g}"   ;;
    *mib) echo $(( ${input%mib} / 1024 )) ;;
    *mb)  echo $(( ${input%mb}  / 1024 )) ;;
    *m)   echo $(( ${input%m}   / 1024 )) ;;
    *[0-9]) echo "$input" ;;
    *) echo "0" ;;
  esac
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════
check_root
arch_check
pve_check
ssh_check
parse_args "$@"
start_script

# --- Validate ---
validate_prerequisites

case "$VM_TYPE" in desktop|laptop) ;; *) msg_error "Invalid --type '${VM_TYPE}'. Use: desktop | laptop"; exit 1 ;; esac
case "$VGA" in std|vmware|none|virtio) ;; *) msg_error "Invalid --vga '${VGA}'."; exit 1 ;; esac

ISO_TYPE=$(echo "$ISO_TYPE" | tr '[:upper:]' '[:lower:]')

if [[ "$MEMORY" != "4096" && "$MEMORY" != "8192" && "$MEMORY" != "16384" ]]; then
  msg_warn "Memory ${MEMORY}MB is non-standard. Realistic: 4096, 8192, 16384."
fi

# Ostype — warn if l26/win10/win11 (PVE injects disable_s3/s4 but our -global overrides)
if [[ "$OSTYPE" != "other" ]]; then
  msg_warn "OSTYPE '${OSTYPE}' may cause PVE to inject disable_s3/s4 globals."
  msg_warn "Our args line overrides these — S3/S4 should still work."
  msg_warn "Recommended: --ostype other (default)."
fi

# --- Storage ---
DISK_STORAGE=$(pick_storage "images" "$DISK_STORAGE" "disk")
ISO_STORAGE=$(pick_storage "iso" "$ISO_STORAGE" "ISO")

# --- ISO ---
if [[ -z "$ISO_FILE" ]]; then
  ISO_PATH=$(resolve_iso_path "$ISO_STORAGE")
  if [[ -d "$ISO_PATH" ]]; then
    ISO_FILE=$(pick_iso "$ISO_PATH" "$ISO_FILE" "$ISO_TYPE" "$VMID" "$ISO_STORAGE")
  else
    msg_warn "ISO directory ${ISO_PATH} not found — attach ISO manually after deploy."
    ISO_FILE=""
  fi
fi

# --- CPU vendor & SMBIOS ---
HOST_CPU_VENDOR=$(detect_cpu_vendor)
apply_smbios_profile "$HOST_CPU_VENDOR"
SMBIOS_CPU_VERSION="${SMBIOS_CPU_VERSION:-$(detect_cpu_version "$HOST_CPU_VENDOR")}"
echo -e "${CPU}${BOLD}${DGN}CPU version string: ${BGN}${SMBIOS_CPU_VERSION}${CL}"

# --- Topology ---
TOPOLOGY=$(detect_topology "$CORES" "$THREADS")
IFS=: read -r CORES THREADS SMP_TOTAL <<< "$TOPOLOGY"

# --- Random IDs ---
DISK_SERIAL="${DISK_SERIAL:-$(random_serial_20)}"
MEM_SERIAL="${MEM_SERIAL:-$(random_hex 8)}"
if [[ -z "$MEM_ASSET" ]]; then
  MEM_ASSET=$(LC_ALL=C tr -dc '0-9' </dev/urandom | head -c 10)
  _mt=0
  while [[ ${#MEM_ASSET} -lt 10 && _mt -lt 20 ]]; do
    MEM_ASSET="$(LC_ALL=C tr -dc '1-9' </dev/urandom | head -c 1)${MEM_ASSET}"; ((_mt++))
  done
  [[ ${#MEM_ASSET} -lt 10 ]] && MEM_ASSET="${MEM_ASSET}$(printf '%010d' "$((RANDOM * RANDOM))")" && MEM_ASSET="${MEM_ASSET:0:10}"
fi
echo -e "${DISK}${BOLD}${DGN}Disk serial: ${BGN}${DISK_SERIAL}${CL}"
echo -e "${DISK}${BOLD}${DGN}Memory serial: ${BGN}${MEM_SERIAL}${CL}  asset: ${BGN}${MEM_ASSET}${CL}"

# --- Build QEMU args ---
build_args

# --- Dry-run: show config and exit ---
if [[ "$DRY_RUN" == true ]]; then
  echo ""
  echo -e "${BOLD}${GN}╔════════════════════ DRY RUN ════════════════════╗${CL}"
  echo -e "${BOLD}${GN}║${CL}  No VM will be created. Config preview:         ${BOLD}${GN}║${CL}"
  echo -e "${BOLD}${GN}╠══════════════════════════════════════════════════╣${CL}"
  echo -e "${BOLD}${GN}║${CL}  VMID:      ${VMID}"
  echo -e "${BOLD}${GN}║${CL}  Name:      ${VM_NAME}"
  echo -e "${BOLD}${GN}║${CL}  Topology:  ${SMP_TOTAL} vCPUs (${CORES}c × ${THREADS}t)"
  echo -e "${BOLD}${GN}║${CL}  Memory:    ${MEMORY}MB  ·  Disk: ${DISK_SIZE} on ${DISK_STORAGE}"
  echo -e "${BOLD}${GN}║${CL}  VGA:       ${VGA}  ·  NIC: e1000 on ${BRIDGE}"
  echo -e "${BOLD}${GN}║${CL}  Type:      ${VM_TYPE}  ·  OS: ${OSTYPE}"
  echo -e "${BOLD}${GN}║${CL}  Board:     ${SMBIOS_BOARD_MFG} ${SMBIOS_BOARD_PRODUCT}"
  echo -e "${BOLD}${GN}║${CL}  CPU:       ${SMBIOS_CPU_VERSION}"
  echo -e "${BOLD}${GN}║${CL}  ISO:       ${ISO_FILE:-none}"
  [[ "$ADD_TPM" == true ]] && echo -e "${BOLD}${GN}║${CL}  TPM:       enabled"
  [[ "$IGPU_ENABLE" == true ]] && echo -e "${BOLD}${GN}║${CL}  iGPU:      ${IGPU_VENDOR:-?} ${IGPU_PCI:-}"
  [[ -n "$AFFINITY" ]] && echo -e "${BOLD}${GN}║${CL}  Affinity:  ${AFFINITY}"
  echo -e "${BOLD}${GN}╠══════════════════════════════════════════════════╣${CL}"
  echo -e "${BOLD}${GN}║${CL}  args:"
  echo "$FULL_ARGS" | fold -s -w 64 | while read -r line; do
    printf "${BOLD}${GN}║${CL}  ${DIM}%s${CL}\n" "$line"
  done
  echo -e "${BOLD}${GN}╚══════════════════════════════════════════════════╝${CL}"
  echo ""
  CLEANUP_VMID=""
  trap - ERR EXIT
  exit 0
fi

# --- Dump-args: print args line and exit ---
if [[ "$DUMP_ARGS" == true ]]; then
  echo "$FULL_ARGS"
  CLEANUP_VMID=""
  trap - ERR EXIT
  exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════════
# CREATE VM
# ═══════════════════════════════════════════════════════════════════════════════
header_info
echo -e "${ID}${BOLD}VM ${VMID} · ${VM_NAME} · ${VM_TYPE} · VGA: ${VGA}${CL}"

msg_info "Creating VM ${VMID}"

# qm create (cores = total vCPUs; --threads not accepted by qm create on some PVE builds)
qm create "$VMID" \
  --name "$VM_NAME" --bios ovmf --machine q35 --ostype "$OSTYPE" --cpu host \
  --sockets 1 --cores "$SMP_TOTAL" --memory "$MEMORY" \
  --balloon 0 --numa 0 --scsihw virtio-scsi-single \
  --net0 "e1000,bridge=${BRIDGE},firewall=${FIREWALL}" \
  --vga "$VGA" --localtime 1
msg_ok "VM ${VMID} created"

# Set proper topology via qm set (--threads always supported here)
if [[ "$THREADS" -gt 1 ]]; then
  qm set "$VMID" --sockets 1 --cores "$CORES" --threads "$THREADS"
  msg_ok "Topology set: ${CORES}c × ${THREADS}t (${SMP_TOTAL} vCPUs)"
fi

# Arm rollback
CLEANUP_VMID="$VMID"

# SMBIOS1 + vmgenid
SYS_UUID=$(cat /proc/sys/kernel/random/uuid)
SMBIOS1_LINE="uuid=${SYS_UUID}"
VMGENID=$(cat /proc/sys/kernel/random/uuid)
echo -e "${SEC}${BOLD}${DGN}UUID: ${BGN}${SYS_UUID}${CL}"

# EFI disk
msg_info "Adding EFI disk"
qm set "$VMID" --efidisk0 "${DISK_STORAGE}:1,efitype=4m"
msg_ok "EFI disk added (efitype=4m, no pre-enrolled-keys)"

# NVRAM injection
inject_nvram "$VMID"

# TPM 2.0 (optional)
if [[ "$ADD_TPM" == true ]]; then
  msg_info "Adding TPM 2.0"
  qm set "$VMID" --tpmstate0 "${DISK_STORAGE}:1,version=v2.0"
  msg_ok "TPM 2.0 added"
fi

# iGPU passthrough
if [[ "$IGPU_ENABLE" == true ]]; then
  msg_info "Adding iGPU passthrough"
  if [[ -n "$IGPU_ROM" ]]; then
    qm set "$VMID" --hostpci0 "${IGPU_PCI},romfile=${IGPU_ROM}"
  else
    qm set "$VMID" --hostpci0 "${IGPU_PCI}"
  fi
  [[ -n "$IGPU_AUDIO" ]] && qm set "$VMID" --hostpci1 "${IGPU_AUDIO}"
  msg_ok "${IGPU_VENDOR^^} iGPU passthrough configured"
fi

# SATA disk
msg_info "Adding SATA disk"
DISK_SIZE_GB=$(parse_disk_size_gb "$DISK_SIZE")
[[ "$DISK_SIZE_GB" =~ ^[0-9]+$ ]] || { msg_error "Could not parse disk size: ${DISK_SIZE}"; exit 1; }
(( DISK_SIZE_GB >= 32 )) || { msg_error "Disk size ${DISK_SIZE_GB}GB too small (min 32G, 128G+ recommended)"; exit 1; }
qm set "$VMID" --sata0 "${DISK_STORAGE}:${DISK_SIZE_GB},ssd=1,serial=${DISK_SERIAL}"
msg_ok "SATA disk: ${DISK_SIZE_GB}GB (serial: ${DISK_SERIAL})"

# ISO
if [[ -n "$ISO_FILE" ]]; then
  msg_info "Attaching ISO"
  qm set "$VMID" --ide2 "${ISO_STORAGE}:iso/${ISO_FILE},media=cdrom"
  qm set "$VMID" --boot "order=ide2;sata0;net0"
  msg_ok "ISO attached: ${ISO_FILE}"
else
  qm set "$VMID" --boot "order=sata0;net0"
  msg_ok "Boot order: sata0;net0"
fi

# ─── Write args to conf ───────────────────────────────────────────────────────
msg_info "Writing anti-detection config"
CONF_FILE="/etc/pve/qemu-server/${VMID}.conf"
TMP_CONF=$(mktemp /tmp/pve-vm-XXXXXX.conf)
{
  echo "args: ${FULL_ARGS}"
  echo "smbios1: ${SMBIOS1_LINE}"
  echo "vmgenid: ${VMGENID}"
  [[ -n "$AFFINITY" ]] && echo "affinity: ${AFFINITY}"
  grep -vE '^(args|smbios1|vmgenid|affinity):' "$CONF_FILE" 2>/dev/null || true
} > "$TMP_CONF"
cp "$TMP_CONF" "$CONF_FILE"
rm -f "$TMP_CONF"
msg_ok "Anti-detection args written to config"

# ═══════════════════════════════════════════════════════════════════════════════
# FINAL DISPLAY
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}${GN}╔══════════════════════════════════════════════════════════════════╗${CL}"
echo -e "${BOLD}${GN}║${CL}  ${BOLD}VM ${VMID} (${VM_NAME}) deployed successfully!${CL}                               ${BOLD}${GN}║${CL}"
echo -e "${BOLD}${GN}╠══════════════════════════════════════════════════════════════════╣${CL}"
echo -e "${BOLD}${GN}║${CL}  ${BOLD}Anti-Detection Layers Active:${CL}                                    ${BOLD}${GN}║${CL}"
echo -e "${BOLD}${GN}║${CL}    ${GN}✓${CL} OVMF + Q35 (patched Strong firmware)                           ${BOLD}${GN}║${CL}"
echo -e "${BOLD}${GN}║${CL}    ${GN}✓${CL} SMBIOS spoofing (types 0,1,2,3,4,8,9,17 + auto 7,20,26,27)  ${BOLD}${GN}║${CL}"
echo -e "${BOLD}${GN}║${CL}    ${GN}✓${CL} ACPI: ssdt + ssdt-ec + hpet + pit                             ${BOLD}${GN}║${CL}"
echo -e "${BOLD}${GN}║${CL}    ${GN}✓${CL} CPU: host,hypervisor=off (binary hides KVM)                    ${BOLD}${GN}║${CL}"
printf "${BOLD}${GN}║${CL}    ${GN}✓${CL} %-60s ${BOLD}${GN}║${CL}\n" "Topology: ${SMP_TOTAL} vCPUs (${CORES}c × ${THREADS}t)"
echo -e "${BOLD}${GN}║${CL}    ${GN}✓${CL} S3/S4 sleep + PIT SSDT (POWER + CLOCK 45pts each)             ${BOLD}${GN}║${CL}"
if [[ "$NVRAM_INJECTED" == true ]]; then
  echo -e "${BOLD}${GN}║${CL}    ${GN}✓${CL} EFI NVRAM: host Secure Boot certs injected                     ${BOLD}${GN}║${CL}"
fi
echo -e "${BOLD}${GN}║${CL}    ${GN}✓${CL} e1000 NIC (Intel 82540EM) + SATA disk (custom serial)          ${BOLD}${GN}║${CL}"
echo -e "${BOLD}${GN}║${CL}    ${GN}✓${CL} Balloon disabled · ACPI hotplug off · Timers: binary-handled   ${BOLD}${GN}║${CL}"
[[ -n "$AFFINITY" ]] && printf "${BOLD}${GN}║${CL}    ${GN}✓${CL} %-60s ${BOLD}${GN}║${CL}\n" "CPU affinity: ${AFFINITY}"
[[ "$ADD_TPM" == true ]] && echo -e "${BOLD}${GN}║${CL}    ${GN}✓${CL} TPM 2.0 emulation                                              ${BOLD}${GN}║${CL}"
if [[ "$IGPU_ENABLE" == true ]]; then
  printf "${BOLD}${GN}║${CL}    ${GN}✓${CL} %-60s ${BOLD}${GN}║${CL}\n" "${IGPU_VENDOR^^} iGPU passthrough (${IGPU_ROM:-no ROM})"
  [[ "$IGPU_VENDOR" == "intel" ]] && printf "${BOLD}${GN}║${CL}    ${GN}✓${CL} %-60s ${BOLD}${GN}║${CL}\n" "IGD: opregion=on, GMS=${IGPU_GMS}"
fi
echo -e "${BOLD}${GN}║${CL}                                                                  ${BOLD}${GN}║${CL}"
echo -e "${BOLD}${GN}╠══════════════════════════════════════════════════════════════════╣${CL}"
echo -e "${BOLD}${GN}║${CL}  ${BOLD}Start:${CL}  qm start ${VMID}                                               ${BOLD}${GN}║${CL}"
echo -e "${BOLD}${GN}║${CL}  ${BOLD}Config:${CL} cat /etc/pve/qemu-server/${VMID}.conf                          ${BOLD}${GN}║${CL}"
printf "${BOLD}${GN}║${CL}  ${DIM}%-56s${NC} ${BOLD}${GN}║${CL}\n" "Post-Install: run windows\\run-tools.bat in guest"
echo -e "${BOLD}${GN}║${CL}  ${DIM}Test: pafish64.exe · al-khaser · VMAware${CL}                           ${BOLD}${GN}║${CL}"
echo -e "${BOLD}${GN}╚══════════════════════════════════════════════════════════════════╝${CL}"

# ─── Summary file ─────────────────────────────────────────────────────────────
SUMMARY="/root/vm-${VMID}-deploy-summary.txt"
{
  echo "=== VM ${VMID} (${VM_NAME}) — Deployment Summary ==="
  echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
  echo ""
  echo "--- SMBIOS ---"
  echo "Board: ${SMBIOS_BOARD_MFG} ${SMBIOS_BOARD_PRODUCT} (${SMBIOS_BOARD_VERSION})"
  echo "BIOS:  ${SMBIOS_BIOS_VENDOR} v${SMBIOS_BIOS_VERSION} (${SMBIOS_BIOS_DATE}, r${SMBIOS_BIOS_RELEASE})"
  echo "CPU:   ${SMBIOS_CPU_MFG} — ${SMBIOS_CPU_VERSION}"
  echo "UUID:  ${SYS_UUID}"
  echo "Disk:  ${DISK_SERIAL}"
  echo "Mem:   ${MEM_MFG} ${MEM_SPEED}MT/s ${MEM_PART} S/N:${MEM_SERIAL} A/T:${MEM_ASSET}"
  echo ""
  echo "--- Hardware ---"
  echo "Topology: ${SMP_TOTAL} vCPUs (${CORES}c × ${THREADS}t, 1 socket)"
  echo "Memory:   ${MEMORY}MB  ·  Disk: ${DISK_SIZE} on ${DISK_STORAGE}"
  echo "VGA:      ${VGA}  ·  NIC: e1000 on ${BRIDGE}"
  echo "ISO:      ${ISO_FILE:-none}"
  [[ -n "$AFFINITY" ]] && echo "Affinity: ${AFFINITY}"
  [[ "$IGPU_ENABLE" == true ]] && echo "iGPU:     ${IGPU_VENDOR^^} ${IGPU_PCI} (ROM: ${IGPU_ROM:-none})"
  echo ""
  echo "--- Config ---"
  cat "$CONF_FILE"
} > "$SUMMARY"
echo -e "\n${INFO}${BOLD}Summary saved: ${BGN}${SUMMARY}${CL}"

CLEANUP_VMID=""
trap - ERR EXIT
