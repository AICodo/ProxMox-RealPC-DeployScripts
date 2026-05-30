#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
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
#  10. iGPU passthrough setup — Intel or AMD (optional, --igpu)
#  11. Package pinning (prevent apt from overwriting patched QEMU/OVMF)
#  12. Verification of installation
#
# Usage:   bash pve-realpc-setup.sh                    # interactive whiptail menu (default when stdin is a TTY)
#          bash pve-realpc-setup.sh --list-releases    # dump resolved upstream releases and exit
#          bash pve-realpc-setup.sh --non-interactive  # CI: auto-pick latest base + Strong, no prompts
#          bash pve-realpc-setup.sh --help             # full flag reference
#
# Common overrides:
#   --no-strong / --skip-pin / --skip-kernel-downgrade / --skip-download / --igpu
#   --release-tag TAG / --strong-tag TAG / --debian-tag TAG
#
# Requires: root on a Proxmox VE 9 host, internet access (for downloads & API resolver)
###############################################################################
set -euo pipefail
IFS=$'\n\t'

# ─── Tunables ────────────────────────────────────────────────────────────────
# Upstream intentionally splits releases:
#   - The newest PVE9 tag (resolved live from GitHub API; v20260530-111870-pve9 /
#     v11.0.0-4 as of this writing) ships only the base .deb + ACPI + patch.
#     NO Strong .tgz, NO matching kvm.ko.
#   - The previous "enhanced" tag (v20260506-222829-pve9 / v11.0.0-1) ships
#     the same base files PLUS the Strong .tgz (sensor passthrough +
#     kvm.ko built against kernel 6.17.13-2).
# The qemu-autoGenPatch.patch is byte-for-byte identical between the two —
# so we pull base assets from the latest tag and overlay Strong from the
# enhanced tag. Use --no-strong to skip Strong entirely (no sensor passthrough,
# but you also avoid the kernel-version pin to 6.17.13-2).
# Upstream repo (used by both the help heredoc below and the GitHub-API resolver).
UPSTREAM_REPO="AICodo/pve-emu-realpc"
RELEASE_TAG="v20260530-111870-pve9"   # static fallback — resolver auto-picks newest at runtime
STRONG_TAG="v20260506-222829-pve9"    # last release shipping the Strong .tgz
BASE_URL="https://github.com/${UPSTREAM_REPO}/releases/download/${RELEASE_TAG}"
STRONG_URL="https://github.com/${UPSTREAM_REPO}/releases/download/${STRONG_TAG}"
WORK_DIR="/root/pve-realpc"
ACPI_DIR="/root"                       # ACPI .aml files go here (args reference /root/)
MAC_PREFIX="D8:FC:93"                  # Realistic Dell/Intel OUI
DATACENTER_CFG="/etc/pve/datacenter.cfg"
BACKUP_DIR="/root/pve-realpc/backup"

# Debian release — patched ROM/BIOS files with VM strings removed
# The PVE deb and Debian release share the same core sedPatch anti-detection
# transformations, but only the Debian release includes separately compiled
# SeaBIOS/VGA/EFI ROMs with "QEMU", "Bochs", "SeaBIOS" strings scrubbed
# (the PVE deb ships stock ROMs). The PVE qemu-autoGenPatch.patch is ~836 bytes
# larger — it adds bootsplash overrides and build-system integration.
# The QEMU binary from the PVE deb is PREFERRED over the Debian one because it
# includes PVE management integration + Strong build CPU sensor passthrough.
# We only use the Debian release for ROM overlay, NOT the binary.
DEBIAN_TAG="v20260507-200382-debian"
DEBIAN_URL="https://github.com/AICodo/pve-emu-realpc/releases/download/${DEBIAN_TAG}"
DEBIAN_DIR="${WORK_DIR}/debian"       # patched ROM staging (declared early for trap handler)
DEBIAN_BIOS_FILES=("bios-256k.bin" "bios.bin" "bios-microvm.bin")
DEBIAN_EFI_ROMS=("efi-e1000.rom" "efi-e1000e.rom" "efi-virtio.rom")
DEBIAN_VGA_ROMS=("vgabios-qxl.bin" "vgabios-stdvga.bin")
DEBIAN_ALL_ROMS=("${DEBIAN_BIOS_FILES[@]}" "${DEBIAN_EFI_ROMS[@]}" "${DEBIAN_VGA_ROMS[@]}")
SEABIOS_PATCH="seabios-autoGenPatch.patch"

# PVE release asset filenames  (static fallbacks — resolver updates these live)
# Base files come from ${RELEASE_TAG} (fallback); Strong .tgz from ${STRONG_TAG}.
# When the resolver runs, these are recomputed from the actual upstream release.
QEMU_BASE_DEB="pve-qemu-kvm_11.0.0-4_amd64.deb"
OVMF_BASE_DEB="pve-edk2-firmware-ovmf_4.2025.05-2_all.deb"
STRONG_TGZ="pve-qemu-kvm_11.0.0-1_amd64_Strong_intel_amd_6.17.13-2.tgz"
# Inside ${STRONG_TGZ} you'll find these (we locate them at install time by
# globbing — the exact paths inside the .tgz aren't guaranteed across upstream
# releases, so don't hard-code them):
#   - pve-qemu-kvm_11.0.0-1_amd64_Strong.deb
#   - pve-edk2-firmware-ovmf_4.2025.05-2_all_Strong.deb
#   - kvm.ko.6.17.13-2-intel  /  kvm.ko.6.17.13-2-amd
PATCH_FILE="qemu-autoGenPatch.patch"
ACPI_FILES=("ssdt.aml" "ssdt-ec.aml" "ssdt-battery.aml" "hpet.aml")

# iGPU passthrough ROM (AICodo/intel-ultra-rom — Intel only, AMD doesn't need a custom ROM)
IGPU_ROM_TAG="v2.0-20260307-095826"
IGPU_ROM_URL="https://github.com/AICodo/intel-ultra-rom/releases/download/${IGPU_ROM_TAG}"
IGPU_ROM_FILE="ultra-1-2-qemu10.rom"
IGPU_ROM_DIR="/usr/share/kvm"

# Boot splash — the PVE build hardcodes /usr/share/kvm/bootsplash.jpg in fw_cfg.c
# (replaces the default EDK2/TianoCore boot logo to defeat VMAware BOOT_LOGO CRC32 check).
# Not in release assets — downloaded from main branch.
BOOTSPLASH_DEST="/usr/share/kvm/bootsplash.jpg"

# ─── Flags ───────────────────────────────────────────────────────────────────
SKIP_DOWNLOAD=false
SKIP_PIN=false
SKIP_KERNEL_DOWNGRADE=false
ENABLE_IGPU=false
ENABLE_STRONG=true
NEEDS_REBOOT=false
INTERACTIVE_MODE=auto             # auto = run interactive when stdin is a tty
LIST_RELEASES_ONLY=false
SKIP_RESOLVE=false                # disable GitHub API lookup (use static defaults)
RELEASE_TAG_FLAG=""               # set via --release-tag to pin the base tag
STRONG_TAG_FLAG=""                # set via --strong-tag to pin the Strong tag
DEBIAN_TAG_FLAG=""                # set via --debian-tag to pin the Debian ROM tag
USER_PROVIDED_TAG=false
VERBOSE=false
DRY_RUN=false
FORCE=false
CLEANUP_FILES=()
STATE_FILE="${WORK_DIR}/.install-state"

