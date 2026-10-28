#!/bin/bash
# =============================================================================
# Proxmox VE Hardware Health Checker
# =============================================================================
# Read-only diagnostic. Does not modify hardware, network, VM or BMC config.
# Companion to pve-drive-health-check.sh — that one covers RAID/ZFS/SMART/IO,
# this one covers the rest of the box. Run both after a hardware swap.
#
# Checks, in order:
#   1. ECC memory / machine checks — EDAC counters (per DIMM where the
#      driver exposes it), rasdaemon history, MCE/EDAC lines in the kernel log.
#   2. Temperatures — read straight from hwmon sysfs (no lm-sensors needed),
#      AMD CCD temperature spread, thermal throttling events.
#   3. Kernel log — PCIe AER errors, OOM kills (mapped to VM/CT IDs), block
#      I/O errors, lockups/panics/oopses, number of boots in the window.
#   4. Network — physical NIC link/speed/error counters, bridge uplinks
#      checked against /etc/network/interfaces, bond slave state.
#   5. Proxmox — core services, failed systemd units, cluster quorum,
#      failed tasks, running guests without start-on-boot. Skipped if this
#      isn't a PVE host.
#   6. IPMI / BMC — sensor thresholds and recent System Event Log entries,
#      if ipmitool and a local BMC interface are present.
#
# Usage:
#   ./pve-hardware-health-check.sh [-d DAYS]
#     -d DAYS   how far back to look in the kernel log, task log and SEL
#               (default 7)
#
# Requirements:
#   - root (dmidecode, ipmitool and parts of the journal need it)
#   - bash 4+ (associative arrays) — any PVE release has this
#   - dmidecode, pciutils — on PVE by default
#   - ipmitool for section 6 — skipped if missing
#   - rasdaemon (optional) — adds ECC history that survives reboots
#
# Exit codes (see bottom of script):
#   0 = clean run, no issues
#   1 = warnings only
#   2 = at least one CRITICAL finding
#   3 = could not run (not root, bad arguments)
#
# =============================================================================

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; NC='\033[0m'; BOLD='\033[1m'

# Same reporting model as pve-drive-health-check.sh: RESULTS is one row per
# checked component for the summary table, ISSUES is everything that wasn't
# clean, and only warn()/fail() add to ISSUES (and so to the exit code).
declare -A RESULTS
ISSUES=()

# ── helpers ──────────────────────────────────────────────────────────────────
hr()  { echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"; }
hr2() { echo "  ──────────────────────────────────────────────────"; }
ok()  { echo -e "  ${GREEN}[OK]${NC}  $*"; }
warn(){ echo -e "  ${YELLOW}[WARN]${NC} $*"; ISSUES+=("$*"); }
fail(){ echo -e "  ${RED}[FAIL]${NC} $*"; ISSUES+=("CRITICAL: $*"); }
# Print up to N lines indented, trimmed to terminal-friendly width.
show(){ head -n "${1:-5}" | cut -c1-150 | sed 's/^/      /'; }
# Read a sysfs file, empty string if missing/unreadable.
rd()  { cat "$1" 2>/dev/null; }

usage() {
    echo "Usage: $0 [-d DAYS]"
    echo "  -d DAYS   how far back to look in logs (default 7)"
}

# ── arguments ────────────────────────────────────────────────────────────────
DAYS=7
while getopts ":d:h" opt; do
    case "$opt" in
        d) DAYS="$OPTARG" ;;
        h) usage; exit 0 ;;
        *) usage; exit 3 ;;
    esac
done
[[ "$DAYS" =~ ^[1-9][0-9]*$ ]] || { echo "-d needs a positive number of days"; exit 3; }

# ── root check ───────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && { echo "Run as root."; exit 3; }

SINCE_EPOCH=$(date -d "$DAYS days ago" +%s)

# ── kernel log, read once ────────────────────────────────────────────────────
# Sections 1-3 all grep the same kernel log, so pull it once up front.
#
# Deliberately `_TRANSPORT=kernel` rather than `journalctl -k`: -k implies
# -b (current boot only), which would hide everything from before the last
# reboot — and if the box crashed, that's exactly the part you want.
# Falls back to dmesg (current boot only) if there's no journal.
KLOG=""
KLOG_SRC=""
if command -v journalctl &>/dev/null; then
    KLOG=$(journalctl -q --no-pager -o short-iso _TRANSPORT=kernel --since "$DAYS days ago" 2>/dev/null)
    if [[ -d /var/log/journal ]]; then
        KLOG_SRC="journal, last $DAYS days"
    else
        KLOG_SRC="journal is not persistent — current boot only"
    fi
fi
if [[ -z "$KLOG" ]]; then
    KLOG=$(dmesg -T 2>/dev/null)
    KLOG_SRC="dmesg — current boot only"
fi

