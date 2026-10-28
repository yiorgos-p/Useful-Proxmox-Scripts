#!/bin/bash
# =============================================================================
# Proxmox VE ZFS Disk Replacement Helper
# =============================================================================
# Works out how to replace a failed disk in a ZFS pool and, with --apply,
# does it. Without --apply it only prints the plan and changes nothing.
#
# What it figures out on its own:
#   - which pool is degraded and which device failed
#   - which disk is the new one (blank, not in any pool, not mounted, big
#     enough) — or takes it from -n
#   - whether the pool uses whole disks (data pools) or partitions (the
#     PVE installer's rpool: BIOS boot + ESP + ZFS), and copies the
#     partition layout from a healthy disk in the same vdev if so
#   - whether the new disk needs to be made bootable, and how
#     (proxmox-boot-tool with UEFI or GRUB, or plain grub-install)
#
# The plan, for a partitioned boot pool:
#   1. sgdisk --zap-all <new>              wipe old partition tables
#   2. sgdisk <healthy> -R <new>           copy the partition layout
#   3. sgdisk -G <new>                     give the copy new GUIDs
#   4. zpool replace -f <pool> <old> <new-partN>
#   5. proxmox-boot-tool format/init <new ESP>, then clean
# For a whole-disk pool, it's just zap + zpool replace.
#
# With --apply it shows the plan, asks you to type the new disk's name,
# then runs every step, stopping at the first one that fails. The resilver
# itself runs in the background afterwards.
#
# Usage:
#   ./pve-zfs-replace-disk.sh [-p POOL] [-o OLD] [-n NEW] [--apply]
#     -p POOL    pool to fix (default: the one degraded pool)
#     -o OLD     failed device, as zpool status shows it (name or GUID)
#     -n NEW     new disk, e.g. /dev/sdc or /dev/disk/by-id/ata-...
#     --apply    run the plan (asks for confirmation first)
#
# Exit codes:
#   0 = plan printed, or applied successfully
#   1 = nothing to replace (no failed device found)
#   2 = refused (a safety check failed) or a step failed
#   3 = could not run (not root, no ZFS, bad arguments)
#
# =============================================================================

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; NC='\033[0m'; BOLD='\033[1m'

ESP_TYPE=c12a7328-f81f-11d2-ba4b-00a0c93ec93b
BIOS_BOOT_TYPE=21686148-6449-6e6f-744e-656564454649

