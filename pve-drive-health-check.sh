#!/bin/bash
# =============================================================================
# Proxmox VE Drive Health Checker
# =============================================================================
# Read-only diagnostic. Does not modify RAID config, VM config, or drives.
#
# Checks, in order:
#   1. RAID controller health (VD state, BBU/CacheVault, per-drive PD stats)
#      — via storcli/perccli/MegaCli, if one is found on the box.
#   2. ZFS pool health (state, READ/WRITE/CKSUM errors, scrub/resilver
#      status, capacity/fragmentation) — if any pools are imported.
#   3. Direct SMART health for any block device not fully hidden behind a
#      RAID controller (NVMe, SATA passthrough/JBOD, etc).
#   4. Live IO utilization (3x `iostat -x`, 2s apart) per device.
#   5. Proxmox VM disk config audit (cache mode vs storage backend,
#      discard/iothread pairing) — only runs if /etc/pve/qemu-server exists.
#
# Requirements:
#   - root (needed for smartctl/storcli raw device access)
#   - zfsutils-linux (zpool/zfs) for section 2 — skipped entirely if no
#     `zpool` binary or no imported pools are found
#   - smartmontools (smartctl) for section 3
#   - sysstat (iostat) for section 4 — script warns and skips if missing
#   - storcli64/storcli/perccli64/perccli/MegaCli64 for section 1 — script
#     skips RAID checks entirely if none is found (e.g. plain JBOD/NVMe box)
#
# Exit codes (see bottom of script):
#   0 = clean run, no issues
#   1 = warnings only
#   2 = at least one CRITICAL finding
#
# =============================================================================

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; NC='\033[0m'; BOLD='\033[1m'

# RESULTS holds one row per checked component for the final summary table
# (component name -> status string). ISSUES is a flat list of everything
# that wasn't clean, used for the "Issues requiring attention" block and
# for the exit code at the end. Both are populated via the ok/warn/fail
# helpers below so every section reports through the same mechanism.
declare -A RESULTS
ISSUES=()

