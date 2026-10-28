#!/bin/bash
# =============================================================================
# Proxmox VE Guest Audit
# =============================================================================
# Read-only audit of the VMs and containers on this node. Does not start,
# stop, unlock, edit or delete anything — it only reads configs and asks PVE
# for status. Every finding comes with the command you'd use to act on it.
#
# Checks, in order:
#   1. Inventory — every local guest with status, snapshot count and lock.
#   2. Snapshots — snapshots older than N days, leftover vzdump snapshots.
#   3. Locks and pending changes — guests stuck locked after a failed task,
#      config changes waiting for a reboot.
#   4. Guest agent — enabled but not answering, and running VMs without it.
#   5. Start on boot — running guests that won't come back after a host
#      reboot. HA-managed guests are skipped, since HA starts those.
#   6. CPU type — VMs with cpu=host in a cluster whose nodes have different
#      CPUs, which breaks live migration between them.
#   7. Containers — privileged containers.
#   8. Disks — detached (unusedN) disks, and volumes on storage that no
#      guest config refers to at all.
#
# Usage:
#   ./pve-guest-audit.sh [-s DAYS]
#     -s DAYS   flag snapshots older than this (default 14)
#
# Requirements:
#   - root, on a Proxmox VE node
#   - python3 (ships with PVE) for parsing pvesh JSON
#
# Exit codes (see bottom of script):
#   0 = clean run, no issues
#   1 = warnings
#   3 = could not run (not root, not PVE, bad arguments)
# Nothing here is CRITICAL, so 2 isn't used: these are housekeeping
# findings, not outages.
#
# =============================================================================

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; NC='\033[0m'; BOLD='\033[1m'

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
info(){ echo "  [INFO] $*"; }

# Value of a key from the main section of a guest config. Everything after
# the first [section] belongs to a snapshot or to pending changes.
cfgval() { awk -v k="$2" '/^\[/{exit} index($0, k": ") == 1 {print substr($0, length(k) + 3); exit}' "$1" 2>/dev/null; }

usage() {
    echo "Usage: $0 [-s DAYS]"
    echo "  -s DAYS   flag snapshots older than this (default 14)"
}

# ── arguments ────────────────────────────────────────────────────────────────
SNAP_DAYS=14
while getopts ":s:h" opt; do
    case "$opt" in
        s) SNAP_DAYS="$OPTARG" ;;
        h) usage; exit 0 ;;
        *) usage; exit 3 ;;
    esac
done
[[ "$SNAP_DAYS" =~ ^[1-9][0-9]*$ ]] || { echo "-s needs a positive number of days"; exit 3; }

[[ $EUID -ne 0 ]] && { echo "Run as root."; exit 3; }
command -v pveversion &>/dev/null || { echo "Not a Proxmox VE host."; exit 3; }

NODE=$(hostname -s)
NOW=$(date +%s)
CLUSTERED=false
[[ -f /etc/pve/corosync.conf ]] && CLUSTERED=true

