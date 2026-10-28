#!/bin/bash
# =============================================================================
# Proxmox VE Memory Checker
# =============================================================================
# Read-only diagnostic for where a PVE host's RAM and swap are going.
# Does not change ARC limits, swappiness, swap or guest memory.
#
# Checks, in order:
#   1. Host memory — available RAM, KSM savings, guest RAM assigned vs
#      physical RAM.
#   2. ZFS ARC — size and limits, ARC + guests vs RAM, zfs_arc_max set but
#      silently ignored, or set in /etc/modprobe.d but not active.
#   3. Swap — usage, active swapping right now, swap on a ZFS zvol, and
#      swap per VM/CT plus the host processes using the most.
#
# Usage:
#   ./pve-memory-check.sh [-i SECONDS]
#     -i SECONDS   how long to sample swap activity (default 5)
#
# Requirements:
#   - root (reading other processes' memory stats needs it)
#   - cgroup v2 (PVE 7+) for exact per-guest numbers; falls back to
#     per-process VmSwap on older hosts
#
# Exit codes (see bottom of script):
#   0 = clean run, no issues
#   1 = warnings only
#   2 = at least one CRITICAL finding
#   3 = could not run (not root, bad arguments)
#
# =============================================================================

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; NC='\033[0m'; BOLD='\033[1m'

ARCSTATS=/proc/spl/kstat/zfs/arcstats
ZFS_PARAMS=/sys/module/zfs/parameters
CGROUP=/sys/fs/cgroup

# Same reporting model as the other scripts in this repo: RESULTS is one row
# per check for the summary table, ISSUES is everything that wasn't clean,
# and only warn()/fail() add to ISSUES (and so to the exit code). Rows whose
# value starts with INFO are shown uncolored and don't affect the exit code.
declare -A RESULTS
ISSUES=()

# ── helpers ──────────────────────────────────────────────────────────────────
hr()  { echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"; }
ok()  { echo -e "  ${GREEN}[OK]${NC}  $*"; }
warn(){ echo -e "  ${YELLOW}[WARN]${NC} $*"; ISSUES+=("$*"); }
fail(){ echo -e "  ${RED}[FAIL]${NC} $*"; ISSUES+=("CRITICAL: $*"); }
info(){ echo "  [INFO] $*"; }
rd()  { cat "$1" 2>/dev/null; }
# Bytes to a human-readable GiB/MiB string.
hb()  { awk -v b="${1:-0}" 'BEGIN{ if (b >= 2^30) printf "%.1f GiB", b/2^30; else printf "%.0f MiB", b/2^20 }'; }
# Integer percentage a of b.
percent() { awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN{ if (b > 0) printf "%.0f", 100*a/b; else print 0 }'; }

usage() {
    echo "Usage: $0 [-i SECONDS]"
    echo "  -i SECONDS   how long to sample swap activity (default 5)"
}

# ── arguments ────────────────────────────────────────────────────────────────
INTERVAL=5
while getopts ":i:h" opt; do
    case "$opt" in
        i) INTERVAL="$OPTARG" ;;
        h) usage; exit 0 ;;
        *) usage; exit 3 ;;
    esac
done
[[ "$INTERVAL" =~ ^[1-9][0-9]*$ ]] || { echo "-i needs a positive number of seconds"; exit 3; }

[[ $EUID -ne 0 ]] && { echo "Run as root."; exit 3; }

# ── host numbers used by several sections ────────────────────────────────────
# %.0f, not print: awk prints large numbers in exponent form.
meminfo() { awk -v k="$1:" '$1 == k {printf "%.0f\n", $2 * 1024; exit}' /proc/meminfo; }
MEM_TOTAL=$(meminfo MemTotal)
MEM_AVAIL=$(meminfo MemAvailable)
SWAP_TOTAL=$(meminfo SwapTotal)
SWAP_FREE=$(meminfo SwapFree)
SWAP_USED=$(( SWAP_TOTAL - SWAP_FREE ))

ARC_SIZE=0; ARC_MAX=0
if [[ -r "$ARCSTATS" ]]; then
    ARC_SIZE=$(awk '$1 == "size"  {print $3}' "$ARCSTATS")
    ARC_MAX=$(awk  '$1 == "c_max" {print $3}' "$ARCSTATS")
fi