# =============================================================================
# SECTION 1 – ECC MEMORY / MACHINE CHECKS
# =============================================================================
check_memory() {
    hr
    echo -e "${BOLD}║  ECC MEMORY / MACHINE CHECKS${NC}"
    hr

    # What the board claims about ECC (SMBIOS type 16 = Physical Memory
    # Array). Context for the EDAC result below: on a non-ECC board the
    # EDAC counters never appear and memory corruption can't be detected.
    local ecc_type=""
    if command -v dmidecode &>/dev/null; then
        ecc_type=$(dmidecode -t 16 2>/dev/null | awk -F': ' '/Error Correction Type/{print $2; exit}')
        echo "  Board ECC type: ${ecc_type:-unknown}"
    fi

    local mcs=(/sys/devices/system/edac/mc/mc[0-9]*)
    if [[ ! -d "${mcs[0]}" ]]; then
        if [[ "$ecc_type" == "None" ]]; then
            echo "  No ECC on this board — memory errors can't be detected."
            RESULTS["MEM_ECC"]="NO ECC"
        elif [[ -n "$VIRT" && "$VIRT" != none ]]; then
            echo "  Virtualized ($VIRT) — memory errors are the hypervisor's to see."
        else
            # ECC board (or unknown) but no EDAC driver bound: errors are
            # being corrected silently and nobody is counting them.
            warn "No EDAC memory controller loaded — ECC errors aren't being counted (check the platform EDAC driver loads, e.g. amd64_edac / skx_edac / i10nm_edac / ie31200_edac)"
            RESULTS["MEM_ECC"]="EDAC NOT LOADED"
        fi
    else
        # EDAC counters are since boot (or since the driver loaded).
        local total_ce=0 total_ue=0 mc ce ue d dce due label
        for mc in "${mcs[@]}"; do
            ce=$(rd "$mc/ce_count"); ue=$(rd "$mc/ue_count")
            [[ "$ce" =~ ^[0-9]+$ ]] || ce=0
            [[ "$ue" =~ ^[0-9]+$ ]] || ue=0
            echo "  $(basename "$mc") ($(rd "$mc/mc_name")): corrected=$ce  uncorrected=$ue"
            total_ce=$((total_ce + ce)); total_ue=$((total_ue + ue))
            # Per-DIMM breakdown, only for DIMMs that actually have errors —
            # this is the line that tells you which slot to pull. Newer
            # kernels use dimmN/, older ones rankN/, same file names inside.
            for d in "$mc"/dimm[0-9]* "$mc"/rank[0-9]*; do
                [[ -d "$d" ]] || continue
                dce=$(rd "$d/dimm_ce_count"); due=$(rd "$d/dimm_ue_count")
                [[ "${dce:-0}" == 0 && "${due:-0}" == 0 ]] && continue
                label=$(rd "$d/dimm_label")
                echo "    $(basename "$d")${label:+ ($label)}: corrected=${dce:-0}  uncorrected=${due:-0}"
            done
        done
        if (( total_ue > 0 )); then
            fail "$total_ue uncorrectable memory error(s) since boot — replace the affected DIMM"
            RESULTS["MEM_ECC"]="UNCORRECTABLE: $total_ue"
        elif (( total_ce > 0 )); then
            # A handful of random CEs can be transient. The same DIMM
            # climbing run after run is a failing module.
            warn "$total_ce corrected memory error(s) since boot — watch whether the count keeps climbing on the same DIMM"
            RESULTS["MEM_ECC"]="CORRECTED: $total_ce"
        else
            ok "No ECC errors since boot"
            RESULTS["MEM_ECC"]="OK"
        fi
    fi

    # rasdaemon keeps its own database, so unlike the EDAC counters above
    # its history survives reboots. Shown for context, not scored — the
    # same events are already counted via EDAC/kernel log.
    if command -v ras-mc-ctl &>/dev/null; then
        echo ""
        echo "  rasdaemon summary:"
        ras-mc-ctl --summary 2>/dev/null | grep -v '^$' | show 10
    fi

    # MCE / EDAC lines in the kernel log. Matching on "[Hardware Error]"
    # rather than a bare "mce:" — plenty of "mce:" lines are harmless boot
    # messages (e.g. "mce: CPU0: Thermal monitoring enabled").
    echo ""
    local mce_lines mce_count
    mce_lines=$(grep -E '\[Hardware Error\]|EDAC MC[0-9]+: [0-9]+ (CE|UE)|Machine check events logged' <<< "$KLOG")
    mce_count=$(grep -c . <<< "$mce_lines")
    if (( mce_count == 0 )); then
        ok "No machine-check / EDAC errors in kernel log ($KLOG_SRC)"
    else
        echo "  Kernel log hardware errors ($mce_count lines, last 5):"
        tail -n 5 <<< "$mce_lines" | show 5
        if grep -qiE ' UE |uncorrect|fatal|context corrupt' <<< "$mce_lines"; then
            fail "Uncorrectable machine check(s) in kernel log — CPU or memory fault"
            RESULTS["MEM_MCE_LOG"]="UNCORRECTABLE"
        else
            warn "$mce_count machine-check / EDAC line(s) in kernel log — same address repeating = failing DIMM"
            RESULTS["MEM_MCE_LOG"]="CORRECTED EVENTS: $mce_count"
        fi
    fi
}