# ── helpers ──────────────────────────────────────────────────────────────────
hr()  { echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"; }
ok()  { echo -e "  ${GREEN}[OK]${NC}  $*"; }
bad() { echo -e "  ${RED}[NO]${NC}  $*"; }
note(){ echo -e "  ${YELLOW}[NOTE]${NC} $*"; }
die() { echo -e "${RED}$1${NC}" >&2; exit "${2:-2}"; }

usage() {
    echo "Usage: $0 [-p POOL] [-o OLD] [-n NEW] [--apply]"
    echo "  -p POOL    pool to fix (default: the one degraded pool)"
    echo "  -o OLD     failed device, as zpool status shows it (name or GUID)"
    echo "  -n NEW     new disk, e.g. /dev/sdc or /dev/disk/by-id/ata-..."
    echo "  --apply    run the plan (asks for confirmation first)"
}

# A vdev name from zpool status -> real device node, empty if not present.
resolve() {
    local d
    for d in /dev/disk/by-id /dev/disk/by-path /dev/disk/by-partuuid /dev/disk/by-uuid /dev/disk/by-vdev /dev/mapper /dev; do
        [[ -e "$d/$1" ]] && { readlink -f "$d/$1"; return; }
    done
    [[ "$1" == /dev/* && -e "$1" ]] && readlink -f "$1"
}

# Partition -> its whole disk; a whole disk -> itself.
parent_disk() {
    local pk
    pk=$(lsblk -no PKNAME "$1" 2>/dev/null | head -1)
    if [[ -n "$pk" ]]; then echo "/dev/$pk"; else echo "$1"; fi
}

# Most readable /dev/disk/by-id name for a disk: model_serial style
# (ata-, nvme-, scsi-) before wwn-, as the PVE installer does.
byid() {
    local disk links l
    disk=$(readlink -f "$1")
    links=$(for l in /dev/disk/by-id/*; do
                [[ "$l" == *-part[0-9]* ]] && continue
                [[ "$(readlink -f "$l")" == "$disk" ]] && echo "$l"
            done)
    for l in $(grep -E '/(ata|nvme|scsi|usb)-' <<< "$links" | grep -vE '/nvme-eui\.|/scsi-[0-9]') \
             $(grep '/wwn-' <<< "$links") $links; do
        echo "$l"; return
    done
}

# Path of partition N on a disk given as by-id or kernel name.
part_path() {
    if [[ "$1" == /dev/disk/by-id/* ]]; then echo "$1-part$2"
    elif [[ "$1" =~ [0-9]$ ]]; then echo "${1}p$2"
    else echo "$1$2"; fi
}

# Wait for a device node to appear after repartitioning (udev is async).
wait_for() {
    local i
    for i in $(seq 20); do
        [[ -e "$1" ]] && return 0
        udevadm settle 2>/dev/null; sleep 0.5
    done
    echo "  $1 didn't appear" >&2
    return 1
}

size_of() { lsblk -bdno SIZE "$1" 2>/dev/null; }
hsize()   { awk -v b="${1:-0}" 'BEGIN{ printf "%.0f GB", b/1e9 }'; }

# ── arguments ────────────────────────────────────────────────────────────────
POOL=""; OLD=""; NEW=""; APPLY=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p) POOL="$2"; shift 2 ;;
        -o) OLD="$2"; shift 2 ;;
        -n) NEW="$2"; shift 2 ;;
        --apply) APPLY=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage; exit 3 ;;
    esac
done

[[ $EUID -ne 0 ]] && die "Run as root." 3
command -v zpool &>/dev/null || die "zpool not found — is ZFS installed?" 3
for c in sgdisk lsblk; do
    command -v "$c" &>/dev/null || die "$c not found (apt install gdisk util-linux)" 3
done

echo ""
echo -e "${BOLD}PVE ZFS Disk Replacement — $(date)${NC}"
echo "Host: $(hostname) | Mode: $($APPLY && echo "APPLY (will ask before changing anything)" || echo "plan only, nothing will be changed")"
echo ""

# =============================================================================
# STEP 1 – FIND THE FAILED DEVICE
# =============================================================================
# Config section of zpool status as "depth<TAB>name<TAB>state<TAB>rest".
# Each indent level is two spaces after the leading tab.
pool_tree() {
    zpool status "$1" 2>/dev/null | awk '
        /^config:/ { c = 1; next }
        c && /^errors:/ { exit }
        c && $1 == "NAME" { h = 1; next }
        c && h && NF {
            match($0, /^[ \t]*/)
            rest = ""; for (i = 6; i <= NF; i++) rest = rest " " $i
            printf "%d\t%s\t%s\t%s\n", (RLENGTH - 1) / 2, $1, $2, rest
        }'
}

hr; echo -e "${BOLD}║  1. FAILED DEVICE${NC}"; hr

# Candidates: leaf vdevs in a failed state, outside cache/spares, whose
# replacement isn't already under way.
declare -a F_POOL F_OLD F_STATE F_WAS F_SIB F_PARENT
pools=$POOL
[[ -z "$pools" ]] && pools=$(zpool list -Ho name 2>/dev/null)
[[ -z "$pools" ]] && die "No imported ZFS pools." 1
for p in $pools; do
    zpool list "$p" &>/dev/null || die "No pool named '$p'." 3
    mapfile -t T < <(pool_tree "$p")
    n=${#T[@]}
    section=""
    for ((i = 0; i < n; i++)); do
        IFS=$'\t' read -r d name state rest <<< "${T[i]}"
        (( d == 0 )) && { section=$name; continue; }
        [[ "$section" == cache || "$section" == spares ]] && continue
        # Leaf = next line isn't deeper.
        if (( i + 1 < n )); then
            nd=$(cut -f1 <<< "${T[i+1]}")
            (( nd > d )) && continue
        fi
        [[ "$state" =~ ^(FAULTED|UNAVAIL|REMOVED|OFFLINE)$ ]] || continue
        [[ -n "$OLD" && "$name" != "$OLD" ]] && continue
        # Parent vdev: nearest line above that's one level up.
        pi=-1
        for ((j = i - 1; j >= 0; j--)); do
            (( $(cut -f1 <<< "${T[j]}") == d - 1 )) && { pi=$j; break; }
        done
        parent=$(cut -f2 <<< "${T[pi]}")
        if [[ "$parent" == replacing-* || "$parent" == spare-* ]]; then
            note "$p: $name is already being replaced ($parent) — check progress with: zpool status $p"
            continue
        fi
        # ONLINE siblings under the same parent. A failed top-level vdev
        # (no parent but the pool) has no redundancy to rebuild from.
        sib=""
        if (( d > 1 )); then
            for ((j = pi + 1; j < n; j++)); do
                IFS=$'\t' read -r sd sname sstate _ <<< "${T[j]}"
                (( sd < d )) && break
                (( sd == d )) && [[ "$sstate" == ONLINE && "$sname" != "$name" ]] && { sib=$sname; break; }
            done
        fi
        F_POOL+=("$p"); F_OLD+=("$name"); F_STATE+=("$state"); F_WAS+=("${rest# }")
        F_SIB+=("$sib"); F_PARENT+=("$parent")
    done
done

if [[ ${#F_OLD[@]} -eq 0 ]]; then
    ok "No failed devices found${POOL:+ in $POOL}${OLD:+ matching $OLD} — nothing to replace"
    zpool status -x 2>/dev/null | sed 's/^/      /'
    exit 1
fi
if [[ ${#F_OLD[@]} -gt 1 ]]; then
    echo "  More than one failed device — pick one with -p POOL -o OLD:"
    for i in "${!F_OLD[@]}"; do
        echo "      -p ${F_POOL[i]} -o ${F_OLD[i]}   (${F_STATE[i]} ${F_WAS[i]})"
    done
    exit 2
fi
POOL=${F_POOL[0]}; OLD=${F_OLD[0]}; SIB=${F_SIB[0]}
echo "  Pool:   $POOL ($(zpool list -Ho health "$POOL"))"
echo "  Failed: $OLD — ${F_STATE[0]} ${F_WAS[0]} (in ${F_PARENT[0]})"
[[ -n "$SIB" ]] || die "  No healthy device left in ${F_PARENT[0]} to rebuild from — this needs a restore, not a replace."
echo "  Healthy member of the same vdev: $SIB"

# Is the failed disk still plugged in? Fine if the new disk went into a
# different slot, but worth knowing so the right one gets pulled later.
OLD_DEV=$(resolve "$OLD")
if [[ -n "$OLD_DEV" && -b "$OLD_DEV" ]]; then
    OLD_DISK=$(parent_disk "$OLD_DEV")
    note "The failed device is still attached as $OLD_DISK ($(lsblk -dno MODEL,SERIAL "$OLD_DISK" | xargs)). Pull it after the resilver if the new disk is in another slot."
fi

# =============================================================================
# STEP 2 – LAYOUT OF THE HEALTHY DISK
# =============================================================================
echo ""
hr; echo -e "${BOLD}║  2. POOL LAYOUT${NC}"; hr
SIB_DEV=$(resolve "$SIB")
[[ -n "$SIB_DEV" ]] || die "  Can't find the device for $SIB."
TEMPLATE=$(parent_disk "$SIB_DEV")
TEMPLATE_ID=$(byid "$TEMPLATE"); TEMPLATE_ID=${TEMPLATE_ID:-$TEMPLATE}
NEED_SIZE=$(size_of "$TEMPLATE")
echo "  Healthy disk: $TEMPLATE_ID ($(hsize "$NEED_SIZE"))"

ZPART=""; ESP_PART=""; BIOS_PART=""
if [[ "$SIB_DEV" == "$TEMPLATE" ]]; then
    MODE=whole
    echo "  Layout: whole disks — ZFS partitions the new disk itself"
else
    MODE=partitioned
    ZPART=$(cat "/sys/class/block/$(basename "$SIB_DEV")/partition")
    echo "  Layout: partitioned — ZFS is on partition $ZPART; the layout will be copied"
    # Partition types straight from the GPT (blkid -p), which doesn't
    # depend on udev's database the way lsblk's PARTTYPE column does.
    while read -r part; do
        num=$(cat "/sys/class/block/$(basename "$part")/partition" 2>/dev/null)
        ptype=$(blkid -p -s PART_ENTRY_TYPE -o value "$part" 2>/dev/null)
        [[ "$ptype" == "$ESP_TYPE" ]] && ESP_PART=$num
        [[ "$ptype" == "$BIOS_BOOT_TYPE" ]] && BIOS_PART=$num
    done < <(lsblk -lnpo NAME,TYPE "$TEMPLATE" | awk '$2 == "part" {print $1}')
    lsblk -o NAME,SIZE "$TEMPLATE" 2>/dev/null | sed 's/^/      /'
    echo "      ESP: partition ${ESP_PART:-none} | BIOS boot: partition ${BIOS_PART:-none}"
fi

# Boot setup: only matters if this pool holds the root filesystem.
ROOT_POOL=$(findmnt -no SOURCE / 2>/dev/null | cut -d/ -f1)
BOOT=none
if [[ "$MODE" == partitioned && "$POOL" == "$ROOT_POOL" ]]; then
    if [[ -n "$ESP_PART" && -f /etc/kernel/proxmox-boot-uuids ]]; then
        if [[ -d /sys/firmware/efi ]]; then BOOT=pbt-uefi; else BOOT=pbt-grub; fi
    elif [[ -n "$BIOS_PART" && ! -d /sys/firmware/efi ]]; then
        BOOT=grub-install
    fi
fi
case "$BOOT" in
    pbt-uefi)     echo "  Boot: root pool, proxmox-boot-tool, UEFI — the new disk's ESP (partition $ESP_PART) will be set up" ;;
    pbt-grub)     echo "  Boot: root pool, proxmox-boot-tool, legacy BIOS/GRUB — the new disk's ESP (partition $ESP_PART) will be set up" ;;
    grub-install) echo "  Boot: root pool, legacy GRUB without proxmox-boot-tool — grub-install on the new disk" ;;
    none)         [[ "$POOL" == "$ROOT_POOL" ]] && note "Root pool, but no ESP/BIOS boot partition found — boot setup skipped; check the new disk is bootable yourself" \
                                              || echo "  Boot: not the root pool — no boot setup needed" ;;
esac

# =============================================================================
# STEP 3 – THE NEW DISK
# =============================================================================
echo ""
hr; echo -e "${BOLD}║  3. NEW DISK${NC}"; hr

# Disks that belong to any imported pool, as real device nodes.
IN_POOLS=" $(zpool status -LP 2>/dev/null | grep -oE '/dev/[^[:space:]]+' | while read -r d; do parent_disk "$d"; done | sort -u | xargs) "
LVM_PVS=" $(pvs --noheadings -o pv_name 2>/dev/null | while read -r d; do parent_disk "$(readlink -f "$d")"; done | xargs) "

# Prints one line per check; returns the number of failed checks. "quiet"
# (used for auto-detection) prints nothing and also rejects any disk with
# partitions or signatures: only a blank disk is picked automatically. A
# disk named with -n may have old contents; they get wiped.
check_new() {
    local disk=$1 mode=$2 fails=0 msg
    say() { [[ "$mode" == quiet ]] || "$@"; }
    if [[ "$(lsblk -dno TYPE "$disk" 2>/dev/null)" != disk ]]; then
        say bad "$disk is not a whole disk"; return 1
    fi
    if [[ "$IN_POOLS" == *" $disk "* ]]; then say bad "part of an imported ZFS pool"; fails=$((fails + 1))
    else say ok "not in any imported ZFS pool"; fi
    if [[ "$disk" == "$TEMPLATE" ]]; then say bad "it's the healthy disk being copied from"; fails=$((fails + 1)); fi
    msg=$(lsblk -lnpo NAME,MOUNTPOINT "$disk" | awk 'NF == 2 {print $1 " on " $2}' | xargs)
    if [[ -n "$msg" ]]; then say bad "mounted or swap: $msg"; fails=$((fails + 1))
    else say ok "nothing on it is mounted"; fi
    if [[ "$LVM_PVS" == *" $disk "* ]] || grep -qw "$(basename "$disk")" /proc/mdstat 2>/dev/null \
       || [[ -n "$(ls -A "/sys/block/$(basename "$disk")/holders" 2>/dev/null)" ]]; then
        say bad "in use by LVM, mdraid or device-mapper"; fails=$((fails + 1))
    else say ok "not used by LVM, mdraid or device-mapper"; fi
    local size; size=$(size_of "$disk")
    if (( size < NEED_SIZE )); then say bad "too small: $(hsize "$size") < $(hsize "$NEED_SIZE")"; fails=$((fails + 1))
    else say ok "big enough: $(hsize "$size") ≥ $(hsize "$NEED_SIZE")"; fi
    local parts sigs
    parts=$(lsblk -lnpo NAME,TYPE "$disk" | awk '$2 == "part"' | wc -l)
    sigs=$(wipefs -n "$disk" 2>/dev/null | awk 'NR > 1' | wc -l)
    if (( parts > 0 || sigs > 0 )); then
        [[ "$mode" == quiet ]] && fails=$((fails + 1))
        say note "has $parts partition(s) / $sigs signature(s) — will be wiped"
    else
        say ok "blank"
    fi
    return "$fails"
}

if [[ -n "$NEW" ]]; then
    NEW_DISK=$(readlink -f "$NEW")
    [[ -b "$NEW_DISK" ]] || die "  $NEW isn't a block device."
    echo "  Given: $NEW → $NEW_DISK"
else
    cands=()
    while read -r d tran; do
        [[ "$tran" == usb ]] && continue
        check_new "$d" quiet && cands+=("$d")
    done < <(lsblk -dnpo NAME,TRAN,TYPE | awk '$NF == "disk" {print $1, ($3 ? $2 : "")}')
    if [[ ${#cands[@]} -eq 0 ]]; then
        echo "  No blank, unused disk of at least $(hsize "$NEED_SIZE") found. Disks seen:"
        lsblk -dno NAME,SIZE,MODEL,SERIAL | sed 's/^/      /'
        die "  Insert the new disk (or name a used one explicitly with -n) and run again."
    fi
    if [[ ${#cands[@]} -gt 1 ]]; then
        echo "  More than one blank disk fits — pick one with -n:"
        for d in "${cands[@]}"; do echo "      -n $(byid "$d")   ($(lsblk -dno SIZE,MODEL,SERIAL "$d" | xargs))"; done
        exit 2
    fi
    NEW_DISK=${cands[0]}
    echo "  Found exactly one blank disk that fits: $NEW_DISK"
fi
NEW_ID=$(byid "$NEW_DISK"); NEW_ID=${NEW_ID:-$NEW_DISK}
echo "  $NEW_ID ($(lsblk -dno SIZE,MODEL,SERIAL "$NEW_DISK" | xargs))"
[[ "$NEW_ID" == /dev/disk/by-id/* ]] || note "No /dev/disk/by-id name for this disk — using $NEW_DISK, which can change between boots"
check_new "$NEW_DISK" verbose
NEW_FAILS=$?

# =============================================================================
# STEP 4 – THE PLAN
# =============================================================================
STEP_DESC=(); STEP_CMD=()
step() { STEP_DESC+=("$1"); STEP_CMD+=("$2"); }
q() { printf '%q' "$1"; }

step "Wipe old partition tables and signatures from the new disk" "sgdisk --zap-all $(q "$NEW_ID")"
if [[ "$MODE" == partitioned ]]; then
    NEW_Z=$(part_path "$NEW_ID" "$ZPART")
    step "Copy the partition layout from the healthy disk"  "sgdisk $(q "$TEMPLATE_ID") -R $(q "$NEW_ID")"
    step "Give the copied partitions new unique GUIDs"      "sgdisk -G $(q "$NEW_ID")"
    step "Wait for the new partitions to show up"           "udevadm settle; wait_for $(q "$NEW_Z")"
    step "Replace the failed device; the resilver starts"   "zpool replace -f $(q "$POOL") $(q "$OLD") $(q "$NEW_Z")"
else
    NEW_Z=$NEW_ID
    step "Replace the failed device; the resilver starts"   "zpool replace -f $(q "$POOL") $(q "$OLD") $(q "$NEW_ID")"
fi
case "$BOOT" in
    pbt-uefi|pbt-grub)
        NEW_ESP=$(part_path "$NEW_ID" "$ESP_PART")
        # --force: the partition may hold a filesystem from the disk's past
        # life; the checks above already established nothing uses it.
        step "Format the new disk's ESP"                     "proxmox-boot-tool format $(q "$NEW_ESP") --force"
        step "Install the bootloader on it and register it"  "proxmox-boot-tool init $(q "$NEW_ESP")$([[ $BOOT == pbt-grub ]] && echo ' grub')"
        step "Drop the dead disk's ESP from the boot list"   "proxmox-boot-tool clean"
        ;;
    grub-install)
        step "Install GRUB on the new disk"                  "grub-install $(q "$NEW_ID")"
        ;;
esac

echo ""
hr; echo -e "${BOLD}║  4. PLAN${NC}"; hr
for i in "${!STEP_CMD[@]}"; do
    printf "  %d. %s\n       %s\n" $((i + 1)) "${STEP_DESC[i]}" "${STEP_CMD[i]}"
done
echo ""
echo "  Afterwards the resilver runs in the background: watch -n 10 zpool status $POOL"

if (( NEW_FAILS > 0 )); then
    echo ""
    die "  The new disk failed $NEW_FAILS safety check(s) above — not going any further."
fi

if ! $APPLY; then
    echo ""
    echo -e "  ${BOLD}Nothing was changed.${NC} To run this plan: $0 -p $POOL -o $OLD -n $NEW_ID --apply"
    exit 0
fi

# =============================================================================
# STEP 5 – APPLY
# =============================================================================
echo ""
echo -e "  ${RED}${BOLD}This will ERASE $NEW_DISK ($(lsblk -dno SIZE,MODEL,SERIAL "$NEW_DISK" | xargs)).${NC}"
read -r -p "  Type the new disk's name ($(basename "$NEW_DISK")) to go ahead: " answer < /dev/tty
[[ "$answer" == "$(basename "$NEW_DISK")" ]] || die "  Not confirmed — nothing was changed." 2

echo ""
for i in "${!STEP_CMD[@]}"; do
    echo -e "  ${BOLD}$((i + 1)). ${STEP_DESC[i]}${NC}"
    echo "     \$ ${STEP_CMD[i]}"
    out=$(eval "${STEP_CMD[i]}" 2>&1); rc=$?
    [[ -n "$out" ]] && sed 's/^/       /' <<< "$out"
    if (( rc != 0 )); then
        echo ""
        echo -e "  ${RED}Step $((i + 1)) failed (exit $rc). Stopped here.${NC} Once the cause is fixed, the remaining steps are:"
        for ((j = i; j < ${#STEP_CMD[@]}; j++)); do echo "      ${STEP_CMD[j]}"; done
        exit 2
    fi
done

echo ""
ok "All steps done. Resilver status:"
zpool status "$POOL" | sed -n '/^ *scan:/,/^ *config:/p' | sed '$d; s/^/      /'
echo ""
echo "  Follow it with: watch -n 10 zpool status $POOL"
echo "  When it's finished: zpool status -x should say all pools are healthy."
exit 0