# Running guests: TYPE, NAME and assigned memory (bytes), keyed by VMID.
declare -A GTYPE GNAME GMEM
GUEST_IDS=()
collect_guests() {
    local f id type mem st
    declare -A running
    while read -r id st; do
        [[ "$st" == running ]] && running[$id]=1
    done < <(qm list 2>/dev/null | awk 'NR>1{print $1, $3}'; pct list 2>/dev/null | awk 'NR>1{print $1, $2}')
    for f in /etc/pve/local/qemu-server/*.conf /etc/pve/local/lxc/*.conf; do
        [[ -f "$f" ]] || continue
        id=$(basename "$f" .conf)
        [[ -n "${running[$id]}" ]] || continue
        if [[ "$f" == */lxc/* ]]; then type=CT; else type=VM; fi
        # Main section only; memory defaults to 512 MiB for both.
        mem=$(awk '/^\[/{exit} /^memory: /{print $2; exit}' "$f")
        GTYPE[$id]=$type
        GNAME[$id]=$(awk '/^\[/{exit} /^(name|hostname): /{print $2; exit}' "$f")
        GMEM[$id]=$(( ${mem:-512} * 1048576 ))
        GUEST_IDS+=("$id")
    done
}
collect_guests
GUEST_MEM=0
for id in "${GUEST_IDS[@]}"; do GUEST_MEM=$(( GUEST_MEM + GMEM[$id] )); done

# Guest cgroup directory (cgroup v2), empty if there isn't one.
guest_cg() {
    local d
    if [[ "${GTYPE[$1]}" == VM ]]; then d="$CGROUP/qemu.slice/$1.scope"; else d="$CGROUP/lxc/$1"; fi
    [[ -d "$d" ]] && echo "$d"
}

# =============================================================================
# SECTION 1 – HOST MEMORY
# =============================================================================
check_host() {
    hr
    echo -e "${BOLD}║  HOST MEMORY${NC}"
    hr
    local avail_pct
    avail_pct=$(percent "$MEM_AVAIL" "$MEM_TOTAL")
    echo "  RAM: $(hb "$MEM_TOTAL") total, $(hb "$MEM_AVAIL") available (${avail_pct}%)"
    [[ "$ARC_SIZE" -gt 0 ]] && echo "       of which ZFS ARC: $(hb "$ARC_SIZE") (counted as used, but shrinks when guests need memory)"

    # MemAvailable doesn't count the ARC as reclaimable, so on ZFS hosts
    # add back what the ARC could give up (down to its minimum).
    local reclaim=0 arc_min
    if [[ -r "$ARCSTATS" ]]; then
        arc_min=$(awk '$1 == "c_min" {print $3}' "$ARCSTATS")
        (( ARC_SIZE > arc_min )) && reclaim=$(( ARC_SIZE - arc_min ))
    fi
    local eff_pct
    eff_pct=$(percent $(( MEM_AVAIL + reclaim )) "$MEM_TOTAL")
    if (( eff_pct < 5 )); then
        fail "Only ${eff_pct}% of RAM available (ARC included) — the OOM killer is close"
        RESULTS["MEM_AVAILABLE"]="CRITICAL: ${eff_pct}%"
    elif (( eff_pct < 10 )); then
        warn "Only ${eff_pct}% of RAM available (ARC included)"
        RESULTS["MEM_AVAILABLE"]="LOW: ${eff_pct}%"
    else
        ok "${eff_pct}% of RAM available (ARC included)"
        RESULTS["MEM_AVAILABLE"]="OK (${eff_pct}%)"
    fi

    # ---- KSM ----
    local sharing
    sharing=$(rd /sys/kernel/mm/ksm/pages_sharing)
    if [[ "${sharing:-0}" -gt 0 ]]; then
        echo "  KSM: saving $(hb $(( sharing * $(getconf PAGESIZE) )))"
    fi

    # ---- Guest RAM vs physical ----
    # Assigned (maximum) memory of running guests. Going over 100% can work
    # with ballooning and KSM, but if the guests actually use what they're
    # given, something gets OOM-killed.
    if [[ ${#GUEST_IDS[@]} -gt 0 ]]; then
        local gp
        gp=$(percent "$GUEST_MEM" "$MEM_TOTAL")
        echo "  Running guests: ${#GUEST_IDS[@]}, $(hb "$GUEST_MEM") assigned (${gp}% of RAM)"
        if (( gp > 100 )); then
            warn "Running guests are assigned ${gp}% of physical RAM — overcommitted; fine only while they don't all use it (ballooning/KSM)"
            RESULTS["MEM_OVERCOMMIT"]="OVERCOMMITTED: ${gp}%"
        else
            RESULTS["MEM_OVERCOMMIT"]="OK (${gp}%)"
        fi
    fi
}

# =============================================================================
# SECTION 2 – ZFS ARC
# =============================================================================
check_arc() {
    [[ -r "$ARCSTATS" ]] || return
    hr
    echo -e "${BOLD}║  ZFS ARC${NC}"
    hr

    local c_min target hits misses
    c_min=$(awk  '$1 == "c_min"  {print $3}' "$ARCSTATS")
    target=$(awk '$1 == "c"      {print $3}' "$ARCSTATS")
    hits=$(awk   '$1 == "hits"   {print $3}' "$ARCSTATS")
    misses=$(awk '$1 == "misses" {print $3}' "$ARCSTATS")
    echo "  Size: $(hb "$ARC_SIZE") | target: $(hb "$target") | min: $(hb "$c_min") | max: $(hb "$ARC_MAX") ($(percent "$ARC_MAX" "$MEM_TOTAL")% of RAM)"
    (( hits + misses > 0 )) && echo "  Hit ratio since boot: $(percent "$hits" $(( hits + misses )))%"

    # ---- Is the configured limit actually in effect? ----
    # zfs_arc_max is silently ignored when it's below zfs_arc_min (default
    # 1/32 of RAM), below 64 MiB or above physical RAM. 0 means "default".
    local param conf
    param=$(rd "$ZFS_PARAMS/zfs_arc_max"); param=${param:-0}
    conf=$(grep -hoE '^[[:space:]]*options[[:space:]]+zfs[[:space:]].*zfs_arc_max=[0-9]+' /etc/modprobe.d/*.conf 2>/dev/null |
               grep -oE 'zfs_arc_max=[0-9]+' | tail -1 | cut -d= -f2)
    if (( param > 0 && param != ARC_MAX )); then
        warn "zfs_arc_max is set to $(hb "$param") but the ARC limit is $(hb "$ARC_MAX") — the setting is being ignored (it must be above zfs_arc_min, $(hb "$c_min"))"
        RESULTS["ARC_LIMIT"]="IGNORED"
    elif [[ -n "$conf" && "$conf" != "$param" ]]; then
        warn "zfs_arc_max=$(hb "$conf") in /etc/modprobe.d isn't active (running: $( (( param == 0 )) && echo default || hb "$param")) — with root on ZFS, run update-initramfs -u -k all and reboot"
        RESULTS["ARC_LIMIT"]="NOT ACTIVE"
    elif [[ -z "$conf" && "$param" -gt 0 ]]; then
        info "zfs_arc_max was set at runtime only — it'll reset on reboot unless added to /etc/modprobe.d/zfs.conf"
        RESULTS["ARC_LIMIT"]="INFO: runtime only"
    elif (( param == 0 )); then
        echo "  No zfs_arc_max set — using the OpenZFS default (the max shown above)"
        RESULTS["ARC_LIMIT"]="INFO: default"
    else
        ok "zfs_arc_max $(hb "$param") is set and active"
        RESULTS["ARC_LIMIT"]="OK ($(hb "$param"))"
    fi

    # ---- ARC + guests vs RAM ----
    # The ARC gives memory back under pressure, but not instantly. A guest
    # that suddenly needs its RAM can push the host into swap or the OOM
    # killer first. PVE's guidance: keep ARC max + guest RAM + a couple of
    # GiB for the host within physical RAM.
    if [[ ${#GUEST_IDS[@]} -gt 0 ]]; then
        local need=$(( ARC_MAX + GUEST_MEM + 2 * 2**30 ))
        echo "  ARC max + running guests + 2 GiB for the host: $(hb "$need") of $(hb "$MEM_TOTAL")"
        if (( need > MEM_TOTAL && GUEST_MEM < MEM_TOTAL )); then
            local room=$(( MEM_TOTAL - GUEST_MEM - 2 * 2**30 ))
            warn "ARC max ($(hb "$ARC_MAX")) plus guest RAM doesn't fit in physical RAM — guests can be OOM-killed before the ARC shrinks. Consider zfs_arc_max of at most $(hb $(( room > 0 ? room : 0 )))"
            RESULTS["ARC_VS_GUESTS"]="TOO BIG: $(percent "$need" "$MEM_TOTAL")% of RAM"
        elif (( need > MEM_TOTAL )); then
            # Guests alone are already overcommitted; section 1 said so.
            RESULTS["ARC_VS_GUESTS"]="INFO: guests alone overcommit RAM"
        else
            ok "ARC max and guest RAM fit in physical RAM"
            RESULTS["ARC_VS_GUESTS"]="OK"
        fi
    fi
}

# =============================================================================
# SECTION 3 – SWAP
# =============================================================================
check_swap() {
    hr
    echo -e "${BOLD}║  SWAP${NC}"
    hr

    if (( SWAP_TOTAL == 0 )); then
        echo "  No swap configured."
        RESULTS["SWAP_USAGE"]="INFO: no swap"
    else
        local used_pct
        used_pct=$(percent "$SWAP_USED" "$SWAP_TOTAL")
        echo "  Swap: $(hb "$SWAP_USED") of $(hb "$SWAP_TOTAL") used (${used_pct}%) | swappiness: $(rd /proc/sys/vm/swappiness)"
        if (( used_pct >= 80 )); then
            warn "Swap ${used_pct}% full — when it runs out, the OOM killer starts"
            RESULTS["SWAP_USAGE"]="FULL: ${used_pct}%"
        else
            RESULTS["SWAP_USAGE"]="OK (${used_pct}%)"
        fi
    fi

    # ---- Swap on a zvol ----
    # Swapping to ZFS needs ZFS to allocate memory exactly when memory is
    # short, and can hang the host. A known OpenZFS problem.
    local zvols
    zvols=$(awk 'NR > 1 && $1 ~ /^\/dev\/zd/ {print $1}' /proc/swaps 2>/dev/null | xargs)
    if [[ -n "$zvols" ]]; then
        warn "Swap on a ZFS zvol ($zvols) — can deadlock the host under memory pressure; use a plain partition, or no swap"
        RESULTS["SWAP_ZVOL"]="SWAP ON ZVOL"
    fi

    # ---- Swapping right now? ----
    # Swap that's merely in use is usually idle pages, which is harmless.
    # Pages being read back in (pswpin) mean something is waiting on disk.
    if (( SWAP_TOTAL > 0 )); then
        local in1 out1 in2 out2 rin rout
        read -r in1 out1 < <(awk '/^pswpin/{i=$2} /^pswpout/{o=$2} END{print i, o}' /proc/vmstat)
        sleep "$INTERVAL"
        read -r in2 out2 < <(awk '/^pswpin/{i=$2} /^pswpout/{o=$2} END{print i, o}' /proc/vmstat)
        rin=$(( (in2 - in1) / INTERVAL )); rout=$(( (out2 - out1) / INTERVAL ))
        echo "  Swap activity over ${INTERVAL}s: ${rin} pages/s in, ${rout} pages/s out"
        if (( rin >= 100 )); then
            warn "Host is actively swapping in (${rin} pages/s) — guests or host processes are waiting on swapped-out memory"
            RESULTS["SWAP_ACTIVITY"]="SWAPPING: ${rin}/s in"
        else
            ok "No heavy swapping right now"
            RESULTS["SWAP_ACTIVITY"]="OK"
        fi
    fi

    (( SWAP_USED > 0 )) || return

    # ---- Per guest ----
    # cgroup v2 keeps an exact swap counter per guest. Without it, add up
    # VmSwap of each process by the cgroup it's in.
    declare -A gswap
    local id cg v pid kb path
    for id in "${GUEST_IDS[@]}"; do
        cg=$(guest_cg "$id")
        [[ -n "$cg" && -r "$cg/memory.swap.current" ]] && gswap[$id]=$(rd "$cg/memory.swap.current")
    done

    # Every process with swap: guest ones fill in what cgroups didn't
    # cover, the rest are host processes.
    local host_procs=""
    while read -r pid kb; do
        path=$(rd "/proc/$pid/cgroup")
        if [[ "$path" =~ qemu\.slice/([0-9]+)\.scope || "$path" =~ /lxc(\.payload)?[/.]([0-9]+) ]]; then
            id=${BASH_REMATCH[1]}; [[ "$id" =~ ^[0-9]+$ ]] || id=${BASH_REMATCH[2]}
            [[ -n "${GTYPE[$id]}" && -z "$(guest_cg "$id")" ]] && gswap[$id]=$(( ${gswap[$id]:-0} + kb * 1024 ))
        else
            host_procs+="$((kb * 1024)) $pid $(rd "/proc/$pid/comm")"$'\n'
        fi
    done < <(grep -sH '^VmSwap:' /proc/[0-9]*/status | awk -F'[/: \t]+' '$(NF-1) > 0 {print $3, $(NF-1)}')

    echo ""
    echo "  --- Swap per guest ---"
    local rows="" total_g=0 used
    for id in "${GUEST_IDS[@]}"; do
        v=${gswap[$id]:-0}
        total_g=$(( total_g + v ))
        cg=$(guest_cg "$id")
        used=$(rd "$cg/memory.current")
        rows+="$v $id ${used:-0}"$'\n'
    done
    if (( total_g == 0 )); then
        echo "  No guest memory is in swap."
    else
        printf "  %-7s %-3s %-22s %10s %10s %10s\n" VMID TYPE NAME ASSIGNED "IN RAM" SWAP
        while read -r v id used; do
            (( v > 0 )) || continue
            printf "  %-7s %-3s %-22.22s %10s %10s %10s\n" "$id" "${GTYPE[$id]}" "${GNAME[$id]:--}" \
                "$(hb "${GMEM[$id]}")" "$( (( used > 0 )) && hb "$used" || echo -)" "$(hb "$v")"
        done < <(sort -rn <<< "$rows" | head -15)
        echo "  Guests total: $(hb "$total_g") of $(hb "$SWAP_USED") swap used"
    fi
    RESULTS["SWAP_GUESTS"]="INFO: $(hb "$total_g")"

    if [[ -n "$host_procs" ]]; then
        echo ""
        echo "  --- Host processes using the most swap ---"
        sort -rn <<< "$host_procs" | head -5 | while read -r v pid name; do
            printf "  %-8s %-20s %10s\n" "$pid" "$name" "$(hb "$v")"
        done
    fi
}