# =============================================================================
# SECTION 2 – TEMPERATURES
# =============================================================================
check_temperatures() {
    hr
    echo -e "${BOLD}║  TEMPERATURES${NC}"
    hr

    local found=false h
    for h in /sys/class/hwmon/hwmon*; do
        [[ -r "$h/name" ]] || continue
        local inputs=("$h"/temp*_input)
        [[ -r "${inputs[0]}" ]] || continue
        found=true

        local chip hwid dev_hint=""
        chip=$(rd "$h/name"); hwid=$(basename "$h")
        [[ -e "$h/device" ]] && dev_hint=" ($(basename "$(readlink -f "$h/device")"))"

        # Fallback thresholds (°C) for chips that don't publish usable
        # limits. The chip's own max/crit win when present — except on AMD,
        # where temp1_max is often a low 70°C that a busy Zen box sits
        # above all day, so there the defaults take precedence over max.
        local dwarn="" dcrit="" prefer_default=false
        case "$chip" in
            k10temp|zenpower) dwarn=84; dcrit=90; prefer_default=true ;;
            coretemp)         dwarn=85; dcrit=100 ;;
            nvme)             dwarn=70; dcrit=80 ;;
            drivetemp)        dwarn=50; dcrit=60 ;;
        esac

        echo ""
        echo -e "  ${BOLD}${chip}${NC}${dev_hint}"

        local worst="OK" hottest=0 ccd_min=999 ccd_max=0 t
        for t in "${inputs[@]}"; do
            local base=${t%_input} raw val label crit max w c state
            raw=$(rd "$t")
            [[ "$raw" =~ ^-?[0-9]+$ ]] || continue
            val=$((raw / 1000))
            # Unconnected sensors commonly read 0, -128 or 127+. Skip them
            # rather than alarming on a sensor that isn't wired to anything.
            (( val <= 0 || val >= 150 )) && continue
            label=$(rd "${base}_label"); label=${label:-$(basename "$base")}

            crit=$(rd "${base}_crit"); max=$(rd "${base}_max")
            [[ "$crit" =~ ^[0-9]+$ ]] && crit=$((crit / 1000)) || crit=""
            [[ "$max"  =~ ^[0-9]+$ ]] && max=$((max / 1000))   || max=""
            # Same bogus-value filter for the limits themselves.
            [[ -n "$crit" ]] && (( crit <= 20 || crit >= 150 )) && crit=""
            [[ -n "$max"  ]] && (( max  <= 20 || max  >= 150 )) && max=""

            c=${crit:-$dcrit}
            if $prefer_default; then w=${dwarn:-$max}; else w=${max:-$dwarn}; fi
            [[ -z "$w" && -n "$c" ]] && w=$((c - 10))
            [[ -n "$w" && -n "$c" ]] && (( w >= c )) && w=$((c - 5))

            state="OK"
            if [[ -n "$c" ]] && (( val >= c )); then state="CRITICAL"
            elif [[ -n "$w" ]] && (( val >= w )); then state="HOT"
            fi
            printf "    %-18s %4s°C   (warn %s / crit %s)  %s\n" "$label" "$val" "${w:--}" "${c:--}" "$state"

            case "$state" in
                CRITICAL) fail "$chip $label at ${val}°C (critical ${c}°C)"; worst="CRITICAL" ;;
                HOT)      warn "$chip $label at ${val}°C (warn ${w}°C)"; [[ "$worst" == OK ]] && worst="HOT" ;;
            esac
            (( val > hottest )) && hottest=$val

            if [[ "$chip" == k10temp && "$label" == Tccd* ]]; then
                (( val < ccd_min )) && ccd_min=$val
                (( val > ccd_max )) && ccd_max=$val
            fi
        done

        # On multi-CCD Ryzen/EPYC, a big gap between CCDs under similar
        # load usually means uneven cooler contact or bad paste.
        if (( ccd_max > 0 && ccd_max - ccd_min > 20 )); then
            warn "$chip CCD temperature spread $((ccd_max - ccd_min))°C (${ccd_min}–${ccd_max}°C) — check cooler mounting / thermal paste"
            [[ "$worst" == OK ]] && worst="CCD SPREAD"
        fi

        if [[ "$worst" == "CCD SPREAD" ]]; then
            RESULTS["TEMP_${chip}_${hwid}"]="CCD SPREAD: $((ccd_max - ccd_min))°C"
        elif [[ "$worst" == OK ]]; then
            RESULTS["TEMP_${chip}_${hwid}"]="OK (max ${hottest}°C)"
        else
            RESULTS["TEMP_${chip}_${hwid}"]="$worst: ${hottest}°C"
        fi
    done

    if ! $found; then
        echo "  No hwmon temperature sensors exposed — normal inside a VM; on bare"
        echo "  metal the sensor driver may not be loaded (apt install lm-sensors && sensors-detect)."
    fi

    echo ""
    local thr thr_count
    thr=$(grep -iE 'temperature above threshold|cpu clock throttled|critical temperature reached' <<< "$KLOG")
    thr_count=$(grep -c . <<< "$thr")
    if (( thr_count > 0 )); then
        echo "  Thermal throttling events ($thr_count, last 3):"
        tail -n 3 <<< "$thr" | show 3
        warn "$thr_count thermal throttling event(s) in kernel log — CPU has been running too hot"
        RESULTS["TEMP_THROTTLING"]="THROTTLED: $thr_count"
    else
        ok "No thermal throttling in kernel log"
    fi
}