# ── gather guests ────────────────────────────────────────────────────────────
# Keyed by VMID, which is unique across the whole cluster.
declare -A TYPE CONF STATUS NAME
IDS=()
for f in /etc/pve/local/qemu-server/*.conf /etc/pve/local/lxc/*.conf; do
    [[ -f "$f" ]] || continue
    id=$(basename "$f" .conf)
    IDS+=("$id")
    CONF[$id]="$f"
    if [[ "$f" == */lxc/* ]]; then
        TYPE[$id]=CT; NAME[$id]=$(cfgval "$f" hostname)
    else
        TYPE[$id]=VM; NAME[$id]=$(cfgval "$f" name)
    fi
    [[ "$(cfgval "$f" template)" == 1 ]] && STATUS[$id]=template
done
mapfile -t IDS < <(printf '%s\n' "${IDS[@]}" | sort -n)

while read -r id st; do
    [[ -n "${CONF[$id]}" && -z "${STATUS[$id]}" ]] && STATUS[$id]="$st"
done < <(qm list 2>/dev/null | awk 'NR>1{print $1, $3}'; pct list 2>/dev/null | awk 'NR>1{print $1, $2}')

# VMIDs with a task running right now (backup, migration...). A lock on one
# of these is expected, not stale.
ACTIVE_IDS=" $(pvesh get "/nodes/$NODE/tasks" --source active --output-format json 2>/dev/null | python3 -c '
import json, sys
try:
    print(" ".join(sorted({str(t.get("id", "")) for t in json.load(sys.stdin) if t.get("id")})))
except Exception:
    pass
' 2>/dev/null) "

# Snapshots per guest as "name snaptime" lines. PENDING and special:* are
# sections too, but not snapshots.
snapshots() {
    awk '
        /^\[/ { s = substr($0, 2, length($0) - 2); if (s == "PENDING" || s ~ /^special:/) s = ""; else print s, 0; next }
        s != "" && /^snaptime: / { print s, $2 }' "$1" 2>/dev/null |
        awk '{ t[$1] = ($2 > t[$1] ? $2 : t[$1]) } END { for (s in t) print s, t[s] }'
}

# =============================================================================
# SECTION 1 – INVENTORY
# =============================================================================
check_inventory() {
    hr
    echo -e "${BOLD}║  INVENTORY${NC}"
    hr
    if [[ ${#IDS[@]} -eq 0 ]]; then
        echo "  No guests on this node."
        return
    fi
    printf "  %-7s %-3s %-24s %-9s %-6s %s\n" VMID TYPE NAME STATUS SNAPS LOCK
    local id n_vm=0 n_ct=0 n_run=0
    for id in "${IDS[@]}"; do
        printf "  %-7s %-3s %-24.24s %-9s %-6s %s\n" "$id" "${TYPE[$id]}" "${NAME[$id]:--}" \
            "${STATUS[$id]:-unknown}" "$(snapshots "${CONF[$id]}" | wc -l)" "$(cfgval "${CONF[$id]}" lock)"
        [[ "${TYPE[$id]}" == VM ]] && n_vm=$((n_vm + 1)) || n_ct=$((n_ct + 1))
        [[ "${STATUS[$id]}" == running ]] && n_run=$((n_run + 1))
    done
    echo ""
    echo "  $n_vm VM(s), $n_ct container(s), $n_run running"
}

# =============================================================================
# SECTION 2 – SNAPSHOTS
# =============================================================================
# Snapshots aren't backups, and on ZFS/LVM-thin/Ceph every one of them keeps
# all blocks changed since it was taken. Old ones quietly eat the pool.
check_snapshots() {
    hr
    echo -e "${BOLD}║  SNAPSHOTS${NC}"
    hr
    local id name ts age old_total=0 guests=() leftover=()
    for id in "${IDS[@]}"; do
        local old=()
        while read -r name ts; do
            [[ -z "$name" ]] && continue
            # A CT snapshot named "vzdump" is made by snapshot-mode backups
            # and removed when they finish. One that's still there with no
            # backup running is left over from a backup that died.
            if [[ "${TYPE[$id]}" == CT && "$name" == vzdump && "$ACTIVE_IDS" != *" $id "* ]]; then
                leftover+=("CT$id")
                continue
            fi
            (( ts == 0 )) && continue
            age=$(( (NOW - ts) / 86400 ))
            (( age >= SNAP_DAYS )) && old+=("$name (${age}d)")
        done < <(snapshots "${CONF[$id]}")
        if [[ ${#old[@]} -gt 0 ]]; then
            echo "  ${TYPE[$id]} $id ${NAME[$id]}: ${old[*]}"
            old_total=$((old_total + ${#old[@]}))
            guests+=("${TYPE[$id]}$id")
        fi
    done
    if (( old_total > 0 )); then
        warn "$old_total snapshot(s) older than $SNAP_DAYS days on: ${guests[*]} (remove with: qm delsnapshot / pct delsnapshot <id> <name>)"
        RESULTS["SNAPSHOTS_OLD"]="OLD: $old_total on ${#guests[@]} guest(s)"
    else
        ok "No snapshots older than $SNAP_DAYS days"
        RESULTS["SNAPSHOTS_OLD"]="OK"
    fi
    if [[ ${#leftover[@]} -gt 0 ]]; then
        warn "Leftover 'vzdump' snapshot on: ${leftover[*]} — from a backup that didn't finish (pct delsnapshot <id> vzdump)"
        RESULTS["SNAPSHOTS_VZDUMP"]="LEFTOVER: ${leftover[*]}"
    fi
}

# =============================================================================
# SECTION 3 – LOCKS AND PENDING CHANGES
# =============================================================================
check_locks() {
    hr
    echo -e "${BOLD}║  LOCKS AND PENDING CHANGES${NC}"
    hr
    local id lock stale=() pending=()
    for id in "${IDS[@]}"; do
        lock=$(cfgval "${CONF[$id]}" lock)
        if [[ -n "$lock" ]]; then
            if [[ "$ACTIVE_IDS" == *" $id "* ]]; then
                echo "  ${TYPE[$id]} $id is locked ($lock) by a task that's still running — fine"
            else
                stale+=("${TYPE[$id]}$id($lock)")
            fi
        fi
        # Changes that couldn't be hot-plugged sit in a [PENDING] section
        # until the next full stop/start. Only VMs have this.
        if grep -q '^\[PENDING\]' "${CONF[$id]}" 2>/dev/null; then
            local keys
            keys=$(awk '/^\[PENDING\]/{p=1; next} /^\[/{p=0} p && /: /{sub(/:.*/, ""); printf "%s ", $0}' "${CONF[$id]}")
            pending+=("${TYPE[$id]}$id")
            echo "  ${TYPE[$id]} $id pending: ${keys% }"
        fi
    done
    if [[ ${#stale[@]} -gt 0 ]]; then
        warn "Guest(s) locked with no task running: ${stale[*]} — left over from a failed task? Check the task log, then: qm unlock / pct unlock <id>"
        RESULTS["GUEST_LOCKS"]="STALE: ${#stale[@]}"
    else
        ok "No stale locks"
        RESULTS["GUEST_LOCKS"]="OK"
    fi
    if [[ ${#pending[@]} -gt 0 ]]; then
        warn "Config changes waiting for a reboot on: ${pending[*]} — they take effect after a full shutdown and start (not a reboot from inside the guest)"
        RESULTS["GUEST_PENDING"]="PENDING: ${#pending[@]}"
    else
        ok "No pending config changes"
    fi
}

# =============================================================================
# SECTION 4 – QEMU GUEST AGENT
# =============================================================================
# The agent is what lets PVE freeze filesystems for consistent backups and
# snapshots, shut a VM down cleanly and show its IPs. Enabled-but-dead is
# the bad case: backups then run without a filesystem freeze, silently.
check_agent() {
    hr
    echo -e "${BOLD}║  QEMU GUEST AGENT${NC}"
    hr
    local id agent dead=() none=() good=0
    for id in "${IDS[@]}"; do
        [[ "${TYPE[$id]}" == VM && "${STATUS[$id]}" == running ]] || continue
        agent=$(cfgval "${CONF[$id]}" agent)
        if [[ "$agent" == 1* || "$agent" == *enabled=1* ]]; then
            if timeout 15 qm agent "$id" ping &>/dev/null; then
                good=$((good + 1))
            else
                dead+=("VM$id")
            fi
        else
            none+=("VM$id")
        fi
    done
    (( good > 0 )) && ok "$good VM(s) with a responding guest agent"
    if [[ ${#dead[@]} -gt 0 ]]; then
        warn "Guest agent enabled but not responding: ${dead[*]} — service not installed or not running inside the guest; backups run without a filesystem freeze"
        RESULTS["GUEST_AGENT"]="NOT RESPONDING: ${#dead[@]}"
    elif (( good > 0 )); then
        RESULTS["GUEST_AGENT"]="OK"
    fi
    if [[ ${#none[@]} -gt 0 ]]; then
        info "Running VM(s) without the guest agent enabled: ${none[*]}"
        [[ -z "${RESULTS[GUEST_AGENT]}" ]] && RESULTS["GUEST_AGENT"]="INFO: ${#none[@]} without agent"
    fi
    (( good == 0 && ${#dead[@]} == 0 && ${#none[@]} == 0 )) && echo "  No running VMs."
}

# =============================================================================
# SECTION 5 – START ON BOOT
# =============================================================================
check_onboot() {
    hr
    echo -e "${BOLD}║  START ON BOOT${NC}"
    hr
    # Guests in HA are started by the HA stack and normally have onboot off.
    # "state ignored" takes a resource out of HA's hands, so those still count.
    local ha_ids
    ha_ids=" $(awk '
        /^(vm|ct): *[0-9]+/ { if (id != "" && !ign) print id; id = $2; ign = 0; next }
        /^[ \t]+state[ \t]+ignored/ { ign = 1 }
        END { if (id != "" && !ign) print id }' /etc/pve/ha/resources.cfg 2>/dev/null | xargs) "
    local id missing=() ha=0
    for id in "${IDS[@]}"; do
        [[ "${STATUS[$id]}" == running ]] || continue
        [[ "$ha_ids" == *" $id "* ]] && { ha=$((ha + 1)); continue; }
        [[ "$(cfgval "${CONF[$id]}" onboot)" == 1 ]] || missing+=("${TYPE[$id]}$id")
    done
    (( ha > 0 )) && echo "  $ha running guest(s) are HA-managed — start-on-boot not needed"
    if [[ ${#missing[@]} -gt 0 ]]; then
        warn "Running guest(s) without start-on-boot — won't come back after a host reboot: ${missing[*]} (qm set / pct set <id> --onboot 1)"
        RESULTS["GUEST_ONBOOT"]="NO ONBOOT: ${#missing[@]}"
    else
        ok "All running non-HA guests start on boot"
        RESULTS["GUEST_ONBOOT"]="OK"
    fi
}

# =============================================================================
# SECTION 6 – CPU TYPE
# =============================================================================
# cpu=host passes the physical CPU's exact feature set through. Fast, but a
# VM started on a newer CPU can't live-migrate to an older one. Only matters
# in a cluster, and only if the nodes actually differ.
check_cpu_type() {
    $CLUSTERED || return
    hr
    echo -e "${BOLD}║  CPU TYPE (LIVE MIGRATION)${NC}"
    hr
    local models n_models
    models=$(pvesh get /nodes --output-format json 2>/dev/null | python3 -c '
import json, subprocess, sys
try:
    nodes = [n["node"] for n in json.load(sys.stdin) if n.get("status") == "online"]
except Exception:
    sys.exit()
for n in nodes:
    try:
        out = subprocess.run(["pvesh", "get", "/nodes/%s/status" % n, "--output-format", "json"],
                             capture_output=True, text=True, timeout=20).stdout
        print("%s\t%s" % (n, json.loads(out)["cpuinfo"]["model"]))
    except Exception:
        pass
' 2>/dev/null)
    n_models=$(cut -f2 <<< "$models" | sed '/^$/d' | sort -u | wc -l)

    local id cpu host_vms=()
    for id in "${IDS[@]}"; do
        [[ "${TYPE[$id]}" == VM ]] || continue
        cpu=$(cfgval "${CONF[$id]}" cpu)
        [[ "$cpu" == host || "$cpu" == host,* || "$cpu" == *cputype=host* ]] && host_vms+=("VM$id")
    done

    if (( n_models > 1 )); then
        echo "  Node CPUs:"
        sed 's/^/      /; s/\t/  /' <<< "$models"
    fi
    if [[ ${#host_vms[@]} -eq 0 ]]; then
        ok "No VMs use cpu=host"
        RESULTS["GUEST_CPU_HOST"]="OK"
    elif (( n_models > 1 )); then
        warn "VM(s) with cpu=host on a cluster with $n_models different CPU models: ${host_vms[*]} — live migration between them can fail; consider x86-64-v2-AES or x86-64-v3"
        RESULTS["GUEST_CPU_HOST"]="MIXED CPUS: ${#host_vms[@]} VM(s)"
    else
        info "VM(s) with cpu=host: ${host_vms[*]} — fine while every node has the same CPU"
        RESULTS["GUEST_CPU_HOST"]="INFO: ${#host_vms[@]} VM(s), same CPUs"
    fi
}

# =============================================================================
# SECTION 7 – CONTAINERS
# =============================================================================
check_containers() {
    local id priv=() any=false
    for id in "${IDS[@]}"; do
        [[ "${TYPE[$id]}" == CT ]] || continue
        any=true
        [[ "$(cfgval "${CONF[$id]}" unprivileged)" == 1 ]] || priv+=("CT$id")
    done
    $any || return
    hr
    echo -e "${BOLD}║  CONTAINERS${NC}"
    hr
    # Privileged isn't wrong in itself (NFS mounts, some Docker setups need
    # it), but root in the container is then root on the host.
    if [[ ${#priv[@]} -gt 0 ]]; then
        info "Privileged container(s): ${priv[*]} — root inside is root on the host; use unprivileged unless something needs otherwise"
        RESULTS["CT_PRIVILEGED"]="INFO: ${#priv[@]} privileged"
    else
        ok "All containers are unprivileged"
        RESULTS["CT_PRIVILEGED"]="OK"
    fi
}

# =============================================================================
# SECTION 8 – DISKS
# =============================================================================
check_disks() {
    hr
    echo -e "${BOLD}║  DISKS${NC}"
    hr

    # ---- Detached disks ----
    # Removing a disk from a guest only detaches it: it stays on storage as
    # unusedN until someone deletes it.
    local id line count=0
    echo ""
    echo "  --- Detached disks (unusedN) ---"
    for id in "${IDS[@]}"; do
        while IFS= read -r line; do
            echo "  ${TYPE[$id]} $id: $line"
            count=$((count + 1))
        done < <(awk '/^\[/{exit} /^unused[0-9]+: /' "${CONF[$id]}")
    done
    if (( count > 0 )); then
        warn "$count detached disk(s) still using space — reattach or delete them in the guest's Hardware/Resources tab"
        RESULTS["DISK_UNUSED"]="DETACHED: $count"
    else
        ok "No detached disks"
        RESULTS["DISK_UNUSED"]="OK"
    fi

    # ---- Volumes nobody refers to ----
    # Lists every guest volume on the storages this node sees and checks it
    # against all guest configs in the cluster (snapshots and unusedN
    # included). Leftovers come from failed migrations, restores or clones,
    # and from guests deleted by hand.
    echo ""
    echo "  --- Unreferenced volumes ---"
    local storages vols
    storages=$(pvesh get "/nodes/$NODE/storage" --enabled 1 --output-format json 2>/dev/null | python3 -c '
import json, sys
try:
    for s in json.load(sys.stdin):
        c = s.get("content", "").split(",")
        if s.get("active") and ("images" in c or "rootdir" in c):
            print(s["storage"])
except Exception:
    pass
' 2>/dev/null)
    if [[ -z "$storages" ]]; then
        echo "  Couldn't list guest storages via pvesh — skipping"
        return
    fi
    echo "  Storages scanned: $(xargs <<< "$storages")"

    vols=$(for s in $storages; do
               pvesh get "/nodes/$NODE/storage/$s/content" --output-format json 2>/dev/null
               echo
           done | python3 -c '
import glob, json, re, sys

# Every volume ID referenced from any guest config in the cluster: the
# first comma field of each value that looks like storage:volume.
refs, has_conf = set(), set()
for f in glob.glob("/etc/pve/nodes/*/qemu-server/*.conf") + glob.glob("/etc/pve/nodes/*/lxc/*.conf"):
    has_conf.add(f.rsplit("/", 1)[1][:-5])
    try:
        for line in open(f):
            if ": " in line:
                v = line.split(": ", 1)[1].strip().split(",")[0]
                if re.match(r"^[\w.-]+:\S", v):
                    refs.add(v)
    except OSError:
        pass

# stdin is one JSON array per storage, back to back.
data, pos, dec, lists = sys.stdin.read(), 0, json.JSONDecoder(), []
while True:
    while pos < len(data) and data[pos].isspace():
        pos += 1
    if pos >= len(data):
        break
    try:
        obj, pos = dec.raw_decode(data, pos)
    except ValueError:
        break
    lists.append(obj)

seen = set()
for items in lists:
    for v in items:
        volid = v.get("volid", "")
        # vmid 0/missing: raw LUNs and the like, not owned by a guest.
        if v.get("content") not in ("images", "rootdir") or not v.get("vmid") \
                or volid in seen or volid in refs:
            continue
        seen.add(volid)
        vmid = str(v.get("vmid", ""))
        kind = "UNREF" if vmid in has_conf else "ORPHAN"
        print("%s\t%s\t%s\t%.1f" % (kind, volid, vmid, v.get("size", 0) / 2**30))
' 2>/dev/null)

    if [[ -z "$vols" ]]; then
        ok "Every guest volume is referenced by a config"
        RESULTS["DISK_ORPHANED"]="OK"
        return
    fi
    local kind volid vmid gib n_orphan=0 n_unref=0 total=0
    while IFS=$'\t' read -r kind volid vmid gib; do
        if [[ "$kind" == ORPHAN ]]; then
            echo "  $volid  ${gib} GiB  (VM/CT $vmid doesn't exist)"
            n_orphan=$((n_orphan + 1))
        else
            echo "  $volid  ${gib} GiB  (belongs to $vmid but isn't in its config)"
            n_unref=$((n_unref + 1))
        fi
        total=$(awk -v a="$total" -v b="$gib" 'BEGIN{print a + b}')
    done <<< "$vols"
    (( n_orphan > 0 )) && warn "$n_orphan volume(s) belong to guests that no longer exist — check nothing needs them, then: pvesm free <volid>"
    (( n_unref > 0 )) && warn "$n_unref volume(s) aren't in their guest's config — 'qm rescan --vmid <id>' adds them as unusedN so you can review them"
    RESULTS["DISK_ORPHANED"]="UNREFERENCED: $((n_orphan + n_unref)) (${total} GiB)"
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
echo -e "${BOLD}PVE Guest Audit — $(date)${NC}"
echo "Node: $NODE | $(pveversion 2>/dev/null) | Snapshot age limit: $SNAP_DAYS days"
$CLUSTERED && echo "Cluster member — checking this node's guests only"
echo ""

check_inventory
check_snapshots
check_locks
check_agent
check_onboot
check_cpu_type
check_containers
check_disks
print_summary

# ------------------------------------------------------------------------
# Exit code — same convention as the other scripts in this repo, minus 2
# since no check here is CRITICAL.
#   0 = clean run, no issues
#   1 = warnings
#   3 = could not run (handled at the top)
# ------------------------------------------------------------------------
[[ ${#ISSUES[@]} -gt 0 ]] && exit 1
exit 0