print_summary() {
    hr
    echo -e "${BOLD}║  SUMMARY${NC}"
    hr
    echo ""

    printf "  %-35s | %s\n" "Check" "Status"
    printf "  %-35s | %s\n" "-----------------------------------" "----------------------------"
    local key val
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        val="${RESULTS[$key]}"
        if [[ "$val" == OK* ]]; then
            printf "  %-35s | ${GREEN}%s${NC}\n" "$key" "$val"
        elif [[ "$val" == INFO* ]]; then
            printf "  %-35s | %s\n" "$key" "$val"
        elif [[ "$val" == CRITICAL* ]]; then
            printf "  %-35s | ${RED}%s${NC}\n" "$key" "$val"
        else
            printf "  %-35s | ${YELLOW}%s${NC}\n" "$key" "$val"
        fi
    done < <(printf '%s\n' "${!RESULTS[@]}" | sort)

    echo ""
    if [[ ${#ISSUES[@]} -eq 0 ]]; then
        echo -e "  ${GREEN}No issues detected.${NC}"
    else
        echo -e "  ${RED}Issues requiring attention (${#ISSUES[@]}):${NC}"
        local issue
        for issue in "${ISSUES[@]}"; do
            echo -e "    ${YELLOW}→${NC} $issue"
        done
    fi
    echo ""
}

# =============================================================================
# MAIN
# =============================================================================
echo ""
echo -e "${BOLD}PVE Memory Checker — $(date)${NC}"
echo "Host: $(hostname) | Kernel: $(uname -r)"
echo ""

check_host
check_arc
check_swap
print_summary

# ------------------------------------------------------------------------
# Exit code — same convention as the other scripts in this repo.
#   0 = clean run, no issues
#   1 = warnings only (nothing CRITICAL)
#   2 = at least one CRITICAL finding
#   3 = could not run (handled at the top)
# ------------------------------------------------------------------------
critical_count=0
for issue in "${ISSUES[@]}"; do
    [[ "$issue" == CRITICAL:* ]] && ((critical_count++))
done
if   [[ $critical_count -gt 0 ]]; then exit 2
elif [[ ${#ISSUES[@]} -gt 0 ]];   then exit 1
else                                    exit 0
fi