# =============================================================================
# SECTION 3 – KERNEL LOG
# =============================================================================
check_kernel_log() {
    hr
    echo -e "${BOLD}║  KERNEL LOG ERRORS${NC}"
    hr
    echo "  Source: $KLOG_SRC"

    # ---- PCIe AER ----
    # Each AER event logs a headline "AER: ... error received ..." line plus
    # several detail lines; count only the headline so one event = one hit.
    # The headline ends with the reporting device's PCI address in both the
    # old ("received: 0000:01:00.0") and new ("received from 0000:01:00.0")
    # kernel wording.
    echo ""
    echo "  --- PCIe AER ---"
    local aer_unc aer_cor
    aer_unc=$(grep -E 'AER: (Multiple )?Uncorrected' <<< "$KLOG")
    aer_cor=$(grep -E 'AER: (Multiple )?Corrected'   <<< "$KLOG")
    local n_unc n_cor
    n_unc=$(grep -c . <<< "$aer_unc"); n_cor=$(grep -c . <<< "$aer_cor")

    _aer_devices() {
        grep -oE '[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f]$' | sort | uniq -c | sort -rn | head -3 |
        while read -r cnt addr; do
            echo "      ${cnt}x $addr  $(lspci -s "$addr" 2>/dev/null | cut -d' ' -f2- | cut -c1-90)"
        done
    }

    if (( n_unc > 0 )); then
        fail "$n_unc uncorrected PCIe error(s) — device or slot fault, can crash the host"
        _aer_devices <<< "$aer_unc"
        RESULTS["KERNEL_PCIE_AER"]="UNCORRECTED: $n_unc"
    elif (( n_cor > 10 )); then
        # A few corrected errors are often harmless link noise (some NICs
        # and risers are chatty). Lots of them on one device = bad seating,
        # riser or card.
        warn "$n_cor corrected PCIe error(s) — reseat/check the device below if it keeps growing"
        _aer_devices <<< "$aer_cor"
        RESULTS["KERNEL_PCIE_AER"]="CORRECTED: $n_cor"
    elif (( n_cor > 0 )); then
        echo "  $n_cor corrected PCIe error(s) — low count, likely link noise"
        _aer_devices <<< "$aer_cor"
        RESULTS["KERNEL_PCIE_AER"]="OK ($n_cor corrected)"
    else
        ok "No PCIe AER errors"
        RESULTS["KERNEL_PCIE_AER"]="OK"
    fi

    # ---- OOM killer ----
    # PVE runs each VM in /qemu.slice/<vmid>.scope and each container under
    # /lxc/<ctid>/, and the kernel's oom-kill line includes task_memcg=...,
    # so we can name the guest instead of just "kvm got killed".
    echo ""
    echo "  --- OOM killer ---"
    local oom_lines oom_count vm_ids ct_ids
    oom_lines=$(grep -E 'Killed process [0-9]+' <<< "$KLOG")
    oom_count=$(grep -c . <<< "$oom_lines")
    vm_ids=$(grep -oE 'task_memcg=/qemu\.slice/[0-9]+\.scope' <<< "$KLOG" | grep -oE '[0-9]+' | sort -un | xargs)
    ct_ids=$(grep -oE 'task_memcg=/lxc/[0-9]+' <<< "$KLOG" | grep -oE '[0-9]+$' | sort -un | xargs)
    if (( oom_count == 0 )); then
        ok "No OOM kills"
        RESULTS["KERNEL_OOM"]="OK"
    else
        echo "  Victims:"
        grep -oE 'Killed process [0-9]+ \([^)]+\)' <<< "$oom_lines" | sed -E 's/.*\((.*)\)/\1/' |
            sort | uniq -c | sort -rn | show 5
        if [[ -n "$vm_ids" ]]; then
            fail "OOM killer killed VM(s): $vm_ids — host ran out of RAM (check overcommit and ZFS ARC size)"
            RESULTS["KERNEL_OOM"]="VM KILLED: $vm_ids"
        elif [[ -n "$ct_ids" ]]; then
            warn "OOM kills inside container(s): $ct_ids — the CT hit its memory limit"
            RESULTS["KERNEL_OOM"]="CT OOM: $ct_ids"
        else
            warn "$oom_count process(es) killed by the OOM killer on the host"
            RESULTS["KERNEL_OOM"]="OOM KILLS: $oom_count"
        fi
    fi

    # ---- Block I/O errors ----
    # Complements the drive checker: SMART can say PASSED while the kernel
    # is already logging failed reads. Optical/floppy/loop are just noise.
    echo ""
    echo "  --- Block I/O errors ---"
    local io_devs
    io_devs=$(grep -oE 'I/O error, dev [a-z0-9]+|Buffer I/O error on dev [a-z0-9]+' <<< "$KLOG" |
              awk '{print $NF}' | grep -vE '^(sr|fd|loop)[0-9]' | sort | uniq -c | sort -rn)
    if [[ -z "$io_devs" ]]; then
        ok "No block I/O errors"
        RESULTS["KERNEL_IO_ERRORS"]="OK"
    else
        show 5 <<< "$io_devs"
        warn "Kernel logged I/O errors on: $(awk '{print $2}' <<< "$io_devs" | xargs) — run pve-drive-health-check.sh"
        RESULTS["KERNEL_IO_ERRORS"]="IO ERRORS: $(awk '{print $2}' <<< "$io_devs" | xargs)"
    fi

    # ---- Lockups / oopses / panics ----
    echo ""
    echo "  --- Lockups, oopses, panics ---"
    local crash crash_count
    crash=$(grep -E 'soft lockup|hard LOCKUP|blocked for more than [0-9]+ seconds|BUG: |kernel BUG at|general protection fault|Kernel panic|WARNING: CPU: [0-9]+ PID' <<< "$KLOG")
    crash_count=$(grep -c . <<< "$crash")
    if (( crash_count == 0 )); then
        ok "No lockups, oopses or panics"
        RESULTS["KERNEL_CRASHES"]="OK"
    else
        echo "  ($crash_count, last 5):"
        tail -n 5 <<< "$crash" | show 5
        if grep -qE 'hard LOCKUP|kernel BUG at|Kernel panic' <<< "$crash"; then
            fail "Kernel panic / hard lockup / BUG in kernel log"
            RESULTS["KERNEL_CRASHES"]="PANIC/LOCKUP"
        else
            # "blocked for more than 120 seconds" during heavy I/O is the
            # common one here — storage too slow for the load.
            warn "$crash_count kernel warning(s)/lockup(s) — see lines above"
            RESULTS["KERNEL_CRASHES"]="WARNINGS: $crash_count"
        fi
    fi

    # ---- Boot count ----
    # The kernel logs "Linux version ..." exactly once per boot, so counting
    # it across the window counts boots. Only meaningful with a persistent
    # journal; with dmesg it's always 1.
    if [[ "$KLOG_SRC" == "journal, last"* ]]; then
        echo ""
        local boots
        boots=$(grep -c 'kernel: Linux version' <<< "$KLOG")
        echo "  Boots in the last $DAYS days: $boots"
        if (( boots >= 3 )); then
            warn "$boots boots in $DAYS days — unplanned reboots? (journalctl --list-boots)"
            RESULTS["KERNEL_BOOTS"]="REBOOTS: $boots"
        fi
    fi
}