# ── helpers ──────────────────────────────────────────────────────────────────
hr()  { echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"; }
hr2() { echo "  ──────────────────────────────────────────────────"; }
ok()  { echo -e "  ${GREEN}[OK]${NC}  $*"; }
# warn()/fail() print AND record — anything that goes through these two
# ends up in the final "Issues requiring attention" list and affects the
# exit code. Plain echo/printf calls elsewhere are just for display and
# deliberately don't count as findings.
warn(){ echo -e "  ${YELLOW}[WARN]${NC} $*"; ISSUES+=("$*"); }
fail(){ echo -e "  ${RED}[FAIL]${NC} $*"; ISSUES+=("CRITICAL: $*"); }

# ── root check ───────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && { echo "Run as root."; exit 1; }

# ── detect storcli/perccli ───────────────────────────────────────────────────
STORCLI=""
for bin in storcli64 storcli perccli64 perccli MegaCli64 MegaCli; do
    path=$(which "$bin" 2>/dev/null) && { STORCLI="$path"; break; }
done
# also check common manual install paths
if [[ -z "$STORCLI" ]]; then
    for path in /usr/local/sbin/storcli /opt/MegaRAID/storcli/storcli64 /root/storcli64; do
        [[ -x "$path" ]] && { STORCLI="$path"; break; }
    done
fi

HAS_RAID=false
RAID_CONTROLLERS=0
if [[ -n "$STORCLI" ]]; then
    # "show ctrlcount" is the documented, version-stable way to get the
    # controller count (returns a single "Controller Count = N" line).
    # Fall back to counting "Controller = N" lines from a plain listing
    # for older storcli/perccli builds that don't support it — but note
    # that fallback can overcount if "Controller = N" happens to repeat
    # in sub-sections of the output on some firmware/tool versions, so
    # prefer the ctrlcount path whenever it's available.
    cc_out=$($STORCLI show ctrlcount 2>/dev/null)
    RAID_CONTROLLERS=$(echo "$cc_out" | grep -oP 'Controller Count\s*=\s*\K[0-9]+')
    if ! [[ "$RAID_CONTROLLERS" =~ ^[0-9]+$ ]]; then
        RAID_CONTROLLERS=$($STORCLI /call show 2>/dev/null | grep -c "^Controller = ")
    fi
    [[ "$RAID_CONTROLLERS" =~ ^[0-9]+$ ]] && [[ "$RAID_CONTROLLERS" -gt 0 ]] && HAS_RAID=true
fi

# ── detect ZFS ───────────────────────────────────────────────────────────────
# Same pattern as the storcli detection above: look for the tool, then
# confirm there's actually something to check (a `zpool` binary can be
# installed with no pools imported, e.g. on a box that boots off ext4/XFS
# but has zfsutils-linux pulled in as a dependency of something else).
HAS_ZFS=false
ZFS_POOLS=()
if command -v zpool &>/dev/null; then
    while IFS= read -r p; do
        [[ -n "$p" ]] && ZFS_POOLS+=("$p")
    done < <(zpool list -H -o name 2>/dev/null)
    [[ ${#ZFS_POOLS[@]} -gt 0 ]] && HAS_ZFS=true
fi

# =============================================================================
# SECTION 1 – RAID CONTROLLER CHECK
# =============================================================================
check_raid_controller() {
    hr
    echo -e "${BOLD}║  RAID CONTROLLER HEALTH${NC}"
    hr

    if ! $HAS_RAID; then
        echo -e "  No RAID controller / storcli not found — skipping RAID checks."
        echo -e "  (If you have a controller, install storcli from Dell/Broadcom support site)"
        return
    fi

    echo -e "  Tool    : $STORCLI"
    echo -e "  Controllers found: $RAID_CONTROLLERS"
    echo ""

    # Deliberately "show all" here, not plain "show" — the BBU_Info /
    # Cachevault_Info sections we parse below only appear with "all".
    local ctrl_out
    ctrl_out=$($STORCLI /call show all 2>/dev/null)

    # ---- Virtual Drives ----
    echo "  --- Virtual Drives ---"
    echo "$ctrl_out" | grep -A1 "VD LIST" | grep -v "VD LIST\|^--"
    local vd_lines
    vd_lines=$(echo "$ctrl_out" | grep -E "RAID[0-9]+" | grep -v "^--")
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # A VD row looks like: "0/0   RAID1 Optl  RW  Yes  RWBD  -  ON  1.090 TB"
        # field 1 = DG/VD id, field 2 = RAID level, field 3 = State.
        state=$(echo "$line" | awk '{print $3}')
        vd_id=$(echo "$line"  | awk '{print $1}')
        if [[ "$state" == "Optl" ]]; then
            ok "VD $vd_id → Optimal"
            RESULTS["VD_${vd_id}"]="OPTIMAL"
        elif [[ "$state" == "Dgrd" ]]; then
            fail "VD $vd_id → DEGRADED — array running without redundancy!"
            RESULTS["VD_${vd_id}"]="DEGRADED"
        elif [[ "$state" == "Pdgd" ]]; then
            fail "VD $vd_id → PARTIALLY DEGRADED"
            RESULTS["VD_${vd_id}"]="PARTIALLY DEGRADED"
        else
            warn "VD $vd_id → $state"
            RESULTS["VD_${vd_id}"]="$state"
        fi
    done <<< "$vd_lines"

    # ---- Battery Backup Unit / CacheVault ----
    # Older/lower-end controllers report BBU_Info. Newer MegaRAID
    # generations (94xx/95xx and similar) ship a supercap+flash
    # "CacheVault" instead, reported under Cachevault_Info with different
    # field names — check both rather than assuming BBU.
    echo ""
    echo "  --- Battery Backup / CacheVault ---"
    local bbu cv
    bbu=$(echo "$ctrl_out" | grep -A2 "BBU_Info" | grep -v "BBU_Info\|^--\|^$" | head -2)
    cv=$(echo "$ctrl_out"  | grep -A2 "Cachevault_Info" | grep -v "Cachevault_Info\|^--\|^$" | head -2)
    if [[ -n "$cv" ]]; then
        echo "  $cv"
        cv_state=$(echo "$cv" | awk 'NR==1{print $2}')
        [[ "$cv_state" == "Optimal" ]] && ok "CacheVault Optimal" || warn "CacheVault state: $cv_state"
    elif [[ -n "$bbu" ]]; then
        echo "  $bbu"
        bbu_state=$(echo "$bbu" | awk 'NR==2{print $2}')
        [[ "$bbu_state" == "Optimal" ]] && ok "BBU Optimal" || warn "BBU state: $bbu_state"
    else
        warn "No BBU/CacheVault detected — write cache may be disabled for safety"
    fi

    # ---- Physical drives (detailed, per-drive) ----
    echo ""
    echo "  --- Physical Drives (RAID) ---"
    hr2

    local pd_out
    pd_out=$($STORCLI /call/eall/sall show all 2>/dev/null)

    # storcli's PD LIST summary table (EID:Slot -> firmware state, e.g.
    # "252:0   0  Onln  ...") appears once at the top of this output,
    # separate from the detailed per-drive blocks ("Drive /c0/e252/s0 :")
    # further down. The detailed blocks don't repeat the state in a form
    # we can pull out with the same regex, so we index the summary table
    # here and look each drive up by EID:Slot when we hit its block below.
    #
    # CAVEAT: keyed only by "eid:slot" — this assumes enclosure/slot
    # numbers don't collide across controllers. True on most setups (each
    # controller owns its own enclosures) but not guaranteed on every
    # multi-controller box; verify against your own `storcli show` output
    # if you run more than one controller per host.
    local -A PD_STATE
    while IFS= read -r line; do
        if [[ "$line" =~ ^([0-9]+):([0-9]+)[[:space:]]+[0-9]+[[:space:]]+(Onln|Offln|JBOD|Rbld|UGood|UBad) ]]; then
            PD_STATE["${BASH_REMATCH[1]}:${BASH_REMATCH[2]}"]="${BASH_REMATCH[3]}"
        fi
    done <<< "$pd_out"

    local current_drive="" current_id="" eid="" slot=""
    local media_err other_err shield temp model sn state

    while IFS= read -r line; do
        if [[ "$line" =~ ^Drive\ /c([0-9]+)/e([0-9]+)/s([0-9]+) ]]; then
            this_id="${BASH_REMATCH[1]}:${BASH_REMATCH[2]}:${BASH_REMATCH[3]}"
            # storcli's per-drive "show all" output repeats a
            # "Drive /cX/eY/sZ <sub-section> :" header once per sub-section
            # (Device attributes, State, Device Speed, Policies/Settings,
            # ...) for the SAME physical drive. Only treat this as a new
            # drive when the c/e/s identifier actually changes — otherwise
            # every sub-section header would flush a partial record and
            # you'd get several fragmented entries per physical drive
            # instead of one merged one.
            if [[ "$this_id" != "$current_id" ]]; then
                if [[ -n "$current_drive" ]]; then
                    _print_raid_drive "$current_drive" "$model" "$sn" "$temp" "$media_err" "$other_err" "$shield" "$state"
                fi
                current_id="$this_id"
                current_drive=$(echo "$line" | grep -oP '/c[0-9]+/e[0-9]+/s[0-9]+')
                eid="${BASH_REMATCH[2]}"; slot="${BASH_REMATCH[3]}"
                media_err=""; other_err=""; shield=""; temp="N/A"; model=""; sn=""
                state="${PD_STATE[${eid}:${slot}]:-unknown}"
            fi
        fi
        [[ "$line" =~ "Media Error Count"  ]] && media_err=$(echo "$line"  | awk -F= '{print $2}' | xargs)
        [[ "$line" =~ "Other Error Count"  ]] && other_err=$(echo "$line"  | awk -F= '{print $2}' | xargs)
        [[ "$line" =~ "Shield Counter"     ]] && shield=$(echo "$line"     | awk -F= '{print $2}' | xargs)
        [[ "$line" =~ "Drive Temperature"  ]] && temp=$(echo "$line"       | awk -F= '{print $2}' | xargs)
        [[ "$line" =~ "Model Number"       ]] && model=$(echo "$line"      | awk -F= '{print $2}' | xargs)
        # NOTE: the pattern below is intentionally UNQUOTED. Quoting any
        # part of the RHS of =~ makes bash match it as a literal string
        # instead of a regex — "^SN" quoted would look for a literal
        # caret character and never match, which is exactly what silently
        # broke serial-number capture in the original version of this
        # script (sn was always empty).
        [[ "$line" =~ ^SN ]] && sn=$(echo "$line" | awk -F= '{print $2}' | xargs)
    done <<< "$pd_out"
    # flush the last drive — the loop above only flushes on seeing the
    # *next* drive's header, so the final drive needs an explicit push.
    [[ -n "$current_drive" ]] && _print_raid_drive "$current_drive" "$model" "$sn" "$temp" "$media_err" "$other_err" "$shield" "$state"
}

_print_raid_drive() {
    local drive=$1 model=$2 sn=$3 temp=$4 media=$5 other=$6 shield=$7 state=$8
    echo ""
    echo -e "  ${BOLD}Drive: $drive${NC}  |  $model  |  SN: $sn"
    echo "    Temp          : $temp"
    echo "    State         : ${state:-unknown}"
    echo "    Media Errors  : $media"
    echo "    Other Errors  : $other"
    echo "    Shield Count  : $shield"

    local key
    key="RAID_${drive//\//_}"

    # Order matters here: we want the worst applicable condition to win
    # and set the final status, not just whichever check happens to run
    # last. Media errors > offline > rebuilding > shield events > other
    # errors > clean.
    if [[ -n "$media" && "$media" != "0" ]]; then
        fail "$drive has $media media errors — potential drive failure!"
        RESULTS[$key]="MEDIA ERRORS"
    elif [[ "$state" == "Offln" ]]; then
        fail "$drive is OFFLINE"
        RESULTS[$key]="OFFLINE"
    elif [[ "$state" == "Rbld" ]]; then
        warn "$drive is REBUILDING — do not stress the array"
        RESULTS[$key]="REBUILDING"
    elif [[ -n "$shield" && "$shield" != "0" ]]; then
        # Shield Counter increments when the controller itself has
        # detected and started managing/quarantining potential media
        # errors on this drive — an early-warning signal worth watching
        # even with zero reported media errors so far.
        warn "$drive has shield counter $shield — controller is managing this drive, watch closely"
        RESULTS[$key]="SHIELD EVENTS: $shield"
    elif [[ -n "$other" && "$other" -gt 100 ]]; then
        warn "$drive has $other other errors (possible controller/cable issue)"
        RESULTS[$key]="OTHER ERRORS: $other"
    else
        ok "$drive → OK (media errors: ${media:-0})"
        RESULTS[$key]="OK"
    fi
}

# =============================================================================
# SECTION 2 – ZFS POOL HEALTH
# =============================================================================
check_zfs_pools() {
    hr
    echo -e "${BOLD}║  ZFS POOL HEALTH${NC}"
    hr

    if ! $HAS_ZFS; then
        echo -e "  No ZFS pools found — skipping ZFS checks."
        return
    fi

    echo -e "  Pools found: ${ZFS_POOLS[*]}"
    echo ""

    # `zpool status -x` gives a single-line "all pools are healthy" summary
    # when everything's clean, or names exactly which pool has a problem.
    # Much easier to key a script off than parsing the full `status -v`
    # output, so it's a fast first pass before the per-pool detail below.
    local x_out
    x_out=$(zpool status -x 2>&1)
    if echo "$x_out" | grep -q "all pools are healthy"; then
        ok "zpool status -x → all pools healthy"
    else
        warn "zpool status -x → $x_out"
    fi

    for pool in "${ZFS_POOLS[@]}"; do
        echo ""
        echo -e "  ${BOLD}Pool: $pool${NC}"
        hr2

        local status_out
        status_out=$(zpool status -v "$pool" 2>/dev/null)

        # ---- Pool state ----
        local state
        state=$(echo "$status_out" | awk '/state:/{print $2; exit}')
        echo "    State: ${state:-unknown}"
        case "$state" in
            ONLINE)
                ok "$pool → ONLINE"
                RESULTS["ZFS_${pool}"]="ONLINE"
                ;;
            DEGRADED)
                fail "$pool → DEGRADED — redundancy lost, replace the faulted device"
                RESULTS["ZFS_${pool}"]="DEGRADED"
                ;;
            FAULTED|UNAVAIL)
                fail "$pool → $state — pool is not accessible"
                RESULTS["ZFS_${pool}"]="$state"
                ;;
            SUSPENDED)
                fail "$pool → SUSPENDED — pool I/O is halted, check underlying storage now"
                RESULTS["ZFS_${pool}"]="SUSPENDED"
                ;;
            OFFLINE)
                warn "$pool → OFFLINE"
                RESULTS["ZFS_${pool}"]="OFFLINE"
                ;;
            *)
                warn "$pool → ${state:-unknown}"
                RESULTS["ZFS_${pool}"]="${state:-UNKNOWN}"
                ;;
        esac

        # ---- Per-device READ/WRITE/CKSUM error counts ----
        # Rows in the "config:" block look like:
        #   sdc   FAULTED   3   0   0  too many errors
        # NAME/STATE never contain spaces, so READ/WRITE/CKSUM are always
        # fields 3/4/5 counting from the FRONT. Counting from the back
        # ($(NF-2) etc.) breaks the moment a row has a trailing annotation
        # like "too many errors" appended, which shifts the last field —
        # confirmed by testing against a synthetic FAULTED-device sample.
        #
        # We take the MAX per column across all rows rather than summing,
        # because pool/vdev rows can roll up their children's counts
        # depending on ZFS version — summing risks double-counting the
        # same error at the disk level and the vdev/pool level above it.
        # MAX gives "the worst single reading in this pool" instead, which
        # is what you actually want to know and can't be double-counted.
        local err_totals rmax wmax cmax
        err_totals=$(echo "$status_out" | awk '
            /^config:/ { in_cfg=1; next }
            /^errors:/ { in_cfg=0 }
            in_cfg && NF>=5 {
                r=$3; w=$4; c=$5
                if (r ~ /^[0-9]+$/ && w ~ /^[0-9]+$/ && c ~ /^[0-9]+$/) {
                    if (r+0>rmax) rmax=r+0
                    if (w+0>wmax) wmax=w+0
                    if (c+0>cmax) cmax=c+0
                }
            }
            END { print rmax+0, wmax+0, cmax+0 }
        ')
        set -- $err_totals
        rmax=$1; wmax=$2; cmax=$3

        echo "    Worst READ/WRITE/CKSUM on any device: $rmax / $wmax / $cmax"
        if [[ "$cmax" -gt 0 ]]; then
            fail "$pool has checksum errors (worst device: $cmax) — data corruption was detected, and repaired if redundancy allowed"
            RESULTS["ZFS_${pool}_ERRORS"]="CKSUM: $cmax"
        elif [[ "$rmax" -gt 0 || "$wmax" -gt 0 ]]; then
            warn "$pool has read/write errors (worst device: read=$rmax write=$wmax) — check cabling/controller"
            RESULTS["ZFS_${pool}_ERRORS"]="READ/WRITE ERRORS: $rmax/$wmax"
        fi

        # ---- Scrub / resilver status ----
        local scan_line
        scan_line=$(echo "$status_out" | grep "scan:")
        echo "    Scan  : ${scan_line#*scan: }"
        if echo "$scan_line" | grep -qi "resilver in progress"; then
            warn "$pool is resilvering — avoid heavy load until it completes"
        elif echo "$scan_line" | grep -qi "scrub in progress"; then
            echo "      (scrub in progress — informational, not a fault)"
        elif echo "$scan_line" | grep -qiE "repaired [1-9]|with [1-9][0-9]* errors"; then
            warn "$pool's last scrub reported repairs or errors — review: ${scan_line#*scan: }"
        fi

        # ---- Capacity / fragmentation ----
        local list_line cap frag
        list_line=$(zpool list -H -o name,cap,frag "$pool" 2>/dev/null)
        cap=$(echo "$list_line" | awk '{print $2}' | tr -d '%')
        frag=$(echo "$list_line" | awk '{print $3}' | tr -d '%')
        echo "    Capacity: ${cap:-?}%  |  Fragmentation: ${frag:-?}%"
        if [[ "$cap" =~ ^[0-9]+$ ]] && [[ "$cap" -gt 80 ]]; then
            # High fill slows ZFS's copy-on-write allocator (it has to work
            # harder to find free space) and increases fragmentation over
            # time; a pool that fills completely can be painful to recover
            # from. This is a space/allocation issue, NOT an ARC (RAM read
            # cache) issue — ARC sizing depends on system memory pressure,
            # not on how full the pool's disks are.
            warn "$pool is ${cap}% full — CoW allocation slows down near full; plan expansion/cleanup"
            RESULTS["ZFS_${pool}_CAP"]="${cap}%"
        fi
        if [[ "$frag" =~ ^[0-9]+$ ]] && [[ "$frag" -gt 70 ]]; then
            warn "$pool fragmentation at ${frag}% — may affect write performance"
        fi
    done
}