while (( $# > 0 )); do
    arg="$1"
    case "$arg" in
        --skip-download)          SKIP_DOWNLOAD=true ;;
        --skip-pin)               SKIP_PIN=true ;;
        --skip-kernel-downgrade)  SKIP_KERNEL_DOWNGRADE=true ;;
        --igpu)                   ENABLE_IGPU=true ;;
        --no-strong)              ENABLE_STRONG=false ;;
        --interactive)            INTERACTIVE_MODE=force ;;
        --non-interactive)        INTERACTIVE_MODE=off ;;
        --list-releases)          LIST_RELEASES_ONLY=true ;;
        --skip-resolve)           SKIP_RESOLVE=true ;;
        --verbose)                VERBOSE=true ;;
        --dry-run)                DRY_RUN=true ;;
        --force)                  FORCE=true ;;
        --release-tag)            [[ $# -ge 2 ]] || { echo "Error: --release-tag requires a TAG argument" >&2; exit 2; }
                                  RELEASE_TAG_FLAG="$2"; USER_PROVIDED_TAG=true; shift ;;
        --strong-tag)             [[ $# -ge 2 ]] || { echo "Error: --strong-tag requires a TAG argument (or 'none')" >&2; exit 2; }
                                  STRONG_TAG_FLAG="$2";  USER_PROVIDED_TAG=true; shift ;;
        --debian-tag)             [[ $# -ge 2 ]] || { echo "Error: --debian-tag requires a TAG argument" >&2; exit 2; }
                                  DEBIAN_TAG_FLAG="$2";  USER_PROVIDED_TAG=true; shift ;;
        --help|-h)
            cat <<HELPEOF
$0 — PVE Anti-VM-Detection Setup

  Just run it. No flags needed.

    bash $0

The script auto-resolves the latest ${UPSTREAM_REPO} release from GitHub,
shows a whiptail menu with the newest base + last Strong-shipping tags
pre-selected, and asks you to confirm — Default or Advanced. iGPU passthrough
and kernel pin are also prompted. There is no flag you need to pass for the
common case.

────────────────────────────────────────────────────────────────────────
Advanced / unattended use (flags only needed when not running interactively)
────────────────────────────────────────────────────────────────────────

  Discovery
    --list-releases         Print resolved upstream release roster, exit
    --interactive           Force menu mode (even on non-TTY stdin)
    --non-interactive       Skip prompts; use latest auto-resolved tags

  Override the auto-resolver
    --release-tag TAG       Pin the base release tag
    --strong-tag TAG|none   Pin the Strong overlay tag (or "none" to skip)
    --debian-tag TAG        Pin the Debian ROMs tag
    --skip-resolve          Don't query GitHub API; use static fallback tags

  Override the install behaviour (all also available as prompts)
    --igpu                  Enable iGPU passthrough host config
    --no-strong             Skip Strong overlay (no sensor passthrough, no
                            kernel pin to 6.17.13-2)
    --skip-pin              Skip APT package pinning
    --skip-kernel-downgrade Skip auto kernel install if version mismatch
    --skip-download         Reuse pre-staged assets in ${WORK_DIR}
    --verbose               Show debug output (wget progress, set -x)
    --dry-run               Print what would be done, don't modify system
    --force                 Re-install even if already patched

────────────────────────────────────────────────────────────────────────
Environment
────────────────────────────────────────────────────────────────────────

  Proxy support: set http_proxy / https_proxy for corporate networks.
  Example: export https_proxy=http://proxy:8080

────────────────────────────────────────────────────────────────────────
Examples
────────────────────────────────────────────────────────────────────────

  bash $0                                       # interactive — the normal path
  bash $0 --list-releases                       # show available upstream releases
  bash $0 --non-interactive                     # CI: auto latest + Strong, no prompts
  bash $0 --non-interactive --no-strong         # CI: base only, no kernel pin
  bash $0 --release-tag v20260530-111870-pve9 --strong-tag none

HELPEOF
            exit 0
            ;;
        *) echo "Unknown argument: $arg"; exit 1 ;;
    esac
    shift
done

# ─── Helpers ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; exit 1; }
dbg()   { [[ "$VERBOSE" == true ]] && echo -e "${CYAN}[DBG]${NC}   $*" || true; }

dry_msg() { [[ "$DRY_RUN" == true ]] && echo -e "${YELLOW}[DRY]${NC}  $*" || true; }

# ─── Trap: clean up .part files and warn about partial state on interrupt ─────
cleanup_on_interrupt() {
    echo "" >&2
    warn "Script interrupted. Cleaning up partial downloads..."
    rm -f "${WORK_DIR}"/*.part "${DEBIAN_DIR}"/*.part 2>/dev/null || true
    [[ ${#CLEANUP_FILES[@]} -gt 0 ]] && rm -f "${CLEANUP_FILES[@]}" 2>/dev/null || true
    if [[ -f "$STATE_FILE" ]]; then
        local done_steps
        done_steps=$(tr '\n' ', ' < "$STATE_FILE" | sed 's/, $//')
        warn "Completed steps before interrupt: ${done_steps}"
    fi
    warn "Download cache preserved in ${WORK_DIR}. Re-run to resume."
    warn "If packages were partially installed, run: apt-get install -f -y"
    exit 130
}
trap cleanup_on_interrupt INT TERM

# Guard dry-run commands that would modify the system
dry_guard() {
    if [[ "$DRY_RUN" == true ]]; then
        dry_msg "Would run: $*"
        return 1
    fi
    return 0
}

# Validate that a config file contains an expected pattern after modification.
# Used after sed -i on system files to catch silent corruption.
validate_config_line() {
    local file="$1" pattern="$2" label="$3"
    if ! grep -q "$pattern" "$file" 2>/dev/null; then
        fail "Config validation failed: ${label} — '${pattern}' not found in ${file}. Restore from ${BACKUP_DIR}"
    fi
}

# Check available disk space before downloading large assets.
# Requires at least MIN_MB free in the target directory.
check_disk_space() {
    local path="$1" min_mb="${2:-250}"
    local avail_kb avail_mb
    mkdir -p "$path" 2>/dev/null || true
    avail_kb=$(df -k "$path" 2>/dev/null | awk 'NR==2 {print $4}')
    if [[ -z "$avail_kb" || "$avail_kb" -lt $((min_mb * 1024)) ]]; then
        fail "Low disk space: ${path} has ${avail_kb:-?}KB free (need >= ${min_mb}MB). Free up space and retry."
    fi
    dbg "Disk space OK: ${path} has $((avail_kb / 1024))MB free (need >= ${min_mb}MB)"
}

require_root() {
    [[ "$DRY_RUN" == true ]] && return 0
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
    # Cluster-awareness: changing MAC prefix in datacenter.cfg affects all nodes
    if [[ -f /etc/pve/corosync.conf ]] || pvecm status &>/dev/null; then
        warn "Cluster detected — MAC prefix changes in datacenter.cfg will apply cluster-wide."
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

###############################################################################
# UI helpers (inspired by community-scripts/ProxmoxVE)
###############################################################################
# Colour palette used by the banner + msg_* helpers below.
YW='\033[33m'; BL='\033[36m'; BGN='\033[4;92m'; DGN='\033[32m'; BOLD='\033[1m'
TAB="  "; BFR="\\r\\033[K"; HOLD=" "
CM="${TAB}\xE2\x9C\x94${TAB}"          # check mark
XX="${TAB}\xE2\x9C\x96${TAB}"          # cross
II="${TAB}\xE2\x9E\xA4${TAB}"          # arrow

header_info() {
    clear
    cat <<'BANNER'

  ╔═══════════════════════════════════════════════════════════════════╗
  ║   PVE RealPC — Anti-VM-Detection Setup for Proxmox VE 9           ║
  ║                                                                   ║
  ║   Upstream: AICodo/pve-emu-realpc  (QEMU 11 patched build)        ║
  ║   Style:    community-scripts/ProxmoxVE                           ║
  ╚═══════════════════════════════════════════════════════════════════╝

BANNER
}

# Progressive status helpers. msg_info shows a "working" line; msg_ok rewrites
# it as success; msg_err rewrites it as failure and exits.
msg_info() { local m="$*"; printf "${BFR}${YW}${II}${HOLD}${m}${NC}"; }
msg_ok()   { local m="$*"; printf "${BFR}${GREEN}${CM}${HOLD}${m}${NC}\n"; }
msg_err()  { local m="$*"; printf "${BFR}${RED}${XX}${HOLD}${m}${NC}\n"; exit 1; }

have_whiptail() { command -v whiptail &>/dev/null; }

###############################################################################
# Upstream release resolver
#
# Queries the GitHub API and produces a stable, pipe-separated index of every
# pve-emu-realpc release. The setup script uses this to (a) auto-detect the
# newest base + latest Strong-shipping release without any hard-coded tags,
# (b) populate whiptail menus for interactive selection, and (c) print a
# release roster with `--list-releases`.
#
# Output format (one line per release):
#
#   KIND | TAG | DATE | QEMU_VER | OVMF_VER | STRONG_KERNEL | PATCH_BYTES | TITLE
#
# KIND is one of:
#   pve9-strong   - tag ends with -pve9 AND ships a *_Strong_*.tgz asset
#   pve9-base     - tag ends with -pve9 but NO Strong asset
#   debian        - tag ends with -debian
#   ubuntu        - tag ends with -ubuntu
#   pve-other     - any other tag (older PVE8 releases, pre-suffix scheme)
#
# Empty fields stay empty so callers can still parse the line.
###############################################################################
# UPSTREAM_REPO is declared up in the tunables block (needed by the help heredoc).
RELEASE_CACHE="${WORK_DIR}/upstream-releases.txt"
RELEASE_API_URL="https://api.github.com/repos/${UPSTREAM_REPO}/releases?per_page=20"

resolve_upstream_releases() {
    # Returns 0 with $RELEASE_CACHE populated on success, 1 on any failure.
    mkdir -p "$(dirname "$RELEASE_CACHE")"
    local raw="${RELEASE_CACHE}.raw"
    if ! curl -sSL --max-time 20 "$RELEASE_API_URL" -o "$raw" 2>/dev/null; then
        rm -f "$raw"; return 1
    fi
    [[ -s "$raw" ]] || { rm -f "$raw"; return 1; }
    # Bail on a "rate limit exceeded" payload.
    if grep -q '"message".*rate limit' "$raw"; then
        rm -f "$raw"; return 1
    fi
    # python3 is in the Debian/PVE base; falling back to pure-bash parsing of
    # GitHub JSON would be fragile.
    if ! command -v python3 &>/dev/null; then
        rm -f "$raw"; return 1
    fi
    if ! python3 -c "$(cat <<'PYEOF'
import json, sys, re
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for r in data:
    if r.get('draft') or r.get('prerelease'):
        continue
    tag = r.get('tag_name') or ''
    date = (r.get('published_at') or '')[:10]
    title = (r.get('name') or '').strip()
    assets = {a['name']: a['size'] for a in (r.get('assets') or [])}
    qemu_ver = ''
    ovmf_ver = ''
    strong_kernel = ''
    has_strong = False
    patch_bytes = 0
    for name, size in assets.items():
        m = re.match(r'pve-qemu-kvm_([0-9][0-9.\-]*)_amd64\.deb$', name)
        if m: qemu_ver = m.group(1)
        m = re.match(r'pve-edk2-firmware-ovmf_([0-9][0-9.\-]*)_all\.deb$', name)
        if m: ovmf_ver = m.group(1)
        m = re.match(r'pve-qemu-kvm_[0-9][0-9.\-]*_amd64_Strong_intel_amd(?:_(.+))?\.tgz$', name)
        if m:
            has_strong = True
            strong_kernel = m.group(1) or ''
        if name == 'qemu-autoGenPatch.patch':
            patch_bytes = size
    if tag.endswith('-pve9'):
        kind = 'pve9-strong' if has_strong else 'pve9-base'
    elif tag.endswith('-debian'):
        kind = 'debian'
    elif tag.endswith('-ubuntu'):
        kind = 'ubuntu'
    else:
        kind = 'pve-other'
    title_ascii = title.encode('ascii', 'replace').decode().replace('?', '')[:60]
    print(f'{kind}|{tag}|{date}|{qemu_ver}|{ovmf_ver}|{strong_kernel}|{patch_bytes}|{title_ascii}')
PYEOF
)" < "$raw" > "$RELEASE_CACHE" 2>/dev/null
    then
        rm -f "$raw"; return 1
    fi
    rm -f "$raw"
    [[ -s "$RELEASE_CACHE" ]] || return 1
    return 0
}

# Filter the cache by KIND (first field). Output: matching lines, newest first
# (the API already returns newest-first; we preserve that order).
releases_of_kind() {
    local kind="$1"
    [[ -f "$RELEASE_CACHE" ]] || return 1
    awk -F'|' -v k="$kind" '$1 == k' "$RELEASE_CACHE"
}

# Best-effort pick: first line matching KIND (= newest of that kind).
# Calls awk directly with `{print; exit}` rather than piping releases_of_kind
# through `head -1` — `head` closing its stdin after one line would SIGPIPE
# the upstream awk and abort the pipeline under `set -euo pipefail`.
latest_of_kind() {
    local kind="$1"
    [[ -f "$RELEASE_CACHE" ]] || return 1
    awk -F'|' -v k="$kind" '$1 == k {print; exit}' "$RELEASE_CACHE"
}

# Pretty-print a release line for menu labels.
# Input: pipe-separated line. Output: human-readable summary.
release_summary() {
    local line="$1"
    IFS='|' read -r kind tag date qver over kver pbytes title <<<"$line"
    local s="${date}  qemu ${qver:-?}"
    [[ -n "$over"  ]] && s+="  ovmf ${over}"
    [[ -n "$kver"  ]] && s+="  strong-kernel ${kver}"
    [[ "$kind" == "pve9-strong" && -z "$kver" ]] && s+="  strong (no kernel pin)"
    [[ "$kind" == "pve9-base"   ]] && s+="  (no strong overlay)"
    [[ -n "$title" ]] && s+="  — ${title}"
    printf '%s' "$s"
}

###############################################################################
# Interactive configuration phase (whiptail-driven)
###############################################################################
# Sets the install-time variables from user choices instead of hard-coded
# constants. Anything the user explicitly passed via flag is preserved; the
# interactive prompts only fire for fields that weren't pre-set on the CLI.
# (INTERACTIVE_MODE is declared and parsed above in the flag-parser block —
# do NOT re-assign it here or --interactive / --non-interactive get silently
# clobbered back to "auto".)
WT_BACK="PVE RealPC Setup"  # whiptail --backtitle

# whiptail wrappers — soft-fail back to plain read if whiptail is missing.
wt_yesno() {
    # wt_yesno TITLE QUESTION [default-yes|default-no]
    local title="$1" q="$2" def="${3:-default-yes}" extra=()
    [[ "$def" == "default-no" ]] && extra=(--defaultno)
    if have_whiptail; then
        whiptail --backtitle "$WT_BACK" --title "$title" "${extra[@]}" --yesno "$q" 12 76
        return $?
    fi
    local prompt="[y/N]" reply
    [[ "$def" == "default-yes" ]] && prompt="[Y/n]"
    read -rp "${title} — ${q} ${prompt} " reply
    if [[ "$def" == "default-yes" ]]; then [[ -z "$reply" || "$reply" =~ ^[Yy] ]]
    else                                    [[ "$reply" =~ ^[Yy] ]]; fi
}

wt_menu() {
    # wt_menu TITLE PROMPT  pairs:  TAG1 LABEL1 TAG2 LABEL2 ...
    # Prints chosen TAG on stdout.
    local title="$1" prompt="$2"; shift 2
    local -a items=("$@")
    if have_whiptail; then
        whiptail --backtitle "$WT_BACK" --title "$title" --menu "$prompt" 22 96 12 \
            "${items[@]}" 3>&1 1>&2 2>&3
        return $?
    fi
    # Fallback: numbered list
    echo "${title} — ${prompt}"
    local i=1; local -a tags=()
    while (( $# )); do
        tags+=("$1"); echo "  ${i}) $2 [$1]"; shift 2; (( i++ ))
    done
    local reply
    read -rp "Choose [1-$((i-1))]: " reply
    if [[ "$reply" =~ ^[0-9]+$ ]] && (( reply >= 1 && reply < i )); then
        echo "${tags[$((reply-1))]}"
        return 0
    fi
    return 1
}

# Build a whiptail menu of releases of a given kind, with sensible default.
# Args: title prompt kind extra_tag extra_label
# Prints chosen TAG (or extra_tag if the user picked the extra row).
pick_release_menu() {
    local title="$1" prompt="$2" kind="$3" extra_tag="${4:-}" extra_label="${5:-}"
    local -a items=()
    local line tag rest
    while IFS= read -r line; do
        IFS='|' read -r _ tag _ _ _ _ _ _ <<<"$line"
        [[ -z "$tag" ]] && continue
        items+=("$tag" "$(release_summary "$line")")
    done < <(releases_of_kind "$kind")
    if [[ ${#items[@]} -eq 0 ]]; then
        # Distinguish "no items found" (exit 2) from "user cancelled" (exit 1 from wt_menu)
        return 2
    fi
    if [[ -n "$extra_tag" ]]; then
        items+=("$extra_tag" "$extra_label")
    fi
    wt_menu "$title" "$prompt" "${items[@]}"
}

# Update RELEASE_TAG / STRONG_TAG / DEBIAN_TAG and derive asset filenames
# from the parsed release cache. Future upstream releases work automatically
# as long as they keep the (very stable) filename conventions:
#   pve-qemu-kvm_<VER>_amd64.deb
#   pve-edk2-firmware-ovmf_<VER>_all.deb
#   pve-qemu-kvm_<VER>_amd64_Strong_intel_amd[_<KERNEL>].tgz
apply_release_choice() {
    local base="$1" strong="$2" deb="$3"
    [[ -n "$base"   ]] && RELEASE_TAG="$base"
    [[ -n "$strong" ]] && STRONG_TAG="$strong"
    [[ -n "$deb"    ]] && DEBIAN_TAG="$deb"
    BASE_URL="https://github.com/${UPSTREAM_REPO}/releases/download/${RELEASE_TAG}"
    STRONG_URL="https://github.com/${UPSTREAM_REPO}/releases/download/${STRONG_TAG}"
    DEBIAN_URL="https://github.com/${UPSTREAM_REPO}/releases/download/${DEBIAN_TAG}"
    # Pull versions out of the cache if we have it
    if [[ -s "$RELEASE_CACHE" ]]; then
        local line qver over
        line=$(awk -F'|' -v t="$RELEASE_TAG" '$2==t {print; exit}' "$RELEASE_CACHE")
        if [[ -n "$line" ]]; then
            qver=$(awk -F'|' '{print $4}' <<<"$line")
            over=$(awk -F'|' '{print $5}' <<<"$line")
            [[ -n "$qver" ]] && QEMU_BASE_DEB="pve-qemu-kvm_${qver}_amd64.deb"
            [[ -n "$over" ]] && OVMF_BASE_DEB="pve-edk2-firmware-ovmf_${over}_all.deb"
        fi
        # Strong .tgz filename includes the Strong-tag's qemu version and kernel
        local sline sqver skver
        sline=$(awk -F'|' -v t="$STRONG_TAG" '$2==t {print; exit}' "$RELEASE_CACHE")
        if [[ -n "$sline" ]]; then
            sqver=$(awk -F'|' '{print $4}' <<<"$sline")
            skver=$(awk -F'|' '{print $6}' <<<"$sline")
            if [[ -n "$sqver" ]]; then
                if [[ -n "$skver" ]]; then
                    STRONG_TGZ="pve-qemu-kvm_${sqver}_amd64_Strong_intel_amd_${skver}.tgz"
                else
                    STRONG_TGZ="pve-qemu-kvm_${sqver}_amd64_Strong_intel_amd.tgz"
                fi
            fi
        fi
    fi
}

# Decide whether to launch the whiptail flow.
should_run_interactive() {
    case "$INTERACTIVE_MODE" in
        force) return 0 ;;
        off)   return 1 ;;
        auto)
            # Skip when the user already gave us enough info on the CLI to
            # proceed unattended (any explicit release pin, or --non-interactive).
            [[ "$USER_PROVIDED_TAG" == true ]] && return 1
            [[ -t 0 ]] || return 1
            have_whiptail || return 1
            return 0
            ;;
    esac
    return 1
}

# Interactive configuration phase. Sets RELEASE_TAG / STRONG_TAG / DEBIAN_TAG
# and the install behaviour booleans from user-chosen values.
run_interactive_config() {
    header_info
    if ! resolve_upstream_releases; then
        warn "Could not reach GitHub API (or python3 missing). Falling back to static defaults: ${RELEASE_TAG} / ${STRONG_TAG} / ${DEBIAN_TAG}"
        sleep 2
        return 0
    fi

    # Auto-detected sensible defaults
    local def_base def_strong def_debian
    def_strong=$(latest_of_kind pve9-strong | awk -F'|' '{print $2}')
    def_base=$(latest_of_kind pve9-base | awk -F'|' '{print $2}')
    # If upstream's latest tag IS a Strong release, that's also the latest base
    # (the Strong tag also ships the base files). Treat it as such.
    if [[ -z "$def_base" || "$(latest_of_kind pve9-base | awk -F'|' '{print $3}')" < "$(latest_of_kind pve9-strong | awk -F'|' '{print $3}')" ]]; then
        def_base="$def_strong"
    fi
    def_debian=$(latest_of_kind debian | awk -F'|' '{print $2}')

    # If any of these are still empty, the API gave us something unexpected
    if [[ -z "$def_base" || -z "$def_strong" || -z "$def_debian" ]]; then
        warn "Resolver returned incomplete data — using static defaults."
        sleep 2
        return 0
    fi

    local summary="The script auto-resolved the latest upstream releases:

  Base release:    ${def_base}
                   $(release_summary "$(awk -F'|' -v t="$def_base" '$2==t' "$RELEASE_CACHE" | head -1)")
  Strong overlay:  ${def_strong}
                   $(release_summary "$(awk -F'|' -v t="$def_strong" '$2==t' "$RELEASE_CACHE" | head -1)")
  Debian ROMs:     ${def_debian}
                   $(release_summary "$(awk -F'|' -v t="$def_debian" '$2==t' "$RELEASE_CACHE" | head -1)")

Default mode uses these picks + sensible install options. Advanced mode lets
you swap any release and toggle Strong / iGPU / APT pin / kernel pin manually."

    if wt_yesno "Setup mode" "$summary"$'\n\nUse Default settings?'  default-yes; then
        apply_release_choice "$def_base" "$def_strong" "$def_debian"
        # Default mode still asks the two high-impact questions a user needs to
        # consent to — these change host behaviour materially. Everything else
        # (release picks, APT pin, etc.) keeps the safe default.
        if wt_yesno "iGPU passthrough" "Would you like to configure iGPU passthrough on this host?\n\nThis will:\n  - Enable intel_iommu / amd_iommu in GRUB\n  - Blacklist i915/snd_hda_intel (Intel) or amdgpu/radeon (AMD)\n  - Load VFIO modules at boot\n  - Download the Intel iGPU ROM (Intel hosts only)\n\nOnly say YES if you actually plan to pass the iGPU into a VM. Reboot required after.\n\n(Default: no)" default-no; then
            ENABLE_IGPU=true
        fi
        if [[ "$ENABLE_STRONG" == true ]]; then
            if ! wt_yesno "Kernel pin" "The Strong kvm.ko is built for kernel 6.17.13-2. If the host kernel doesn't match, allow auto-install + pin (reboot required)?\n\n(Default: yes — required for sensor passthrough to work)" default-yes; then
                SKIP_KERNEL_DOWNGRADE=true
            fi
        fi
        return 0
    fi

    # ── Advanced mode ─────────────────────────────────────────────────────────
    local picked

    picked=$(pick_release_menu "Base release" "Choose the PVE9 release that provides the base QEMU + OVMF .deb files,\nACPI tables, and the anti-detection patch." pve9-base "$def_strong" "${def_strong}  (newest Strong tag also ships base files — use it)")
    case $? in
        0) ;;
        2) fail "No pve9-base releases found upstream. Run with --skip-resolve to fall back to static defaults, or check connectivity to api.github.com." ;;
        *) msg_err "Cancelled at base-release selection." ;;
    esac
    local base_tag="$picked"

    local strong_tag=""
    picked=$(pick_release_menu "Strong overlay" "Choose the Strong-shipping release.\nProvides Strong QEMU + Strong OVMF + kvm.ko for sensor passthrough.\n\nSelect the LAST row to skip Strong entirely (no sensor passthrough,\nbut no kernel pin either)." pve9-strong "__no_strong__" "SKIP STRONG — base release only, no kvm.ko, no kernel pin")
    case $? in
        0) ;;
        2) warn "No pve9-strong releases found — defaulting to --no-strong."; picked="__no_strong__" ;;
        *) msg_err "Cancelled at Strong-release selection." ;;
    esac
    if [[ "$picked" == "__no_strong__" ]]; then
        ENABLE_STRONG=false
        strong_tag="$def_strong"   # placeholder so URL stays valid
    else
        strong_tag="$picked"
    fi

    picked=$(pick_release_menu "Debian ROMs" "Choose the Debian release. Only its patched BIOS/EFI/VGA ROM files are used\n(QEMU binary from this release is intentionally skipped — PVE binary preferred)." debian)
    case $? in
        0) ;;
        2) fail "No -debian releases found upstream — patched ROM files unavailable." ;;
        *) msg_err "Cancelled at Debian-release selection." ;;
    esac
    local debian_tag="$picked"

    apply_release_choice "$base_tag" "$strong_tag" "$debian_tag"

    if wt_yesno "iGPU passthrough" "Configure host for iGPU passthrough?\n\nIntel: downloads the patched iGPU ROM, enables intel_iommu, blacklists\n       i915 + snd_hda_intel, loads VFIO modules.\nAMD:   enables amd_iommu, blacklists amdgpu+radeon+snd_hda_intel, loads VFIO.\n\nOnly enable if you actually plan to pass the iGPU into a VM." default-no; then
        ENABLE_IGPU=true
    fi

    if wt_yesno "APT package pinning" "Pin pve-qemu-kvm and pve-edk2-firmware-ovmf at priority -1?\n\nWithout this, an unattended 'apt upgrade' may silently overwrite the\npatched packages with stock Proxmox versions and break anti-detection." default-yes; then
        SKIP_PIN=false
    else
        SKIP_PIN=true
    fi

    if [[ "$ENABLE_STRONG" == true ]]; then
        if wt_yesno "Kernel downgrade" "The patched kvm.ko in the Strong .tgz is compiled against a specific\nkernel version. If your running kernel doesn't match, the module won't\nload.\n\nAllow this script to install + pin the matching kernel automatically\nwhen needed? (Reboot required after.)" default-yes; then
            SKIP_KERNEL_DOWNGRADE=false
        else
            SKIP_KERNEL_DOWNGRADE=true
        fi
    fi

    local final="Ready to install with these settings:

  Base release:    ${RELEASE_TAG}
  Base QEMU deb:   ${QEMU_BASE_DEB}
  Base OVMF deb:   ${OVMF_BASE_DEB}
  Strong:          $(if [[ $ENABLE_STRONG == true ]]; then echo "${STRONG_TAG}"; else echo "skipped"; fi)
  Strong .tgz:     $(if [[ $ENABLE_STRONG == true ]]; then echo "${STRONG_TGZ}"; else echo "(n/a)"; fi)
  Debian ROMs:     ${DEBIAN_TAG}
  iGPU setup:      $(if [[ $ENABLE_IGPU == true ]]; then echo "yes"; else echo "no"; fi)
  APT pin:         $(if [[ $SKIP_PIN == true ]]; then echo "no"; else echo "yes"; fi)
  Kernel pin:      $(if [[ $ENABLE_STRONG == true ]]; then if [[ $SKIP_KERNEL_DOWNGRADE == true ]]; then echo "no"; else echo "auto"; fi; else echo "n/a"; fi)"

    if ! wt_yesno "Confirm" "$final"$'\n\nProceed?' default-yes; then
        msg_err "Cancelled by user."
    fi
}

# Print the resolved release roster to stdout (used by --list-releases).
print_release_roster() {
    if [[ ! -s "$RELEASE_CACHE" ]]; then
        echo "Release cache empty — could not reach $RELEASE_API_URL"
        return 1
    fi
    printf '\n%-14s %-32s %-11s %-12s %-12s %-20s %s\n' \
        "KIND" "TAG" "DATE" "QEMU" "OVMF" "STRONG-KERNEL" "TITLE"
    printf '%s\n' "$(printf '%.0s-' {1..130})"
    awk -F'|' '{
        title=$8; gsub(/\\.+/,"",title);
        printf "%-14s %-32s %-11s %-12s %-12s %-20s %s\n",
               $1,$2,$3,$4,$5,($6?$6:"-"),title
    }' "$RELEASE_CACHE"
    echo ""
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
        # apt-cache search uses POSIX ERE — run two searches for both prefix schemes.
        # Sanitize version fragment (escape dots) so `.` doesn't wildcard-match.
        local frag_re="${target_ver_fragment//./\\.}"
        found=$( { apt-cache search "proxmox-kernel.*${frag_re}" 2>/dev/null; \
                   apt-cache search "pve-kernel.*${frag_re}" 2>/dev/null; \
                 } | grep -Ev 'headers|dbg|signed' | head -5 || true)
        if [[ -n "$found" ]]; then
            info "Available kernel packages:"
            echo "$found"
            # awk on first line only — no pipe to head, no SIGPIPE.
            pkg_name=$(awk 'NR==1 {print $1; exit}' <<<"$found")
            info "Selecting: ${pkg_name}"
        else
            warn "╔══════════════════════════════════════════════════════════════════╗"
            printf "${YELLOW}[WARN]${NC}  ║  %-64s║\\n" "KERNEL NOT AVAILABLE"
            printf "${YELLOW}[WARN]${NC}  ║%-66s║\\n" ""
            printf "${YELLOW}[WARN]${NC}  ║  %-64s║\\n" "No kernel package matching '${target_ver_fragment}' found in APT."
            printf "${YELLOW}[WARN]${NC}  ║  %-64s║\\n" "The patched kvm.ko was built for this specific kernel version."
            printf "${YELLOW}[WARN]${NC}  ║%-66s║\\n" ""
            printf "${YELLOW}[WARN]${NC}  ║  %-64s║\\n" "Options:"
            printf "${YELLOW}[WARN]${NC}  ║  %-64s║\\n" "  1. Skip Strong (--no-strong) — base anti-detection still works,"
            printf "${YELLOW}[WARN]${NC}  ║  %-64s║\\n" "     you only lose sensor passthrough (temperature/MHz/power)."
            printf "${YELLOW}[WARN]${NC}  ║  %-64s║\\n" "  2. Check for a newer Strong .tgz built for your kernel."
            printf "${YELLOW}[WARN]${NC}  ║  %-64s║\\n" "  3. Install the kvm.ko anyway — it will NOT load on your"
            printf "${YELLOW}[WARN]${NC}  ║  %-64s║\\n" "     current kernel (version magic mismatch)."
            printf "${YELLOW}[WARN]${NC}  ║%-66s║\\n" ""
            printf "${YELLOW}[WARN]${NC}  ║  %-64s║\\n" "Available kernels:"
            if command -v apt-cache &>/dev/null; then
                local avail_kernels
                avail_kernels=$( { apt-cache search '^proxmox-kernel-[0-9]' 2>/dev/null; \
                                   apt-cache search '^pve-kernel-[0-9]' 2>/dev/null; } \
                                 | grep -Ev 'headers|dbg|signed' | awk '{print $1}' | sort -V | tail -10 || true)
                if [[ -n "$avail_kernels" ]]; then
                    while IFS= read -r k; do
                        printf "${YELLOW}[WARN]${NC}  ║    %-62s║\\n" "$k"
                    done <<<"$avail_kernels"
                else
                    printf "${YELLOW}[WARN]${NC}  ║    %-62s║\\n" "(none found — check APT sources: /etc/apt/sources.list.d/)"
                fi
            fi
            warn "╚══════════════════════════════════════════════════════════════════╝"
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
        # Check if 'kernel pin' subcommand is supported (added in recent PVE releases)
        if proxmox-boot-tool kernel pin --help &>/dev/null 2>&1; then
            info "Pinning ${target_kernel} via proxmox-boot-tool kernel pin ..."
            proxmox-boot-tool kernel pin "$target_kernel" 2>&1 | tail -3 || \
                warn "proxmox-boot-tool kernel pin returned non-zero — GRUB fallback still in effect."
        else
            info "proxmox-boot-tool present but 'kernel pin' subcommand not available — using GRUB fallback."
            proxmox-boot-tool refresh 2>&1 | tail -3 || true
        fi
    fi

    # Method 2: GRUB pinning (works on all setups)
    local grub_default="/etc/default/grub"
    if [[ -f "$grub_default" ]]; then
        # Backup current GRUB config
        cp "$grub_default" "${BACKUP_DIR}/grub.default.bak" 2>/dev/null || true

        # Set GRUB to boot the default (first) entry — PVE sorts by version, newest first
        if grep -q "^GRUB_DEFAULT=" "$grub_default"; then
            sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=0/' "$grub_default"
        else
            echo 'GRUB_DEFAULT=0' >> "$grub_default"
        fi
        validate_config_line "$grub_default" "^GRUB_DEFAULT=0" "GRUB default boot entry"

        # Rebuild GRUB config
        if command -v update-grub &>/dev/null; then
            info "Updating GRUB configuration ..."
            if dry_guard "update-grub"; then
                update-grub || warn "update-grub returned non-zero — boot config may need manual review"
            fi
        fi
        ok "GRUB configured to boot kernel ${target_kernel}"
    fi

    # ── Install the patched kvm.ko into the TARGET kernel's module tree ──
    local target_modules="/lib/modules/${target_kernel}"
    local target_kvm_dir="${target_modules}/kernel/arch/x86/kvm"
    if [[ -d "$target_modules" ]]; then
        mkdir -p "$target_kvm_dir"

        # Remove any compressed stock module
        rm -f "${target_kvm_dir}/kvm.ko.zst" 2>/dev/null || true

        info "Installing patched kvm.ko into /lib/modules/${target_kernel}/ ..."
        cp "$kvm_module_src" "${target_kvm_dir}/kvm.ko"
        chmod 644 "${target_kvm_dir}/kvm.ko"

        # Verify vermagic compatibility between the module and the target kernel
        local module_vermagic kernel_vermagic
        module_vermagic=$(modinfo -F vermagic "${target_kvm_dir}/kvm.ko" 2>/dev/null || echo "")
        if [[ -f "${target_modules}/build/include/generated/utsrelease.h" ]]; then
            kernel_vermagic=$(grep -oP 'UTS_RELEASE "\K[^"]+' "${target_modules}/build/include/generated/utsrelease.h" 2>/dev/null || echo "")
        fi
        if [[ -z "$kernel_vermagic" && -f "/lib/modules/${target_kernel}/modules.builtin" ]]; then
            # Fallback: the target kernel version IS the vermagic base
            kernel_vermagic="$target_kernel"
        fi
        if [[ -n "$module_vermagic" && -n "$kernel_vermagic" ]]; then
            # vermagic format: "6.17.13-2-pve SMP preempt mod_unload modversions "
            if echo "$module_vermagic" | grep -qF "$kernel_vermagic"; then
                ok "Module vermagic verified: compatible with kernel ${target_kernel}"
            else
                warn "Module vermagic MISMATCH: module=${module_vermagic}, kernel=${kernel_vermagic}"
                warn "The kvm.ko will NOT load. Skip Strong (--no-strong) or find a matching build."
            fi
        fi

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
    printf "${YELLOW}[WARN]${NC}  ║  %-64s║\\n" "REBOOT REQUIRED"
    printf "${YELLOW}[WARN]${NC}  ║%-66s║\\n" ""
    printf "${YELLOW}[WARN]${NC}  ║  %-64s║\\n" "A different kernel (${target_kernel}) has been installed"
    printf "${YELLOW}[WARN]${NC}  ║  %-64s║\\n" "and pinned as the default boot entry."
    printf "${YELLOW}[WARN]${NC}  ║%-66s║\\n" ""
    printf "${YELLOW}[WARN]${NC}  ║  %-64s║\\n" "Please reboot now:  reboot"
    printf "${YELLOW}[WARN]${NC}  ║%-66s║\\n" ""
    printf "${YELLOW}[WARN]${NC}  ║  %-64s║\\n" "After reboot, verify with:  uname -r"
    printf "${YELLOW}[WARN]${NC}  ║  %-64s║\\n" "Expected: ${target_kernel}"
    warn "╚══════════════════════════════════════════════════════════════════╝"

    return 0
}

download_asset() {
    # download_asset NAME [URL_BASE] [DEST_DIR]
    # If URL_BASE is omitted, defaults to ${BASE_URL} (the latest release).
    # If DEST_DIR is omitted, defaults to ${WORK_DIR}.
    # Downloads to ${dest}.part and renames atomically so a Ctrl-C / network
    # failure mid-download can't leave a partial file that the next run treats
    # as already-downloaded.
    # For .deb files, validates integrity with dpkg-deb. For .tgz, validates
    # with tar -tzf. All downloads are size-checked (>=50 bytes).
    local name="$1"
    local url_base="${2:-$BASE_URL}"
    local dest_dir="${3:-$WORK_DIR}"
    local dest="${dest_dir}/${name}"
    local part="${dest}.part"
    local label="${4:-}"
    [[ -z "$label" ]] && label="$name"

    if [[ -f "$dest" ]]; then
        ok "Already downloaded: ${label}"
        return 0
    fi
    dbg "Downloading ${url_base}/${name} → ${dest_dir}/"
    info "Downloading ${label} ..."
    rm -f "$part"
    CLEANUP_FILES+=("$part")
    # --show-progress only when stdout is a TTY (avoids carriage-return garbled CI logs)
    local wget_opts=(-q -O "$part")
    [[ "$VERBOSE" == true ]] && wget_opts=(-O "$part")
    [[ -t 1 && "$VERBOSE" != true ]] && wget_opts=(-q --show-progress -O "$part")
    if ! wget "${wget_opts[@]}" "${url_base}/${name}"; then
        rm -f "$part"
        fail "Failed to download ${name}"
    fi
    # Validate download — GitHub error pages are ~10KB of HTML, not real assets
    local fsize
    fsize=$(stat -c%s "$part" 2>/dev/null || echo "0")
    if [[ "$fsize" -lt 50 ]]; then
        rm -f "$part"
        fail "Downloaded ${name} is too small (${fsize} bytes) — likely a download error"
    fi
    # Integrity check for known formats
    if [[ "$name" == *.deb ]]; then
        if ! dpkg-deb --info "$part" &>/dev/null; then
            rm -f "$part"
            fail "Downloaded ${name} failed dpkg-deb integrity check — file may be corrupt"
        fi
    elif [[ "$name" == *.tgz || "$name" == *.tar.gz ]]; then
        if ! tar -tzf "$part" &>/dev/null; then
            rm -f "$part"
            fail "Downloaded ${name} failed tar integrity check — archive may be corrupt"
        fi
    fi
    mv -f "$part" "$dest"
    ok "Downloaded: ${label} (${fsize} bytes)"
}

###############################################################################
# STEP 0: Pre-flight checks
###############################################################################

# --list-releases is read-only — don't require root for it.
if [[ "$LIST_RELEASES_ONLY" == true ]]; then
    if [[ "$SKIP_RESOLVE" == true ]]; then
        fail "--list-releases needs network access — don't pass --skip-resolve with it."
    fi
    # Use a tempdir so we don't need /root/pve-realpc just to list releases.
    RELEASE_CACHE="$(mktemp -d)/upstream-releases.txt"
    info "Querying ${RELEASE_API_URL} ..."
    if resolve_upstream_releases; then
        print_release_roster
        rm -rf "$(dirname "$RELEASE_CACHE")"
        exit 0
    else
        rm -rf "$(dirname "$RELEASE_CACHE")"
        fail "Failed to reach the GitHub API. Check network / rate limits."
    fi
fi

if [[ "$DRY_RUN" == true ]]; then
    dry_msg "DRY RUN — no system modifications will be made."
    dry_msg ""
fi

require_root
check_pve9

# Make sure the working dir exists before the resolver tries to cache into it.
mkdir -p "${WORK_DIR}" "${BACKUP_DIR}"

# ─── Idempotency / half-installed state check ────────────────────────────────
# Track install progress so interrupted runs can report what was already done.
record_step() { echo "$1" >> "$STATE_FILE"; }
step_done()  { [[ -f "$STATE_FILE" ]] && grep -qxF "$1" "$STATE_FILE"; }
QEMU_BIN_PATH="/usr/bin/qemu-system-x86_64"
if [[ "$FORCE" != true ]]; then
    if [[ -f "$QEMU_BIN_PATH" ]]; then
        qsz=$(stat -c%s "$QEMU_BIN_PATH" 2>/dev/null || echo "0")
        if (( qsz >= 29000000 )) && [[ -f "${BACKUP_DIR}/qemu-system-x86_64.stock" ]]; then
            warn "Patched QEMU appears already installed (binary: $((qsz/1024/1024))MB, backup exists)."
            warn "Re-run with --force to re-install anyway, or use --dry-run to preview."
            if [[ "$DRY_RUN" != true ]]; then
                warn "Skipping — nothing to do. Run with --force to override."
                exit 0
            fi
        fi
    fi
    # Warn about half-installed state from a previous interrupted run
    if [[ -f "$STATE_FILE" ]]; then
        done_steps=$(tr '\n' ', ' < "$STATE_FILE" | sed 's/, $//')
        warn "Previous run was interrupted. Completed steps: ${done_steps}."
        warn "Re-running will resume from the beginning. Backups from first run are preserved."
        warn "Delete ${STATE_FILE} to silence this warning."
    fi
fi
rm -f "$STATE_FILE"  # fresh state for this run

# ─── Apply CLI-supplied pins (skips/short-circuits resolver where possible) ──
if [[ -n "$RELEASE_TAG_FLAG" || -n "$STRONG_TAG_FLAG" || -n "$DEBIAN_TAG_FLAG" ]]; then
    # If the user pinned anything, fill the rest from the resolver so we can
    # still derive correct asset filenames. Resolver is best-effort here.
    if [[ "$SKIP_RESOLVE" != true ]]; then
        resolve_upstream_releases || warn "Resolver failed; pinned tags will use the static asset-filename defaults."
    fi
    if [[ "$STRONG_TAG_FLAG" == "none" ]]; then
        ENABLE_STRONG=false
        STRONG_TAG_FLAG=""
    fi
    apply_release_choice "${RELEASE_TAG_FLAG:-$RELEASE_TAG}" \
                         "${STRONG_TAG_FLAG:-$STRONG_TAG}" \
                         "${DEBIAN_TAG_FLAG:-$DEBIAN_TAG}"
fi

# Resolve latest tags in non-interactive mode. Called as a function so the
# variables don't leak into global scope (key concern: local_ prefixed vars).
resolve_noninteractive_tags() {
    if ! resolve_upstream_releases; then
        warn "GitHub API unreachable — falling back to static defaults."
        return 1
    fi
    local def_base def_strong def_debian
    def_strong=$(latest_of_kind pve9-strong | awk -F'|' '{print $2}')
    def_base=$(latest_of_kind pve9-base | awk -F'|' '{print $2}')
    # If upstream's latest tag IS a Strong release, that's also the latest base
    if [[ -z "$def_base" ]]; then
        def_base="$def_strong"
    fi
    def_debian=$(latest_of_kind debian | awk -F'|' '{print $2}')
    if [[ -n "$def_base" && -n "$def_strong" && -n "$def_debian" ]]; then
        info "Auto-resolved latest upstream tags: base=${def_base}, strong=${def_strong}, debian=${def_debian}"
        apply_release_choice "$def_base" "$def_strong" "$def_debian"
    fi
}

# ─── Interactive configuration ────────────────────────────────────────────────
if should_run_interactive && [[ "$SKIP_RESOLVE" != true ]]; then
    run_interactive_config
elif [[ "$SKIP_RESOLVE" != true && -z "$RELEASE_TAG_FLAG" && -z "$STRONG_TAG_FLAG" ]]; then
    resolve_noninteractive_tags
fi

info "CPU vendor: $(detect_cpu_vendor | tr '[:lower:]' '[:upper:]')"
info "Kernel: $(uname -r)"
info "Working directory: ${WORK_DIR}"
info "Base release tag:  ${RELEASE_TAG}"
if [[ "$ENABLE_STRONG" == true ]]; then
    info "Strong overlay tag: ${STRONG_TAG}"
else
    info "Strong overlay:     disabled (--no-strong)"
fi
info "Debian ROM tag:    ${DEBIAN_TAG}"

mkdir -p "${WORK_DIR}" "${BACKUP_DIR}"

###############################################################################
# STEP 1: Set MAC Address Prefix at Datacenter level
###############################################################################
echo ""
info "═══ Step 1/12: MAC Address Prefix ═══"
record_step "step_1"

if [[ -f "$DATACENTER_CFG" ]]; then
    if grep -q "^mac_prefix:" "$DATACENTER_CFG" 2>/dev/null; then
        current_mac=$(grep "^mac_prefix:" "$DATACENTER_CFG" | awk '{print $2}')
        if [[ "$current_mac" == "$MAC_PREFIX" ]]; then
            ok "MAC prefix already set to ${MAC_PREFIX}"
        else
            warn "Changing MAC prefix from ${current_mac} to ${MAC_PREFIX}"
            sed -i "s/^mac_prefix:.*/mac_prefix: ${MAC_PREFIX}/" "$DATACENTER_CFG"
            validate_config_line "$DATACENTER_CFG" "^mac_prefix: ${MAC_PREFIX}" "MAC prefix after update"
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
record_step "step_2"

# Check disk space before downloading ~150MB of assets
check_disk_space "$WORK_DIR" 250

if [[ "$SKIP_DOWNLOAD" == true ]]; then
    warn "Skipping downloads (--skip-download). Expecting assets in ${WORK_DIR}"
else
    info "Base release: ${RELEASE_TAG}"
    # Download base debs from the latest tag
    download_asset "$QEMU_BASE_DEB"
    download_asset "$OVMF_BASE_DEB"

    # Download ACPI tables from the latest tag
    for aml in "${ACPI_FILES[@]}"; do
        download_asset "$aml"
    done

    # Download patch file (for reference / manual rebuilds)
    download_asset "$PATCH_FILE"

    # Download Strong .tgz (contains Strong debs + KVM modules) from STRONG_TAG.
    # The base release may not ship a Strong .tgz (upstream's intentional split),
    # so we always pull this one from ${STRONG_TAG}, not ${RELEASE_TAG}.
    if [[ "$ENABLE_STRONG" == true ]]; then
        info "Strong overlay release: ${STRONG_TAG}"
        download_asset "$STRONG_TGZ" "$STRONG_URL"
    else
        info "Strong overlay skipped (--no-strong). Sensor passthrough will not be available."
    fi
fi

###############################################################################
# STEP 3: Download Debian release assets (patched ROM/BIOS files only)
###############################################################################
echo ""
info "═══ Step 3/12: Download Debian Release Assets (Patched ROMs) ═══"
record_step "step_3"
info "The Debian release provides patched BIOS, EFI, and VGA ROM files"
info "with all VM-identifying strings ('QEMU', 'Bochs', 'SeaBIOS') removed."
info "These are overlaid after PVE deb installation to close firmware-scan gaps."

mkdir -p "$DEBIAN_DIR"

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
        download_asset "$f" "$DEBIAN_URL" "$DEBIAN_DIR" "debian/$f"
    done

    # Download patched EFI network boot ROMs
    for f in "${DEBIAN_EFI_ROMS[@]}"; do
        download_asset "$f" "$DEBIAN_URL" "$DEBIAN_DIR" "debian/$f"
    done

    # Download patched VGA BIOS ROMs
    for f in "${DEBIAN_VGA_ROMS[@]}"; do
        download_asset "$f" "$DEBIAN_URL" "$DEBIAN_DIR" "debian/$f"
    done

    # Download SeaBIOS patch (reference only — not applied, the ROMs are pre-compiled)
    # download_asset "$SEABIOS_PATCH" "$DEBIAN_URL" "$DEBIAN_DIR"

    # Download ACPI tables from Debian release too (may be newer)
    for aml in "${ACPI_FILES[@]}"; do
        download_asset "$aml" "$DEBIAN_URL" "$DEBIAN_DIR" "debian/$aml"
    done
fi

###############################################################################
# STEP 4: Backup stock packages
###############################################################################
echo ""
info "═══ Step 4/12: Backup Stock Packages ═══"
record_step "step_4"

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
record_step "step_5"

info "Installing ${QEMU_BASE_DEB} ..."
if dry_guard "apt-get install -y ${WORK_DIR}/${QEMU_BASE_DEB}"; then
    apt-get install -y "${WORK_DIR}/${QEMU_BASE_DEB}" \
        || fail "Failed to install ${QEMU_BASE_DEB} — run 'apt-get install -f' to resolve dependencies"
fi
ok "Base QEMU anti-detection package installed"

info "Installing ${OVMF_BASE_DEB} ..."
if dry_guard "apt-get install -y ${WORK_DIR}/${OVMF_BASE_DEB}"; then
    apt-get install -y "${WORK_DIR}/${OVMF_BASE_DEB}" \
        || fail "Failed to install ${OVMF_BASE_DEB} — run 'apt-get install -f' to resolve dependencies"
fi
ok "Base OVMF anti-detection package installed"

###############################################################################
# STEP 6: Extract & install Strong build (skipped with --no-strong)
###############################################################################
echo ""
info "═══ Step 6/12: Extract & Install Strong Build ═══"
record_step "step_6"

STRONG_DIR="${WORK_DIR}/strong"
if [[ "$ENABLE_STRONG" != true ]]; then
    info "Skipped (--no-strong). Sensor passthrough will be unavailable; kernel will not be pinned."
else
    mkdir -p "$STRONG_DIR"

    info "Extracting ${STRONG_TGZ} ..."
    tar -xzf "${WORK_DIR}/${STRONG_TGZ}" -C "$STRONG_DIR" --strip-components=0 \
        || fail "Failed to extract ${STRONG_TGZ} — archive may be corrupt. Re-run without --skip-download."

    # Find the Strong debs inside the extracted tree. The filenames are reliable
    # (pve-qemu-kvm*Strong*.deb and pve-edk2*Strong*.deb), so just glob by name.
    # -print -quit gives us a single match without piping into head (which
    # would SIGPIPE find under pipefail and abort the script).
    STRONG_QEMU_PATH=$(find "$STRONG_DIR" -name "pve-qemu-kvm*Strong*.deb" -print -quit 2>/dev/null || true)
    STRONG_OVMF_PATH=$(find "$STRONG_DIR" -name "pve-edk2*Strong*.deb" -print -quit 2>/dev/null || true)

    if [[ -n "$STRONG_QEMU_PATH" ]]; then
        info "Installing Strong QEMU: $(basename "$STRONG_QEMU_PATH") ..."
        if dry_guard "apt-get install -y $STRONG_QEMU_PATH"; then
            apt-get install -y "$STRONG_QEMU_PATH" \
                || fail "Failed to install Strong QEMU — run 'apt-get install -f' to resolve dependencies"
        fi
        ok "Strong QEMU package installed"
    else
        warn "Strong QEMU .deb not found in .tgz — skipping (base install still active)"
    fi

    if [[ -n "$STRONG_OVMF_PATH" ]]; then
        info "Installing Strong OVMF: $(basename "$STRONG_OVMF_PATH") ..."
        if dry_guard "apt-get install -y $STRONG_OVMF_PATH"; then
            apt-get install -y "$STRONG_OVMF_PATH" \
                || fail "Failed to install Strong OVMF — run 'apt-get install -f' to resolve dependencies"
        fi
        ok "Strong OVMF package installed"
    else
        warn "Strong OVMF .deb not found in .tgz — skipping (base install still active)"
    fi
fi

# Install virt-fw-vars for NVRAM anti-detection (host EFI variable injection)
# The deploy script uses this to populate the VM's OVMF NVRAM with real host
# Secure Boot certificates, defeating VMAware's NVRAM check (100pts).
if ! command -v virt-fw-vars &>/dev/null; then
    info "Installing python3-virt-firmware (needed for NVRAM anti-detection) ..."
    apt-get install -y python3-virt-firmware 2>&1 | tail -5 \
        || pip3 install virt-firmware 2>&1 | tail -3 \
        || warn "Could not install virt-firmware — NVRAM injection in deploy script will be skipped"
    if command -v virt-fw-vars &>/dev/null; then
        ok "virt-fw-vars installed (NVRAM anti-detection ready)"
    fi
else
    ok "virt-fw-vars already installed"
fi

# Install iasl (ACPI compiler) for PIT SSDT generation
# The deploy script loads a custom PIT SSDT so the guest exposes the legacy ISA
# 8254 Programmable Interval Timer (hardware ID PNP0100) that real PCs advertise
# in ACPI but QEMU's q35 generated DSDT omits. iasl compiles the ASL into AML.
if ! command -v iasl &>/dev/null; then
    info "Installing acpica-tools (needed for PIT SSDT compilation) ..."
    apt-get install -y acpica-tools 2>&1 | tail -5 \
        || warn "Could not install acpica-tools — PIT SSDT generation will be skipped"
    if command -v iasl &>/dev/null; then
        ok "iasl installed (PIT SSDT compilation ready)"
    fi
else
    ok "iasl already installed"
fi

###############################################################################
# STEP 7: Overlay Debian release patched ROM/BIOS/VGA files
###############################################################################
echo ""
info "═══ Step 7/12: Overlay Patched Debian ROM/BIOS Files ═══"
record_step "step_7"
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

# Helper: overlay a set of ROM files from the Debian release into PVE's ROM dirs.
# Backs up stock versions on first run; skips missing source files gracefully.
overlay_debian_roms() {
    local label="$1"; shift
    local -a files=("$@")
    local f
    for f in "${files[@]}"; do
        if [[ -f "${DEBIAN_DIR}/${f}" ]]; then
            for rom_dir in "$QEMU_ROM_DIR" "$QEMU_ROM_DIR_ALT"; do
                if [[ -f "${rom_dir}/${f}" && ! -f "${BACKUP_DIR}/${f}.stock" ]]; then
                    cp "${rom_dir}/${f}" "${BACKUP_DIR}/${f}.stock"
                fi
                if dry_guard "cp ${DEBIAN_DIR}/${f} → ${rom_dir}/"; then
                    cp "${DEBIAN_DIR}/${f}" "${rom_dir}/${f}"
                    chmod 644 "${rom_dir}/${f}"
                fi
            done
            ok "Overlaid patched ${label}: ${f}"
        else
            warn "Missing Debian asset: ${f}"
        fi
    done
}

# ── Overlay patched BIOS ROMs (SeaBIOS — removes QEMU/Bochs/SeaBIOS strings) ──
overlay_debian_roms "BIOS" "${DEBIAN_BIOS_FILES[@]}"

# ── Overlay patched EFI network boot ROMs ──
overlay_debian_roms "EFI ROM" "${DEBIAN_EFI_ROMS[@]}"

# ── Overlay patched VGA BIOS ROMs ──
overlay_debian_roms "VGA BIOS" "${DEBIAN_VGA_ROMS[@]}"

ok "Debian release ROM/BIOS overlay complete (PVE/Strong QEMU binary preserved)"

# ── Install custom boot splash (defeats VMAware BOOT_LOGO CRC32 detection) ──
# The PVE build patches fw_cfg.c to load /usr/share/kvm/bootsplash.jpg instead of
# the default EDK2/TianoCore logo. CRC32 0x110350C5 = stock OVMF boot logo (100pts).
# Downloaded from main branch (not a release asset).
BOOTSPLASH_URL_BASE="https://raw.githubusercontent.com/AICodo/pve-emu-realpc/main"
if [[ ! -f "$BOOTSPLASH_DEST" ]]; then
    if [[ "$SKIP_DOWNLOAD" != true ]]; then
        download_asset "bootsplash.jpg" "$BOOTSPLASH_URL_BASE" "/usr/share/kvm" "bootsplash (anti-BOOT_LOGO)"
        if [[ -f "$BOOTSPLASH_DEST" ]]; then
            # Also copy to /usr/share/qemu/ for compatibility
            cp "$BOOTSPLASH_DEST" "${QEMU_ROM_DIR_ALT}/bootsplash.jpg" 2>/dev/null || true
            ok "Boot splash installed: ${BOOTSPLASH_DEST}"
        fi
    else
        warn "bootsplash.jpg missing and --skip-download set — BOOT_LOGO detection may trigger"
    fi
else
    ok "Boot splash already installed: ${BOOTSPLASH_DEST}"
fi

###############################################################################
# STEP 8: Install patched KVM kernel module
###############################################################################
echo ""
info "═══ Step 8/12: Install Patched KVM Kernel Module ═══"
record_step "step_8"

CPU_VENDOR=$(detect_cpu_vendor)
KERNEL_VER=$(uname -r)

if [[ "$ENABLE_STRONG" != true ]]; then
    info "Skipped (--no-strong). Host kvm.ko unchanged; running on stock module."
    KVM_MODULE_SRC=""
else

# The .tgz contains kvm.ko files named like: kvm.ko.6.17.9-1-intel / kvm.ko.6.17.9-1-amd
# We need to find the one matching our kernel and CPU vendor
info "Looking for KVM module matching kernel ${KERNEL_VER} and CPU vendor ${CPU_VENDOR} ..."

# Search for matching module
KVM_MODULE_SRC=""

if [[ ! -d "$STRONG_DIR" ]]; then
    warn "Strong directory ${STRONG_DIR} not found — was --skip-download used without pre-staged assets?"
    warn "Skipping KVM module installation. Run without --skip-download to fetch the Strong .tgz."
else
# First try: exact kernel version match with CPU vendor suffix.
# Use -print -quit instead of `| head -1` so find doesn't SIGPIPE under pipefail.
KVM_MODULE_SRC=$(find "$STRONG_DIR" -name "kvm.ko.*${CPU_VENDOR}" -print -quit 2>/dev/null || true)

if [[ -z "$KVM_MODULE_SRC" ]]; then
    # Second try: any kvm.ko with the vendor name
    KVM_MODULE_SRC=$(find "$STRONG_DIR" -name "kvm.ko*${CPU_VENDOR}*" -print -quit 2>/dev/null || true)
fi
fi  # [[ -d "$STRONG_DIR" ]]

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
    if [[ -n "$MODULE_KERNEL_VER" ]] && ! echo "$KERNEL_VER" | grep -qF "$MODULE_KERNEL_VER"; then
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
        if dry_guard "install kvm.ko → ${KERNEL_VER}"; then
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
            if modprobe kvm 2>/dev/null; then
                ok "Patched KVM module loaded successfully"
            else
                # Check vermagic to determine if failure is permanent or transient.
                # NOTE: this block runs at top-level script scope (Step 8 is not a
                # function), so `local` is illegal here — under `set -e` it would
                # abort the script with "local: can only be used in a function"
                # right when we're trying to print the diagnostic. Use a plain var.
                mod_vermagic=$(modinfo -F vermagic "$KVM_DEST" 2>/dev/null || echo "")
                if [[ -n "$mod_vermagic" ]] && ! echo "$mod_vermagic" | grep -qF "$KERNEL_VER"; then
                    warn "KVM module FAILED to load: version magic mismatch."
                    warn "  Module built for: $(echo "$mod_vermagic" | awk '{print $1}')"
                    warn "  Running kernel:   ${KERNEL_VER}"
                    warn "  This will NOT fix itself after reboot. Options:"
                    warn "  1. Re-run with --no-strong to skip sensor passthrough"
                    warn "  2. Install the matching kernel: proxmox-kernel-${KERNEL_VER}"
                    warn "  3. Check upstream for a Strong build against your kernel"
                else
                    warn "Failed to load KVM module — may be a transient issue."
                    warn "After reboot, verify with: lsmod | grep kvm"
                fi
            fi
        fi
        fi  # dry_guard

        ok "Patched KVM module installed for ${CPU_VENDOR}"
    fi
fi

fi  # end of "if [[ $ENABLE_STRONG == true ]]" block for Step 8

###############################################################################
# STEP 9: Place ACPI table files
###############################################################################
echo ""
info "═══ Step 9/12: Place ACPI Table Files ═══"
record_step "step_9"

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

# Generate PIT SSDT — expose the legacy ISA Programmable Interval Timer (PNP0100)
#
# Real PCs advertise the 8254 PIT (hardware ID PNP0100) in their ACPI tables and
# Windows enumerates it as a system device. QEMU's q35 generated DSDT omits it,
# leaving a device-tree anomaly that hardware-enumeration fingerprinting can flag.
# We compile a minimal SSDT that defines PNP0100 at the standard PIT I/O ports
# (0x40–0x43, IRQ 0) so the guest device tree matches a physical machine.
# NOTE: this addresses *device enumeration*, not timing-based "clock" probes
# (RDTSC/QPC skew) — those are handled by the patched KVM/QEMU build, not ACPI.
info "Generating PIT SSDT (exposes legacy ISA PIT / PNP0100) ..."
PIT_ASL="${WORK_DIR}/pit.asl"
PIT_AML="${ACPI_DIR}/pit.aml"

if command -v iasl &>/dev/null; then
    cat > "$PIT_ASL" << 'PITEOF'
DefinitionBlock ("pit.aml", "SSDT", 2, "REALPC", "PIT     ", 0x00000001)
{
    Scope (\_SB)
    {
        Device (PIT0)
        {
            Name (_HID, EisaId ("PNP0100"))
            Method (_STA, 0, NotSerialized)
            {
                Return (0x0F)
            }
            Name (_CRS, ResourceTemplate ()
            {
                IO (Decode16, 0x0040, 0x0040, 0x01, 0x04)
                IRQNoFlags () {0}
            })
        }
    }
}
PITEOF
    # Non-fatal: a non-zero iasl exit (tool quirk, odd locale, etc.) must not abort
    # the whole setup at Step 9 — the [[ -f pit.aml ]] check below handles a missing
    # output gracefully and warns. Without `|| true`, set -e would kill the script.
    iasl -p "${WORK_DIR}/pit" "$PIT_ASL" &>/dev/null || true
    if [[ -f "${WORK_DIR}/pit.aml" ]]; then
        cp "${WORK_DIR}/pit.aml" "$PIT_AML"
        chmod 644 "$PIT_AML"
        ok "PIT SSDT compiled → ${PIT_AML} ($(stat -c%s "$PIT_AML") bytes)"
    else
        warn "iasl compilation failed — PIT SSDT not generated"
    fi
else
    warn "iasl (acpica-tools) not found — cannot generate PIT SSDT."
    warn "  Install with: apt-get install -y acpica-tools"
    warn "  Without it the guest won't expose the legacy ISA PIT (PNP0100)."
fi

###############################################################################
# STEP 10: iGPU Passthrough Setup (Intel / AMD) (optional)
###############################################################################
echo ""
if [[ "$ENABLE_IGPU" == true ]]; then
    IGPU_VENDOR=$(detect_cpu_vendor)
    info "═══ Step 10/12: iGPU Passthrough Setup (${IGPU_VENDOR^^}) ═══"
    record_step "step_10"

    # Download Intel iGPU ROM (Intel only — AMD doesn't need a custom ROM)
    if [[ "$IGPU_VENDOR" == "intel" ]]; then
        if [[ "$SKIP_DOWNLOAD" != true ]]; then
            mkdir -p "$IGPU_ROM_DIR"
            ROM_DEST="${IGPU_ROM_DIR}/${IGPU_ROM_FILE}"
            if [[ -f "$ROM_DEST" ]]; then
                ok "iGPU ROM already installed: ${ROM_DEST}"
            else
                download_asset "$IGPU_ROM_FILE" "$IGPU_ROM_URL" "$IGPU_ROM_DIR" "iGPU ROM: ${IGPU_ROM_FILE}"
                ok "iGPU ROM installed: ${ROM_DEST} ($(stat -c%s "$ROM_DEST") bytes)"
            fi
        else
            if [[ -f "${IGPU_ROM_DIR}/${IGPU_ROM_FILE}" ]]; then
                ok "iGPU ROM present: ${IGPU_ROM_DIR}/${IGPU_ROM_FILE}"
            else
                warn "iGPU ROM not found and --skip-download is set"
            fi
        fi
    else
        info "AMD iGPU — no custom ROM required (standard PCI passthrough)"
    fi

    # Configure IOMMU in GRUB (vendor-specific)
    GRUB_FILE="/etc/default/grub"
    if [[ -f "$GRUB_FILE" ]]; then
        if [[ "$IGPU_VENDOR" == "intel" ]]; then
            IOMMU_PARAM="intel_iommu=on"
        else
            IOMMU_PARAM="amd_iommu=on"
        fi
        GRUB_CHANGED=false
        if ! grep -q "${IOMMU_PARAM}" <(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE" 2>/dev/null) 2>/dev/null; then
            info "Enabling ${IGPU_VENDOR^^} IOMMU in GRUB (${IOMMU_PARAM}) ..."
            cp "$GRUB_FILE" "${BACKUP_DIR}/grub.default.igpu.bak" 2>/dev/null || true
            sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"\([^\"]*\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\\1 ${IOMMU_PARAM}\"/" "$GRUB_FILE"
            validate_config_line "$GRUB_FILE" "${IOMMU_PARAM}" "${IGPU_VENDOR^^} IOMMU in GRUB"
            GRUB_CHANGED=true
        fi
        # Add IOMMU passthrough mode — only passes assigned devices through IOMMU
        # (reduces overhead for non-passthrough devices vs translating all DMA)
        if ! grep -q "iommu=pt" <(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE" 2>/dev/null) 2>/dev/null; then
            sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"\([^\"]*\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\1 iommu=pt\"/" "$GRUB_FILE"
            validate_config_line "$GRUB_FILE" "iommu=pt" "IOMMU passthrough mode in GRUB"
            GRUB_CHANGED=true
        fi
        if [[ "$GRUB_CHANGED" == true ]]; then
            if command -v update-grub &>/dev/null; then
                update-grub 2>&1 | tail -3
            fi
            NEEDS_REBOOT=true
            ok "${IGPU_VENDOR^^} IOMMU + passthrough mode enabled (reboot required)"
        else
            ok "${IGPU_VENDOR^^} IOMMU already enabled in GRUB"
        fi
    fi

    # Blacklist GPU and audio drivers for VFIO passthrough (vendor-specific)
    IGPU_BLACKLIST_FILE="/etc/modprobe.d/pve-realpc-igpu.conf"
    if [[ ! -f "$IGPU_BLACKLIST_FILE" ]]; then
        if dry_guard "create ${IGPU_BLACKLIST_FILE}"; then
        if [[ "$IGPU_VENDOR" == "intel" ]]; then
            cat > "$IGPU_BLACKLIST_FILE" <<'IGPUEOF'
# Blacklist Intel GPU and audio drivers to allow VFIO passthrough
# Created by pve-realpc-setup.sh --igpu
blacklist i915
blacklist snd_hda_intel
options vfio_iommu_type1 allow_unsafe_interrupts=1
IGPUEOF
            ok "Created ${IGPU_BLACKLIST_FILE} (blacklist i915 + snd_hda_intel)"
        else
            cat > "$IGPU_BLACKLIST_FILE" <<'IGPUEOF'
# Blacklist AMD GPU and audio drivers to allow VFIO passthrough
# Created by pve-realpc-setup.sh --igpu
# Note: AMD GPU audio uses the snd_hda_intel module (Intel HDA standard)
blacklist amdgpu
blacklist radeon
blacklist snd_hda_intel
options vfio_iommu_type1 allow_unsafe_interrupts=1
IGPUEOF
            ok "Created ${IGPU_BLACKLIST_FILE} (blacklist amdgpu + radeon + snd_hda_intel)"
        fi
        fi  # dry_guard

        # Ensure VFIO modules load at boot so VFIO claims the devices before other drivers
        VFIO_MODULES_FILE="/etc/modules-load.d/pve-realpc-vfio.conf"
        if [[ ! -f "$VFIO_MODULES_FILE" ]]; then
            if dry_guard "create ${VFIO_MODULES_FILE}"; then
            cat > "$VFIO_MODULES_FILE" <<'VFIOEOF'
# Load VFIO modules at boot for iGPU passthrough
# Created by pve-realpc-setup.sh --igpu
vfio
vfio_iommu_type1
vfio_pci
VFIOEOF
            ok "Created ${VFIO_MODULES_FILE} (vfio, vfio_iommu_type1, vfio_pci)"
            fi  # dry_guard
        else
            ok "VFIO modules already configured: ${VFIO_MODULES_FILE}"
        fi

        # Rebuild initramfs so VFIO claims the devices at boot
        info "Rebuilding initramfs for VFIO changes ..."
        if dry_guard "update-initramfs -u -k all"; then
            if update-initramfs -u -k all; then
                ok "Initramfs updated"
            else
                warn "Initramfs rebuild failed — VFIO may not claim devices after reboot"
                warn "Check /boot for available space and kernel consistency."
            fi
        fi
        NEEDS_REBOOT=true
    else
        ok "iGPU blacklist already configured: ${IGPU_BLACKLIST_FILE}"
    fi
else
    info "═══ Step 10/12: iGPU Passthrough Setup ═══"
    info "Skipped (use --igpu to enable iGPU passthrough — supports Intel and AMD)"
fi

###############################################################################
# STEP 11: Pin packages (prevent apt upgrade from overwriting)
###############################################################################
echo ""
info "═══ Step 11/12: APT Package Pinning ═══"
record_step "step_11"

PIN_FILE="/etc/apt/preferences.d/pve-realpc-hold"
if [[ "$SKIP_PIN" == true ]]; then
    warn "Skipping APT pinning (--skip-pin)"
elif dry_guard "create ${PIN_FILE} + apt-mark hold"; then
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
record_step "step_12"

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
        ROM_OK=$((ROM_OK+1))
    else
        warn "ROM: ${rom_file} MISSING — firmware string scan may still detect VM"
        ROM_MISSING=$((ROM_MISSING+1))
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
            if command -v strings &>/dev/null; then
                if strings "${rom_dir}/${check_rom}" 2>/dev/null | grep -qi "QEMU\|Bochs\|SeaBIOS"; then
                    warn "UNPATCHED: ${rom_dir}/${check_rom} still contains VM strings!"
                else
                    ok "Verified: ${check_rom} is clean (no VM strings)"
                fi
            else
                warn "Cannot verify ROM strings — 'strings' command not found (install binutils)"
            fi
            break
        fi
    done
done

# Verify VMware/VirtIO VGA ROMs (v10.2.1+ / v11 recommend VMware display, but
# the Debian release only provides stdvga + qxl ROMs. vgabios-vmware.bin and
# vgabios-virtio.bin come from the PVE deb and may still contain VM strings
# since PVE ships pre-built ROM blobs that bypass the sedPatch process.)
if command -v strings &>/dev/null; then
    for extra_rom in "vgabios-vmware.bin" "vgabios-virtio.bin"; do
        for rom_dir in "$QEMU_ROM_DIR" "$QEMU_ROM_DIR_ALT"; do
            if [[ -f "${rom_dir}/${extra_rom}" ]]; then
                if strings "${rom_dir}/${extra_rom}" 2>/dev/null | grep -qi "QEMU\|Bochs\|SeaBIOS"; then
                    warn "${extra_rom} contains VM strings (not overlaid from Debian release)"
                    warn "  → The Debian build doesn't produce ${extra_rom}. If using --vga vmware or"
                    warn "    --vga virtio, firmware string scans may still detect VM signatures."
                    warn "  → Mitigation: use --vga std (overlaid) or GPU passthrough (--vga none)."
                else
                    ok "Verified: ${extra_rom} is clean (no VM strings)"
                fi
                break
            fi
        done
    done
fi

# Check ACPI files
for aml in "${ACPI_FILES[@]}"; do
    if [[ -f "${ACPI_DIR}/${aml}" ]]; then
        ok "ACPI: ${aml} present ($(stat -c%s "${ACPI_DIR}/${aml}") bytes)"
    else
        warn "ACPI: ${aml} missing"
    fi
done

# Check KVM module (KERNEL_VER is updated to the target kernel after downgrade)
if [[ "$ENABLE_STRONG" != true ]]; then
    info "kvm.ko check skipped (--no-strong) — host stock module remains in place"
elif [[ -f "/lib/modules/${KERNEL_VER}/kernel/arch/x86/kvm/kvm.ko" ]]; then
    KVM_SIZE=$(stat -c%s "/lib/modules/${KERNEL_VER}/kernel/arch/x86/kvm/kvm.ko")
    ok "Patched kvm.ko present for kernel ${KERNEL_VER} (${KVM_SIZE} bytes)"
else
    warn "Patched kvm.ko NOT found in /lib/modules/${KERNEL_VER}/kernel/arch/x86/kvm/"
fi

# Check MAC prefix
if grep -q "mac_prefix: ${MAC_PREFIX}" "$DATACENTER_CFG" 2>/dev/null; then
    ok "Datacenter MAC prefix: ${MAC_PREFIX}"
fi

# Check boot splash (BOOT_LOGO anti-detection)
if [[ -f "$BOOTSPLASH_DEST" ]]; then
    ok "Boot splash: bootsplash.jpg present ($(stat -c%s "$BOOTSPLASH_DEST") bytes)"
else
    warn "Boot splash: bootsplash.jpg MISSING from /usr/share/kvm/"
    warn "VMAware BOOT_LOGO CRC32 check (100pts) may trigger with stock EDK2 logo"
fi

# Check virt-fw-vars (NVRAM anti-detection)
if command -v virt-fw-vars &>/dev/null; then
    ok "virt-fw-vars available (NVRAM injection ready for deploy script)"
else
    warn "virt-fw-vars not found — deploy script cannot inject host EFI variables"
    warn "Install with: apt install python3-virt-firmware"
fi

# Check PIT SSDT (legacy ISA PIT / PNP0100 exposure)
if [[ -f "${ACPI_DIR}/pit.aml" ]]; then
    ok "PIT SSDT: pit.aml present ($(stat -c%s "${ACPI_DIR}/pit.aml") bytes)"
else
    warn "PIT SSDT: pit.aml missing — guest won't expose the legacy ISA PIT (PNP0100)"
    if ! command -v iasl &>/dev/null; then
        warn "Install iasl: apt install acpica-tools, then re-run this script"
    fi
fi

# Check iGPU setup
if [[ "$ENABLE_IGPU" == true ]]; then
    igpu_vendor=$(detect_cpu_vendor)
    if [[ "$igpu_vendor" == "intel" ]]; then
        if [[ -f "${IGPU_ROM_DIR}/${IGPU_ROM_FILE}" ]]; then
            ok "iGPU ROM: ${IGPU_ROM_FILE} present ($(stat -c%s "${IGPU_ROM_DIR}/${IGPU_ROM_FILE}") bytes)"
        else
            warn "iGPU ROM: ${IGPU_ROM_FILE} missing from ${IGPU_ROM_DIR}/"
        fi
    else
        ok "AMD iGPU: no custom ROM needed"
    fi
    if [[ -f "/etc/modprobe.d/pve-realpc-igpu.conf" ]]; then
        ok "iGPU blacklist configured"
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
if [[ "$ENABLE_STRONG" == true ]]; then
_bx "$GREEN" "Strong QEMU + OVMF installed (sensor passthrough)"
_bx "$GREEN" "Patched KVM module installed (${CPU_VENDOR}, kernel ${KERNEL_VER})"
else
_bx "$GREEN" "Base QEMU + OVMF installed (--no-strong, no sensor passthrough)"
_bx "$GREEN" "Host kvm.ko unchanged (no kernel pin required)"
fi
_bx "$GREEN" "Anti-detection patch active (identical on both v11 tags)"
_bx "$GREEN" "Patched ROM/BIOS/VGA overlaid (Debian ${DEBIAN_TAG})"
_bx "$GREEN" "ACPI tables placed in /root/"
_bx "$GREEN" "MAC prefix set to ${MAC_PREFIX}"
_bx "$GREEN" "Packages pinned against apt upgrades"
if command -v virt-fw-vars &>/dev/null; then
_bx "$GREEN" "virt-fw-vars ready (host EFI→VM NVRAM injection)"
fi
if [[ -f "$BOOTSPLASH_DEST" ]]; then
_bx "$GREEN" "Boot splash installed (defeats BOOT_LOGO CRC32 detection)"
fi
if [[ -f "${ACPI_DIR}/pit.aml" ]]; then
_bx "$GREEN" "PIT SSDT compiled (exposes legacy ISA PIT / PNP0100)"
fi
if [[ "$ENABLE_IGPU" == true ]]; then
igpu_v=$(detect_cpu_vendor)
if [[ "$igpu_v" == "intel" ]]; then
_bx "$GREEN" "Intel iGPU ROM installed (/usr/share/kvm/)"
_bx "$GREEN" "Intel IOMMU enabled + i915/snd_hda_intel blacklisted"
else
_bx "$GREEN" "AMD IOMMU enabled + amdgpu/radeon/snd_hda_intel blacklisted"
fi
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
echo ""
if [[ "$NEEDS_REBOOT" == true ]]; then
    warn "Reboot now, then run: bash pve-realpc-deploy-vm.sh"
else
    info "Ready! Next step: bash pve-realpc-deploy-vm.sh"
fi