# =============================================================================
# SECTION 4 – NETWORK
# =============================================================================
check_network() {
    hr
    echo -e "${BOLD}║  NETWORK${NC}"
    hr

    # Concatenate interfaces + interfaces.d so the bridge/NIC lookups below
    # see the whole config.
    local cfg="" f
    for f in /etc/network/interfaces /etc/network/interfaces.d/*; do
        [[ -f "$f" ]] && cfg+="$(cat "$f")"$'\n'
    done

    # ---- Physical NICs ----
    # Physical = has a backing device in sysfs. Bridges, bonds, VLANs, tap
    # and veth interfaces don't, so this skips all the per-guest clutter.
    echo ""
    echo "  --- Physical NICs ---"
    local n nic any_nic=false
    for n in /sys/class/net/*; do
        [[ -e "$n/device" ]] || continue
        any_nic=true
        nic=$(basename "$n")

        local carrier speed duplex rxe txe rxd crc used=false
        # Reading carrier fails (EINVAL) on an admin-down interface.
        carrier=$(rd "$n/carrier"); carrier=${carrier:-0}
        speed=$(rd "$n/speed"); duplex=$(rd "$n/duplex")
        rxe=$(rd "$n/statistics/rx_errors"); txe=$(rd "$n/statistics/tx_errors")
        rxd=$(rd "$n/statistics/rx_dropped"); crc=$(rd "$n/statistics/rx_crc_errors")
        [[ "$speed" =~ ^[0-9]+$ ]] || speed=""
        # "In use" = mentioned anywhere in the network config (bridge port,
        # bond slave, VLAN parent, own IP). -w treats "." as a boundary, so
        # eno1 also matches when only eno1.100 is configured — intended.
        grep -qwF "$nic" <<< "$cfg" && used=true

        printf "  %-14s %-5s %9s %-5s rx_err=%-6s tx_err=%-6s crc=%-6s drop=%s%s\n" \
            "$nic" "$([[ "$carrier" == 1 ]] && echo up || echo down)" \
            "${speed:+${speed}Mb/s}" "${duplex}" "${rxe:-?}" "${txe:-?}" "${crc:-?}" "${rxd:-?}" \
            "$($used || echo '   (not in config)')"

        $used || continue

        local problems=()
        [[ "$carrier" != 1 ]] && problems+=("link down")
        if [[ "$carrier" == 1 ]]; then
            [[ -n "$speed" ]] && (( speed < 1000 )) && problems+=("negotiated ${speed}Mb/s — bad cable or switch port?")
            [[ "$duplex" == half ]] && problems+=("half duplex")
        fi
        # Counters are since boot. Any real error on modern Ethernet is
        # worth a look; CRC errors in particular point at cabling/optics.
        if [[ "${rxe:-0}" != 0 || "${txe:-0}" != 0 ]]; then
            problems+=("rx_errors=${rxe} tx_errors=${txe}${crc:+ (crc=$crc)} since boot")
        fi

        if [[ ${#problems[@]} -eq 0 ]]; then
            RESULTS["NET_${nic}"]="OK"
        else
            local p
            for p in "${problems[@]}"; do warn "$nic: $p"; done
            if [[ "$carrier" != 1 ]]; then RESULTS["NET_${nic}"]="LINK DOWN"
            else RESULTS["NET_${nic}"]="ERRORS"; fi
        fi
    done
    $any_nic || echo "  No physical NICs found (inside a VM/container?)"

    # ---- Bridges vs config ----
    # The classic post-hardware-swap failure: the new NIC gets a different
    # kernel name, bridge-ports still points at the old one, vmbr0 has no
    # uplink and every VM drops off the network.
    echo ""
    echo "  --- Bridges ---"
    local bridges
    bridges=$(awk '
        $1 == "iface" { cur = $2 }
        ($1 == "bridge-ports" || $1 == "bridge_ports") && cur != "" {
            $1 = ""; sub(/^ +/, ""); print cur "|" $0
        }' <<< "$cfg")
    if [[ -z "$bridges" ]]; then
        echo "  No bridges defined in /etc/network/interfaces"
    fi
    local br ports
    while IFS='|' read -r br ports; do
        [[ -z "$br" ]] && continue
        if [[ ! -d "/sys/class/net/$br" ]]; then
            fail "$br is defined in /etc/network/interfaces but doesn't exist — guests on it have no network (ifreload -a?)"
            RESULTS["NET_BRIDGE_${br}"]="MISSING"
            continue
        fi
        if [[ -z "$ports" || "$ports" == none ]]; then
            echo "  $br: no physical uplink (bridge-ports none) — internal-only by design"
            RESULTS["NET_BRIDGE_${br}"]="OK (internal)"
            continue
        fi

        local p up=() missing=() detached=() down=()
        for p in $ports; do
            if [[ ! -e "/sys/class/net/$p" ]]; then missing+=("$p")
            elif [[ ! -e "/sys/class/net/$br/brif/$p" ]]; then detached+=("$p")
            elif [[ "$(rd "/sys/class/net/$p/carrier")" == 1 ]]; then up+=("$p")
            else down+=("$p")
            fi
        done
        echo "  $br: ports=[$ports]  up=[${up[*]}]${down[*]:+  down=[${down[*]}]}${missing[*]:+  missing=[${missing[*]}]}${detached[*]:+  not-attached=[${detached[*]}]}"

        local m
        for m in "${missing[@]}"; do
            fail "$br uplink '$m' doesn't exist — NIC renamed after a hardware change? Compare with: ip -br link"
        done
        for m in "${detached[@]}"; do
            warn "$br: '$m' exists but isn't attached to the bridge"
        done
        if [[ ${#up[@]} -eq 0 ]]; then
            [[ ${#missing[@]} -eq 0 ]] && fail "$br has no working uplink — guests on it are offline"
            RESULTS["NET_BRIDGE_${br}"]="NO UPLINK"
        elif [[ ${#missing[@]} -gt 0 || ${#detached[@]} -gt 0 ]]; then
            RESULTS["NET_BRIDGE_${br}"]="DEGRADED"
        else
            ok "$br → uplink up (${up[*]})"
            RESULTS["NET_BRIDGE_${br}"]="OK"
        fi
    done <<< "$bridges"

    # ---- Bonds ----
    local b
    for b in /proc/net/bonding/*; do
        [[ -f "$b" ]] || continue
        local bond bstate slaves_down
        bond=$(basename "$b")
        # The first "MII Status" in the file is the bond itself; each one
        # after a "Slave Interface:" line belongs to that slave.
        bstate=$(awk '/^MII Status:/{print $3; exit}' "$b")
        slaves_down=$(awk '/^Slave Interface:/{s=$3} /^MII Status:/ && s!="" {if ($3!="up") print s; s=""}' "$b" | xargs)
        echo ""
        echo "  --- Bond $bond ($(awk -F': ' '/^Bonding Mode/{print $2}' "$b")) ---"
        if [[ "$bstate" != up ]]; then
            fail "$bond is $bstate"
            RESULTS["NET_BOND_${bond}"]="DOWN"
        elif [[ -n "$slaves_down" ]]; then
            warn "$bond lost redundancy — slave(s) down: $slaves_down"
            RESULTS["NET_BOND_${bond}"]="DEGRADED: $slaves_down"
        else
            ok "$bond → all slaves up"
            RESULTS["NET_BOND_${bond}"]="OK"
        fi
    done
}

# =============================================================================
# SECTION 5 – PROXMOX
# =============================================================================
check_pve() {
    hr
    echo -e "${BOLD}║  PROXMOX VE${NC}"
    hr

    if ! command -v pveversion &>/dev/null; then
        echo "  Not a Proxmox VE host — skipping."
        return
    fi
    echo "  $(pveversion 2>/dev/null)"
    echo ""

    # ---- Core services ----
    local svcs=(pve-cluster pvedaemon pveproxy pvestatd) clustered=false s down=()
    if [[ -f /etc/pve/corosync.conf ]]; then
        clustered=true
        svcs+=(corosync pve-ha-lrm pve-ha-crm)
    fi
    for s in "${svcs[@]}"; do
        systemctl is-active --quiet "$s" || down+=("$s")
    done
    if [[ ${#down[@]} -eq 0 ]]; then
        ok "PVE services running (${svcs[*]})"
        RESULTS["PVE_SERVICES"]="OK"
    else
        fail "PVE service(s) not running: ${down[*]}"
        RESULTS["PVE_SERVICES"]="DOWN: ${down[*]}"
    fi

    local failed_units
    failed_units=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | xargs)
    if [[ -n "$failed_units" ]]; then
        warn "Failed systemd unit(s): $failed_units"
        RESULTS["SYSTEMD_FAILED"]="FAILED: $failed_units"
    else
        ok "No failed systemd units"
    fi

    # ---- Quorum ----
    if $clustered; then
        local quorate
        quorate=$(pvecm status 2>/dev/null | awk -F': *' '/^Quorate:/{print $2}')
        if [[ "$quorate" == Yes* ]]; then
            ok "Cluster is quorate"
            RESULTS["PVE_QUORUM"]="OK"
        else
            fail "Cluster is NOT quorate — /etc/pve is read-only, guests can't be started or changed"
            RESULTS["PVE_QUORUM"]="NO QUORUM"
        fi
    fi

    # ---- Failed tasks ----
    # pvesh's JSON is far more stable to parse than its table output; python3
    # ships with every PVE install.
    local node tasks
    node=$(hostname -s)
    tasks=$(pvesh get "/nodes/$node/tasks" --errors 1 --since "$SINCE_EPOCH" --limit 200 \
                --output-format json 2>/dev/null | python3 -c '
import json, sys, time
try:
    t = json.load(sys.stdin)
except Exception:
    sys.exit(1)
print(len(t))
for x in t[:5]:
    print("%s  %-10s %-6s %s" % (time.strftime("%Y-%m-%d %H:%M", time.localtime(x.get("starttime", 0))),
          x.get("type", ""), x.get("id", ""), x.get("status", "")))
' 2>/dev/null)
    if [[ -z "$tasks" ]]; then
        echo "  Couldn't read the task log via pvesh — skipping failed-task check"
    else
        local tcount
        tcount=$(head -1 <<< "$tasks")
        if (( tcount == 0 )); then
            ok "No failed tasks in the last $DAYS days"
            RESULTS["PVE_TASKS"]="OK"
        else
            echo "  Failed tasks (latest 5):"
            tail -n +2 <<< "$tasks" | show 5
            if grep -q ' vzdump ' <<< "$tasks"; then
                warn "$tcount failed task(s) in the last $DAYS days, including backups"
            else
                warn "$tcount failed task(s) in the last $DAYS days"
            fi
            RESULTS["PVE_TASKS"]="FAILED: $tcount"
        fi
    fi

    # ---- Running guests without start-on-boot ----
    # Only look at the [main] section of each config — snapshot sections
    # further down carry their own copy of onboot.
    local no_onboot=() vmid status
    while read -r vmid status; do
        [[ "$status" == running ]] || continue
        awk '/^\[/{exit} /^onboot: *1/{f=1} END{exit !f}' "/etc/pve/local/qemu-server/$vmid.conf" 2>/dev/null \
            || no_onboot+=("VM$vmid")
    done < <(qm list 2>/dev/null | awk 'NR>1{print $1, $3}')
    while read -r vmid status; do
        [[ "$status" == running ]] || continue
        awk '/^\[/{exit} /^onboot: *1/{f=1} END{exit !f}' "/etc/pve/local/lxc/$vmid.conf" 2>/dev/null \
            || no_onboot+=("CT$vmid")
    done < <(pct list 2>/dev/null | awk 'NR>1{print $1, $2}')
    if [[ ${#no_onboot[@]} -gt 0 ]]; then
        warn "Running guest(s) without start-on-boot — won't come back after a host reboot: ${no_onboot[*]}"
        RESULTS["PVE_ONBOOT"]="NO ONBOOT: ${#no_onboot[@]}"
    else
        ok "All running guests start on boot"
    fi
}

# =============================================================================
# SECTION 6 – IPMI / BMC
# =============================================================================
check_ipmi() {
    hr
    echo -e "${BOLD}║  IPMI / BMC${NC}"
    hr

    if ! command -v ipmitool &>/dev/null; then
        echo "  ipmitool not installed — skipping (apt install ipmitool)"
        return
    fi
    if [[ ! -e /dev/ipmi0 && ! -e /dev/ipmi/0 && ! -e /dev/ipmidev/0 ]]; then
        echo "  No local BMC interface (/dev/ipmi0). If the board has a BMC: modprobe ipmi_si ipmi_devintf"
        return
    fi

    # A wedged BMC can make ipmitool hang for minutes — cap every call.
    local ipmi="timeout 60 ipmitool"

    local mc
    mc=$($ipmi mc info 2>/dev/null)
    echo "  BMC: $(awk -F': ' '/Manufacturer Name/{print $2}' <<< "$mc")  firmware $(awk -F': ' '/Firmware Revision/{print $2}' <<< "$mc")"

    # ---- Sensors ----
    # `ipmitool sensor` columns: name | value | unit | status | thresholds...
    # Status for threshold sensors is ok / nc (non-critical) / cr (critical)
    # / nr (non-recoverable); discrete sensors show hex or "na" — ignored.
    echo ""
    echo "  --- Sensors ---"
    local sens total=0 okc=0 bad=0 name val unit st worst="OK"
    sens=$($ipmi sensor 2>/dev/null)
    while IFS='|' read -r name val unit st _; do
        name=$(xargs <<< "$name"); val=$(xargs <<< "$val"); unit=$(xargs <<< "$unit"); st=$(xargs <<< "$st")
        case "$st" in
            ok) ((total++)); ((okc++)) ;;
            nc) ((total++)); ((bad++)); warn "BMC sensor '$name' = $val $unit (non-critical threshold)"
                [[ "$worst" == OK ]] && worst="NON-CRITICAL" ;;
            cr|nr) ((total++)); ((bad++))
                [[ "$st" == cr ]] && st="critical" || st="non-recoverable"
                fail "BMC sensor '$name' = $val $unit ($st threshold)"
                worst="CRITICAL" ;;
        esac
    done <<< "$sens"
    if (( total == 0 )); then
        echo "  No threshold sensors returned"
    else
        (( bad == 0 )) && ok "All $total threshold sensors OK"
        RESULTS["IPMI_SENSORS"]="$worst ($okc/$total ok)"
    fi

    # ---- System Event Log ----
    # The SEL is never cleared automatically, so old events would alarm
    # forever. Only entries inside the -d window are scored; the rest is
    # history. Review, then `ipmitool sel clear` once dealt with.
    echo ""
    echo "  --- System Event Log (last $DAYS days) ---"
    local sel recent=() d tm sensor event dir epoch line sel_worst="OK"
    sel=$($ipmi sel elist 2>/dev/null)
    while IFS='|' read -r _ d tm sensor event dir; do
        epoch=$(date -d "$(xargs <<< "$d") $(xargs <<< "$tm")" +%s 2>/dev/null) || continue
        (( epoch >= SINCE_EPOCH )) || continue
        line="$(xargs <<< "$d") $(xargs <<< "$tm") | $(xargs <<< "$sensor") | $(xargs <<< "$event") | $(xargs <<< "$dir")"
        recent+=("$line")
        # "Non-critical" contains "critical", so match the specific threshold
        # phrases ("Upper Critical", "Lower Critical") instead of a bare word.
        if grep -qiE 'Uncorrectable|Non-recoverable|Failure detected|Predictive Failure|AC lost|Upper Critical|Lower Critical|Drive Fault' <<< "$line"; then
            sel_worst="CRITICAL"
        elif grep -qiE 'Non-critical|Correctable ECC|Redundancy (Lost|Degraded)|Fully Redundant.*Deasserted' <<< "$line"; then
            [[ "$sel_worst" == OK ]] && sel_worst="WARNING"
        fi
    done <<< "$sel"
    echo "  Total entries: $(grep -c . <<< "$sel"), in window: ${#recent[@]}"
    if [[ ${#recent[@]} -gt 0 ]]; then
        printf '%s\n' "${recent[@]}" | tail -n 8 | show 8
    fi
    case "$sel_worst" in
        CRITICAL) fail "Critical hardware event(s) in the BMC event log — see entries above"
                  RESULTS["IPMI_SEL"]="CRITICAL EVENTS" ;;
        WARNING)  warn "Non-critical hardware event(s) in the BMC event log — see entries above"
                  RESULTS["IPMI_SEL"]="WARNING EVENTS" ;;
        *)        ok "No hardware fault events in the BMC event log"
                  RESULTS["IPMI_SEL"]="OK" ;;
    esac
}

# =============================================================================
# SUMMARY
# =============================================================================
print_summary() {
    hr
    echo -e "${BOLD}║  SUMMARY${NC}"
    hr
    echo ""

    printf "  %-35s | %s\n" "Component" "Status"
    printf "  %-35s | %s\n" "-----------------------------------" "----------------------------"
    local key val
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        val="${RESULTS[$key]}"
        if [[ "$val" == OK* || "$val" == "NO ECC" ]]; then
            printf "  %-35s | ${GREEN}%s${NC}\n" "$key" "$val"
        elif echo "$val" | grep -qiE "CRITICAL|UNCORRECT|PANIC|DOWN|MISSING|NO UPLINK|NO QUORUM|VM KILLED"; then
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
echo -e "${BOLD}PVE Hardware Health Checker — $(date)${NC}"
echo -e "Host: $(hostname) | Kernel: $(uname -r) | Log window: $DAYS days"
if command -v dmidecode &>/dev/null; then
    echo "System: $(dmidecode -s system-manufacturer 2>/dev/null) $(dmidecode -s system-product-name 2>/dev/null)" \
         "| S/N: $(dmidecode -s system-serial-number 2>/dev/null)" \
         "| BIOS: $(dmidecode -s bios-version 2>/dev/null) ($(dmidecode -s bios-release-date 2>/dev/null))"
fi
echo "CPU: $(awk -F': ' '/^model name/{print $2; exit}' /proc/cpuinfo) | RAM: $(awk '/^MemTotal/{printf "%.0f GiB", $2/1048576}' /proc/meminfo)"
VIRT=$(systemd-detect-virt 2>/dev/null)
if [[ -n "$VIRT" && "$VIRT" != none ]]; then
    echo -e "${YELLOW}Running inside a VM/container ($VIRT) — most hardware checks won't apply.${NC}"
fi
echo ""

check_memory
check_temperatures
check_kernel_log
check_network
check_pve
check_ipmi
print_summary

# ------------------------------------------------------------------------
# Exit code — same convention as pve-drive-health-check.sh, plus 3 for
# "didn't run" so a wrapper can tell a usage error from a warning.
#   0 = clean run, no issues
#   1 = warnings only (nothing CRITICAL)
#   2 = at least one CRITICAL finding
#   3 = could not run (handled at the top: not root / bad arguments)
# ------------------------------------------------------------------------
critical_count=0
for issue in "${ISSUES[@]}"; do
    [[ "$issue" == CRITICAL:* ]] && ((critical_count++))
done
if   [[ $critical_count -gt 0 ]]; then exit 2
elif [[ ${#ISSUES[@]} -gt 0 ]];   then exit 1
else                                    exit 0
fi