# =============================================================================
# SECTION 3 – DIRECT SMART CHECK (JBOD / non-RAID drives)
# =============================================================================
check_direct_drives() {
    hr
    echo -e "${BOLD}║  DIRECT DRIVE HEALTH (SMART)${NC}"
    hr

    # Enumerate top-level block devices only (no partitions), skipping
    # loop devices, ZFS zvols (zd*), device-mapper (dm*, e.g. LUKS/LVM)
    # and software RAID (md*) — none of those are physical media that
    # smartctl can query directly.
    local drives=()
    while IFS= read -r dev; do
        [[ "$dev" =~ ^loop|^zd|^dm|^md ]] && continue
        drives+=("/dev/$dev")
    done < <(lsblk -dn -o NAME 2>/dev/null)

    if [[ ${#drives[@]} -eq 0 ]]; then
        echo "  No block devices found."
        return
    fi

    for drive in "${drives[@]}"; do
        echo ""
        echo -e "  ${BOLD}$drive${NC}"
        hr2

        if [[ ! -b "$drive" ]]; then
            warn "$drive not a valid block device"
            continue
        fi

        local info
        info=$(smartctl -i "$drive" 2>&1)

        # Check if SMART is available
        if ! echo "$info" | grep -q "SMART support is: Enabled"; then
            # A drive fully behind a RAID controller often reports SMART
            # as unavailable at the OS level even though it's healthy —
            # expected, since we already checked it via storcli above.
            if $HAS_RAID && echo "$info" | grep -qi "unable\|failed\|doesn't\|not available"; then
                echo "    Likely behind RAID controller — checked above via storcli."
                RESULTS["SMART_${drive}"]="VIA RAID CONTROLLER"
            else
                warn "$drive: SMART not enabled or not supported"
                RESULTS["SMART_${drive}"]="SMART UNAVAILABLE"
            fi
            continue
        fi

        local model serial nvme=false
        model=$(echo  "$info" | grep "Device Model\|Model Number" | head -1 | awk -F: '{print $2}' | xargs)
        serial=$(echo "$info" | grep "Serial Number"              | head -1 | awk -F: '{print $2}' | xargs)
        echo "    Model : $model"
        echo "    Serial: $serial"
        [[ "$drive" == *nvme* ]] && nvme=true

        # Health
        local health
        health=$(smartctl -H "$drive" 2>/dev/null | grep "SMART overall-health\|SMART Health Status")
        echo "    Health: $health"

        if echo "$health" | grep -qiE "PASSED|OK"; then
            ok "$drive → PASSED"
            RESULTS["SMART_${drive}"]="PASSED"
        else
            fail "$drive → HEALTH CHECK FAILED"
            RESULTS["SMART_${drive}"]="FAILED"
        fi

        # Key attributes
        local attrs
        attrs=$(smartctl -A "$drive" 2>/dev/null)
        echo ""
        echo "    Key Attributes:"

        if $nvme; then
            echo "$attrs" | grep -E "Temperature:|Available Spare|Media and Data|Percentage Used|Power On Hours" \
                | sed 's/^/      /'
            spare=$(echo "$attrs" | grep "Available Spare:" | grep -oP '[0-9]+' | head -1)
            if [[ -n "$spare" && "$spare" -lt 10 ]]; then
                fail "$drive NVMe spare capacity critically low: ${spare}%"
                # This overrides the PASSED/FAILED status set above so the
                # summary table shows the worst finding for this drive —
                # low spare capacity is a real fail condition even when
                # the overall-health bit still says PASSED.
                RESULTS["SMART_${drive}"]="LOW SPARE: ${spare}%"
            fi
        else
            echo "$attrs" | grep -E "Reallocated_Sector|Current_Pending|Offline_Uncorrectable|Power_On_Hours|Temperature|Wear|Media_Wearout|Host_Writes|Program_Fail|Erase_Fail" \
                | sed 's/^/      /'

            # Check critical raw values
            realloc=$(echo "$attrs" | grep "Reallocated_Sector_Ct" | awk '{print $NF}')
            pending=$(echo "$attrs" | grep "Current_Pending_Sector" | awk '{print $NF}')
            poh=$(echo "$attrs" | grep "Power_On_Hours" | awk '{print $NF}')

            # As with the NVMe spare check above: these override RESULTS
            # so the summary reflects them, not just the pass/fail bit.
            # pending is checked after realloc so it wins if both fire —
            # pending sectors are the more urgent of the two.
            if [[ -n "$realloc" && "$realloc" -gt 0 ]]; then
                warn "$drive has $realloc reallocated sectors"
                RESULTS["SMART_${drive}"]="REALLOCATED: $realloc"
            fi
            if [[ -n "$pending" && "$pending" -gt 0 ]]; then
                fail "$drive has $pending pending sectors — imminent data loss risk!"
                RESULTS["SMART_${drive}"]="PENDING SECTORS: $pending"
            fi

            if [[ "$poh" =~ ^[0-9]+$ ]]; then
                poh_years=$(echo "scale=1; $poh / 8760" | bc 2>/dev/null)
                echo "      → Power-on: ${poh}h (${poh_years:-unknown} years)"
                # 52560h ≈ 6 years (8760h/year). Not a fail condition on
                # its own — just a nudge to plan replacement ahead of time.
                [[ "$poh" -gt 52560 ]] && warn "$drive has been running 6+ years (${poh_years:-unknown}y) — plan replacement"
            elif [[ -n "$poh" ]]; then
                echo "      → Power-on: $poh (unparsed)"
            fi
        fi

        # Error log
        local errlog
        errlog=$(smartctl -l error "$drive" 2>/dev/null | grep -v "^$" | tail -5)
        echo ""
        echo "    Error Log (tail):"
        if echo "$errlog" | grep -q "No Errors"; then
            ok "No errors logged"
        else
            echo "$errlog" | grep -E "error|ATA Error|at LBA" | head -5 | sed 's/^/      /' \
                || echo "      (empty or unavailable)"
        fi
    done
}

# =============================================================================
# SECTION 4 – LIVE IO STATS
# =============================================================================
check_io() {
    hr
    echo -e "${BOLD}║  LIVE IO STATISTICS (3 samples × 2s)${NC}"
    hr
    echo ""

    if ! command -v iostat &>/dev/null; then
        warn "iostat not found — install sysstat: apt install sysstat"
        return
    fi

    local io_out
    io_out=$(iostat -x 2 3 2>/dev/null)

    # We take 3 samples 2s apart because the first `iostat -x` sample after
    # boot reports since-boot averages rather than instantaneous rates —
    # we only want the values from the LAST sample.
    #
    # The awk block below re-reads the column headers off every "Device"
    # line instead of hardcoding field positions (the original version
    # used fixed $7/$11/$19), because sysstat has renamed/split these
    # columns across versions — a single "await" column became
    # "r_await"/"w_await", and "avgqu-sz" became "aqu-sz" around sysstat
    # 11.7. Run `iostat -V` to check your version if this ever comes up
    # empty on a host. Each device's stored values get overwritten every
    # time that device reappears in a later sample block, and an explicit
    # in_block flag (set on "Device", cleared on "avg-cpu") keeps the
    # unlabeled avg-cpu VALUES line from being misread as a device row —
    # so by the END block only the last sample's numbers remain, in
    # first-seen device order.
    local io_data
    io_data=$(echo "$io_out" | awk '
        /^avg-cpu/ { in_block=0; next }
        /^Device/  { for (i=1;i<=NF;i++) col[$i]=i; in_block=1; next }
        in_block && NF>0 {
            dev=$1
            if (dev ~ /^(loop|zram)/) next
            ui=col["%util"]
            if (!ui) next
            ri=("r_await" in col) ? col["r_await"] : col["await"]
            wi=("w_await" in col) ? col["w_await"] : col["await"]
            qi=("aqu-sz" in col)  ? col["aqu-sz"]  : col["avgqu-sz"]
            u=$ui+0
            ra=(ri ? $ri+0 : 0); wa=(wi ? $wi+0 : 0)
            level="OK"
            if (u>80 || ra>100 || wa>100) level="HIGH"
            else if (u>50) level="BUSY"
            util[dev]=$ui; r_await[dev]=(ri?$ri:"0"); w_await[dev]=(wi?$wi:"0"); aqu[dev]=(qi?$qi:"0"); lvl[dev]=level
            if (!(dev in seen)) { order[++n]=dev; seen[dev]=1 }
        }
        END { for (i=1;i<=n;i++) { d=order[i]; print d"|"util[d]"|"r_await[d]"|"w_await[d]"|"aqu[d]"|"lvl[d] } }
    ')

    if [[ -z "$io_data" ]]; then
        warn "Could not parse iostat output — check sysstat version / iostat -x column names"
    else
        while IFS='|' read -r dev util r_await w_await aqu level; do
            [[ -z "$dev" ]] && continue
            case "$level" in
                HIGH)
                    echo -e "  ${RED}[HIGH]${NC}  $(printf '%-10s' "$dev") util=${util}%  r_await=${r_await}ms  w_await=${w_await}ms  queue=$aqu"
                    # Feed into the same warn()/RESULTS tracking as every
                    # other section, so a saturated disk actually shows up
                    # in the final summary — previously this section's
                    # findings never left this block (color only, no
                    # entry in ISSUES or RESULTS).
                    warn "$dev high I/O load — util=${util}% r_await=${r_await}ms w_await=${w_await}ms"
                    RESULTS["IO_${dev}"]="HIGH LOAD"
                    ;;
                BUSY)
                    echo -e "  ${YELLOW}[BUSY]${NC}  $(printf '%-10s' "$dev") util=${util}%  r_await=${r_await}ms  w_await=${w_await}ms  queue=$aqu"
                    RESULTS["IO_${dev}"]="BUSY"
                    ;;
                *)
                    echo -e "  ${GREEN}[OK]${NC}    $(printf '%-10s' "$dev") util=${util}%  r_await=${r_await}ms  w_await=${w_await}ms  queue=$aqu"
                    RESULTS["IO_${dev}"]="OK"
                    ;;
            esac
        done <<< "$io_data"
    fi

    echo ""
    echo "  Thresholds: >50% util = busy, >80% util or >100ms await = high"
}

# =============================================================================
# SECTION 5 – PVE VM DISK CONFIG AUDIT
# =============================================================================
check_vm_configs() {
    hr
    echo -e "${BOLD}║  PVE VM DISK CONFIG AUDIT${NC}"
    hr
    echo ""

    local conf_dir="/etc/pve/qemu-server"
    [[ ! -d "$conf_dir" ]] && { echo "  No VM configs found at $conf_dir"; return; }

    local found_issues=false

    for conf in "$conf_dir"/*.conf; do
        [[ -f "$conf" ]] || continue
        vmid=$(basename "$conf" .conf)

        # Find disk lines with problematic combinations
        while IFS= read -r line; do
            [[ "$line" =~ ^(scsi|virtio|sata|ide)[0-9]+: ]] || continue

            local problems=()
            local storage
            # A disk line looks like:
            #   scsi0: local-zfs:vm-100-disk-0,cache=writeback,discard=on,...
            # Grab the LAST alnum/dash token immediately followed by ":" —
            # the first such token is just the bus/index ("scsi0"), the
            # storage name is the second one ("local-zfs").
            storage=$(echo "$line" | grep -oP '[a-zA-Z0-9_-]+(?=:)' | tail -1)

            # Detect ZFS-backed storage pools
            local is_zfs=false
            # Anchor with a whitespace boundary after $storage rather than
            # a bare "^${storage}.*zfspool" prefix match — otherwise a
            # storage named "local" false-matches against the "local-zfs"
            # line in `pvesm status` (both start with "local"), wrongly
            # flagging plain "local" disks as ZFS-backed. This is a common
            # setup: default PVE ships "local" + "local-lvm", and many
            # boxes add "local-zfs" on top.
            if pvesm status 2>/dev/null | grep -qE "^${storage}[[:space:]]+zfspool"; then
                is_zfs=true
            fi

            # writeback on ZFS = bad
            if echo "$line" | grep -q "cache=writeback" && $is_zfs; then
                problems+=("cache=writeback on ZFS pool (use cache=none)")
            fi

            # writeback on any storage without knowing type — flag for review
            if echo "$line" | grep -q "cache=writeback" && ! $is_zfs; then
                problems+=("cache=writeback (verify this is intentional for non-ZFS storage)")
            fi

            # discard without iothread can cause latency on busy VMs
            if echo "$line" | grep -q "discard=on" && ! echo "$line" | grep -q "iothread=1"; then
                problems+=("discard=on without iothread=1 (add iothread for better performance)")
            fi

            if [[ ${#problems[@]} -gt 0 ]]; then
                found_issues=true
                echo -e "  ${YELLOW}VM $vmid${NC}: $(basename "$conf")"
                for p in "${problems[@]}"; do
                    warn "    → $p"
                    echo "    Line: $(echo "$line" | cut -c1-120)"
                done
                echo ""
            fi
        done < "$conf"
    done

    $found_issues || ok "No VM disk config issues found"
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
    # Bash associative arrays have no guaranteed iteration order — sort
    # keys so repeated runs produce a stable, diff-friendly summary (handy
    # if you're logging this over time or comparing runs).
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        val="${RESULTS[$key]}"
        if echo "$val" | grep -qiE "FAIL|CRITICAL|OFFLINE|DEGRADED|PENDING|LOW SPARE|FAULTED|UNAVAIL|SUSPENDED|CKSUM"; then
            printf "  %-35s | ${RED}%s${NC}\n" "$key" "$val"
        elif echo "$val" | grep -qiE "WARN|REBUILD|ERROR|BUSY|HIGH|REALLOCATED|SHIELD"; then
            printf "  %-35s | ${YELLOW}%s${NC}\n" "$key" "$val"
        else
            printf "  %-35s | ${GREEN}%s${NC}\n" "$key" "$val"
        fi
    done < <(printf '%s\n' "${!RESULTS[@]}" | sort)

    echo ""
    if [[ ${#ISSUES[@]} -eq 0 ]]; then
        echo -e "  ${GREEN}No issues detected.${NC}"
    else
        echo -e "  ${RED}Issues requiring attention (${#ISSUES[@]}):${NC}"
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
echo -e "${BOLD}PVE Drive Health Checker — $(date)${NC}"
echo -e "Host: $(hostname) | Kernel: $(uname -r)"
echo ""

check_raid_controller
check_zfs_pools
check_direct_drives
check_io
check_vm_configs
print_summary

# ------------------------------------------------------------------------
# Exit code — lets this be wired into cron/monitoring (Zabbix, Nagios, a
# Prometheus node-exporter textfile collector, etc.) without scraping
# colored terminal output.
#   0 = clean run, no issues
#   1 = warnings only (nothing CRITICAL)
#   2 = at least one CRITICAL finding (drive/array failure risk)
# NOTE: this is new behavior — earlier versions of this script always
# exited 0. If something already wraps this and checks $?, confirm this
# is what you want before relying on it.
# ------------------------------------------------------------------------
critical_count=0
for issue in "${ISSUES[@]}"; do
    [[ "$issue" == CRITICAL:* ]] && ((critical_count++))
done
if   [[ $critical_count -gt 0 ]]; then exit 2
elif [[ ${#ISSUES[@]} -gt 0 ]];   then exit 1
else                                    exit 0
fi
