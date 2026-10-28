#!/bin/bash
# =============================================================================
# Proxmox VE Cluster Health Checker
# =============================================================================
# Read-only diagnostic for the things that hold a PVE cluster together.
# Does not touch corosync, HA, Ceph or certificates — it only reads status.
#
# Checks, in order:
#   1. Membership — quorum, offline nodes, two-node clusters without a
#      QDevice, PVE version mismatches between nodes.
#   2. Corosync — per-link status for every node (a dead redundant link is
#      invisible until the other one fails too), and link-down / token
#      timeout / retransmit events in the log window.
#   3. HA — HA quorum, master and LRM state, resources in error, fence or
#      recovery, nodes in maintenance.
#   4. Replication — failing storage replication jobs on any node.
#   5. Time — NTP sync and offset on this node, clock skew and timezone
#      differences between nodes.
#   6. Ceph — overall health and raw usage, if Ceph is configured.
#   7. Certificates — expiry of every node's API certificate and the
#      cluster CA.
#
# On a standalone node, sections 1-4 are skipped and the rest still run.
#
# Usage:
#   ./pve-cluster-health.sh [-d DAYS]
#     -d DAYS   how far back to look in the corosync log (default 7)
#
# Requirements:
#   - root, on a Proxmox VE node
#   - python3 (ships with PVE) for parsing pvesh JSON
#
# Exit codes (see bottom of script):
#   0 = clean run, no issues
#   1 = warnings only
#   2 = at least one CRITICAL finding
#   3 = could not run (not root, not PVE, bad arguments)
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
fail(){ echo -e "  ${RED}[FAIL]${NC} $*"; ISSUES+=("CRITICAL: $*"); }
info(){ echo "  [INFO] $*"; }
# Print up to N lines indented, trimmed to terminal-friendly width.
show(){ head -n "${1:-5}" | cut -c1-150 | sed 's/^/      /'; }

usage() {
    echo "Usage: $0 [-d DAYS]"
    echo "  -d DAYS   how far back to look in the corosync log (default 7)"
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

[[ $EUID -ne 0 ]] && { echo "Run as root."; exit 3; }
command -v pveversion &>/dev/null || { echo "Not a Proxmox VE host."; exit 3; }

NODE=$(hostname -s)
NOW=$(date +%s)
SINCE_ISO=$(date -d "$DAYS days ago" '+%Y-%m-%d %H:%M:%S')
CLUSTERED=false
[[ -f /etc/pve/corosync.conf ]] && CLUSTERED=true

# Filled in by check_membership. ONLINE_NODES is one name per line, for the
# sections that ask every node something; OFFLINE_NODES is space-padded
# for substring matching.
ONLINE_NODES=""
OFFLINE_NODES=" "

# =============================================================================
# SECTION 1 – MEMBERSHIP
# =============================================================================
check_membership() {
    hr
    echo -e "${BOLD}║  CLUSTER MEMBERSHIP${NC}"
    hr

    local pvecm expected total flags
    pvecm=$(pvecm status 2>/dev/null)
    expected=$(awk -F': *' '/^Expected votes:/{print $2+0}' <<< "$pvecm")
    total=$(awk -F': *' '/^Total votes:/{print $2+0}' <<< "$pvecm")
    flags=$(awk -F': *' '/^Flags:/{print $2}' <<< "$pvecm")
    echo "  Cluster: $(awk -F': *' '/^Name:/{print $2}' <<< "$pvecm") | votes $total of $expected | flags: ${flags:-?}"

    if [[ "$flags" == *Quorate* ]]; then
        ok "Cluster is quorate"
        RESULTS["CLUSTER_QUORUM"]="OK"
    else
        fail "Cluster is NOT quorate — /etc/pve is read-only, guests can't be started or changed"
        RESULTS["CLUSTER_QUORUM"]="NO QUORUM"
    fi

    # /cluster/status lists every configured node with an online flag.
    local nodes
    nodes=$(pvesh get /cluster/status --output-format json 2>/dev/null | python3 -c '
import json, sys
try:
    for n in json.load(sys.stdin):
        if n.get("type") == "node":
            print("%s\t%s\t%s" % (n.get("name"), n.get("online", 0), n.get("ip", "")))
except Exception:
    pass
' 2>/dev/null)
    if [[ -z "$nodes" ]]; then
        echo "  Couldn't read /cluster/status via pvesh — skipping node checks"
        return
    fi
    local name online ip offline=() n_nodes=0
    echo ""
    while IFS=$'\t' read -r name online ip; do
        n_nodes=$((n_nodes + 1))
        if [[ "$online" == 1 ]]; then
            printf "  %-20s %-15s online\n" "$name" "$ip"
            ONLINE_NODES+="$name"$'\n'
        else
            printf "  %-20s %-15s OFFLINE\n" "$name" "$ip"
            offline+=("$name")
            OFFLINE_NODES+="$name "
        fi
    done <<< "$nodes"
    echo ""
    if [[ ${#offline[@]} -gt 0 ]]; then
        warn "Node(s) offline: ${offline[*]}"
        RESULTS["CLUSTER_NODES"]="OFFLINE: ${offline[*]}"
    else
        ok "All $n_nodes nodes online"
        RESULTS["CLUSTER_NODES"]="OK ($n_nodes nodes)"
    fi

    # Two votes and no tie-breaker: losing either node loses quorum, so the
    # survivor can't start or change anything.
    if (( expected == 2 )) && [[ "$flags" != *Qdevice* ]]; then
        warn "Two-node cluster without a QDevice — if either node goes down, the other loses quorum (add one with: pvecm qdevice setup <ip>)"
        RESULTS["CLUSTER_QDEVICE"]="MISSING (2 nodes)"
    fi

    # ---- PVE versions ----
    # Mixed minor versions are normal mid-upgrade; mixed major versions
    # mean an upgrade was left half done.
    local versions
    versions=$(while IFS= read -r name; do
                   [[ -z "$name" ]] && continue
                   printf '%s\t' "$name"
                   pvesh get "/nodes/$name/version" --output-format json 2>/dev/null |
                       python3 -c 'import json, sys; print(json.load(sys.stdin).get("version", "?"))' 2>/dev/null || echo "?"
               done <<< "$ONLINE_NODES")
    local n_ver n_major
    n_ver=$(cut -f2 <<< "$versions" | grep -v '^?$' | sort -u | wc -l)
    n_major=$(cut -f2 <<< "$versions" | grep -v '^?$' | cut -d. -f1 | sort -u | wc -l)
    if (( n_ver > 1 )); then
        echo "  PVE versions:"
        sed 's/\t/  /' <<< "$versions" | show 50
    fi
    if (( n_major > 1 )); then
        warn "Nodes run different major PVE versions — finish the upgrade; mixed major versions are only supported during one"
        RESULTS["CLUSTER_VERSIONS"]="MIXED MAJOR"
    elif (( n_ver > 1 )); then
        info "Nodes run different PVE point releases — fine for a while, best kept in step"
        RESULTS["CLUSTER_VERSIONS"]="INFO: $n_ver versions"
    elif (( n_ver == 1 )); then
        ok "All nodes on PVE $(cut -f2 <<< "$versions" | grep -v '^?$' | head -1)"
        RESULTS["CLUSTER_VERSIONS"]="OK"
    fi
}

# =============================================================================
# SECTION 2 – COROSYNC
# =============================================================================
check_corosync() {
    hr
    echo -e "${BOLD}║  COROSYNC${NC}"
    hr

    # Node ID -> name, from the nodelist in corosync.conf. (`pvecm nodes`
    # only lists members that are currently up.)
    declare -A idname
    local id name
    while read -r id name; do
        idname[$id]="$name"
    done < <(awk '
        /^[ \t]*node[ \t]*\{/ { id = ""; name = "" }
        /^[ \t]*name:/   { name = $2 }
        /^[ \t]*nodeid:/ { id = $2 }
        /\}/ { if (id != "" && name != "") print id, name; id = ""; name = "" }' /etc/pve/corosync.conf 2>/dev/null)

    # corosync-cfgtool -s prints one block per link with a status line per
    # node. Two formats exist: "nodeid: 2: connected" (corosync 3.1+) and
    # "nodeid 2: link enabled:1 link connected:1" (3.0). Output: link node state.
    local status
    # The local node is skipped: marked "localhost" in the new format, and
    # recognised by the "Local node ID" header in the old one.
    status=$(corosync-cfgtool -s 2>/dev/null | awk '
        /^Local node ID/ { match($0, /[0-9]+/); self = substr($0, RSTART, RLENGTH) }
        /^LINK ID/ { link = $3 }
        /nodeid/ {
            match($0, /[0-9]+/); n = substr($0, RSTART, RLENGTH)
            if ($0 ~ /localhost/ || n == self) next
            st = ($0 ~ /disconnected|link connected:0/) ? "down" : ($0 ~ /connected/ ? "up" : "unknown")
            print link, n, st
        }')
    if [[ -z "$status" ]]; then
        warn "Couldn't read corosync link status (corosync-cfgtool -s) — is corosync running?"
        RESULTS["COROSYNC_LINKS"]="UNKNOWN"
    else
        local links link n st
        links=$(awk '{print $1}' <<< "$status" | sort -un | xargs)
        echo "  Links configured: $links"
        local down=() all_down=()
        for n in $(awk '{print $2}' <<< "$status" | sort -un); do
            local n_up=0 n_down=0 dl=()
            while read -r link st; do
                if [[ "$st" == up ]]; then n_up=$((n_up + 1)); else n_down=$((n_down + 1)); dl+=("$link"); fi
            done < <(awk -v n="$n" '$2 == n {print $1, $3}' <<< "$status")
            printf "  node %-3s %-20s %d/%d link(s) up%s\n" "$n" "${idname[$n]:-?}" "$n_up" $((n_up + n_down)) \
                "${dl[*]:+  (down: link ${dl[*]})}"
            if (( n_up == 0 )); then all_down+=("${idname[$n]:-node $n}")
            elif (( n_down > 0 )); then down+=("${idname[$n]:-node $n} (link ${dl[*]})"); fi
        done
        # A node with every link down is normally one already reported as
        # offline above; only nodes that aren't get a warning of their own.
        local unexplained=() x
        for x in "${all_down[@]}"; do
            [[ "$OFFLINE_NODES" == *" $x "* ]] || unexplained+=("$x")
        done
        [[ ${#all_down[@]} -gt ${#unexplained[@]} ]] && echo "  (no links to offline node(s) — expected)"
        [[ ${#unexplained[@]} -gt 0 ]] && warn "No working corosync link to: ${unexplained[*]}"
        all_down=("${unexplained[@]}")
        if [[ ${#down[@]} -gt 0 ]]; then
            warn "Corosync redundancy lost — link down to: ${down[*]}. The cluster runs on the remaining link; one more failure and those nodes drop out"
            RESULTS["COROSYNC_LINKS"]="DEGRADED"
        elif [[ ${#all_down[@]} -gt 0 ]]; then
            RESULTS["COROSYNC_LINKS"]="NODE(S) UNREACHABLE"
        elif [[ "$links" == *" "* ]]; then
            ok "All links up to every node"
            RESULTS["COROSYNC_LINKS"]="OK"
        else
            ok "Link up to every node"
            info "Only one corosync link — a second link on a separate network/switch protects against a single NIC or switch failure"
            RESULTS["COROSYNC_LINKS"]="INFO: single link"
        fi
    fi

    # ---- Log events ----
    # Token timeouts and retransmits mean corosync packets are late or lost:
    # usually a busy shared network (backups/migration/storage on the same
    # link). Reboots of other nodes also cause some, hence the thresholds.
    local log
    log=$(journalctl -q --no-pager -u corosync --since "$SINCE_ISO" 2>/dev/null)
    echo ""
    echo "  --- Corosync log, last $DAYS days ---"
    if [[ -z "$log" ]]; then
        echo "  No corosync log entries in the window (or no journal)"
        return
    fi
    local tokens retrans linkdown
    tokens=$(grep -c 'Token has not been received' <<< "$log")
    retrans=$(grep -c 'Retransmit List' <<< "$log")
    linkdown=$(grep -cE 'link: host: [0-9]+ link: [0-9]+ is down' <<< "$log")
    echo "  Token timeouts: $tokens | Retransmit lines: $retrans | Link-down events: $linkdown"
    if (( linkdown > 0 )); then
        echo "  Link-down events by host/link:"
        grep -oE 'host: [0-9]+ link: [0-9]+ is down' <<< "$log" | sort | uniq -c | sort -rn | show 10
    fi
    if (( tokens >= 3 || retrans >= 100 )); then
        warn "Corosync is losing or delaying packets ($tokens token timeouts, $retrans retransmit lines in $DAYS days) — corosync needs low latency; keep it off links shared with backup, migration or storage traffic"
        RESULTS["COROSYNC_LOG"]="TOKENS: $tokens RETRANS: $retrans"
    else
        ok "No sign of corosync packet loss"
        RESULTS["COROSYNC_LOG"]="OK"
    fi
}

# =============================================================================
# SECTION 3 – HA
# =============================================================================
check_ha() {
    hr
    echo -e "${BOLD}║  HIGH AVAILABILITY${NC}"
    hr

    local st
    st=$(ha-manager status 2>/dev/null)
    if ! grep -q '^service ' <<< "$st"; then
        echo "  No HA resources configured — skipping."
        return
    fi

    # Lines look like:
    #   quorum OK
    #   master pve1 (active, Wed Oct 28 11:00:00 2026)
    #   lrm pve2 (idle, Wed Oct 28 11:00:00 2026)
    #   service vm:100 (pve1, started)
    if grep -q '^quorum OK' <<< "$st"; then
        ok "HA quorum OK"
        RESULTS["HA_QUORUM"]="OK"
    else
        fail "HA has no quorum — HA can't start, stop or recover anything"
        RESULTS["HA_QUORUM"]="NO QUORUM"
    fi

    local master
    master=$(grep '^master ' <<< "$st")
    if [[ -z "$master" || "$master" == *"old timestamp"* ]]; then
        fail "No active HA master (CRM) — check pve-ha-crm on the nodes: ${master:-none}"
        RESULTS["HA_MASTER"]="NONE"
    else
        echo "  $master"
        RESULTS["HA_MASTER"]="OK"
    fi

    local line node state bad_lrm=() maint=()
    while read -r line; do
        node=$(awk '{print $2}' <<< "$line")
        state=$(sed -E 's/^[^(]*\(([^,)]*).*/\1/' <<< "$line")
        if [[ "$line" == *"old timestamp"* ]]; then bad_lrm+=("$node (no recent update)")
        elif [[ "$state" == maintenance* ]]; then maint+=("$node")
        elif [[ "$state" != active && "$state" != idle ]]; then bad_lrm+=("$node ($state)")
        fi
    done < <(grep '^lrm ' <<< "$st")
    if [[ ${#bad_lrm[@]} -gt 0 ]]; then
        warn "HA LRM not healthy on: ${bad_lrm[*]}"
        RESULTS["HA_LRM"]="PROBLEM: ${#bad_lrm[@]}"
    else
        ok "HA LRM active or idle on all nodes"
        RESULTS["HA_LRM"]="OK"
    fi
    [[ ${#maint[@]} -gt 0 ]] && info "Node(s) in HA maintenance mode: ${maint[*]} — guests were moved off; remember to take them out (ha-manager node-maintenance disable <node>)"

    # Resource states that need a human: error (gave up after retries),
    # fence/recovery (a node was lost and its guests are being recovered).
    local sid errors=() fencing=() n_res=0
    while read -r line; do
        n_res=$((n_res + 1))
        sid=$(awk '{print $2}' <<< "$line")
        state=$(sed -E 's/.*, *([a-z_]+)\)$/\1/' <<< "$line")
        case "$state" in
            error) errors+=("$sid") ;;
            fence|recovery) fencing+=("$sid($state)") ;;
        esac
    done < <(grep '^service ' <<< "$st")
    echo "  HA resources: $n_res"
    if [[ ${#errors[@]} -gt 0 ]]; then
        fail "HA resource(s) in error state: ${errors[*]} — HA has stopped managing them. Fix the cause, then: ha-manager set <sid> --state disabled, and back to started"
    fi
    if [[ ${#fencing[@]} -gt 0 ]]; then
        fail "HA resource(s) being fenced/recovered: ${fencing[*]} — a node was lost"
    fi
    if [[ ${#errors[@]} -eq 0 && ${#fencing[@]} -eq 0 ]]; then
        ok "No HA resources in error, fence or recovery"
        RESULTS["HA_RESOURCES"]="OK ($n_res)"
    else
        RESULTS["HA_RESOURCES"]="CRITICAL: ${#errors[@]} error, ${#fencing[@]} fencing"
    fi
}

# =============================================================================
# SECTION 4 – REPLICATION
# =============================================================================
# Storage replication (ZFS) runs per source node, so ask every online node.
check_replication() {
    local out
    out=$(while IFS= read -r name; do
              [[ -z "$name" ]] && continue
              pvesh get "/nodes/$name/replication" --output-format json 2>/dev/null |
                  N="$name" python3 -c '
import json, os, sys
try:
    for j in json.load(sys.stdin):
        print("%s\t%s\t%s\t%s\t%s" % (os.environ["N"], j.get("id", "?"), j.get("target", "?"),
              j.get("fail_count", 0), (j.get("error") or "").replace("\n", " ")[:100]))
except Exception:
    pass
' 2>/dev/null
          done <<< "$ONLINE_NODES")
    [[ -z "$out" ]] && return

    hr
    echo -e "${BOLD}║  STORAGE REPLICATION${NC}"
    hr
    local node id target fails err bad=() n=0
    while IFS=$'\t' read -r node id target fails err; do
        n=$((n + 1))
        if [[ "$fails" != 0 || -n "$err" ]]; then
            echo "  $id  $node → $target  failed $fails time(s): $err"
            bad+=("$id")
        fi
    done <<< "$out"
    if [[ ${#bad[@]} -gt 0 ]]; then
        warn "Replication job(s) failing: ${bad[*]} — the replica on the target is getting older (pvesr status on the source node)"
        RESULTS["REPLICATION"]="FAILING: ${#bad[@]} of $n"
    else
        ok "All $n replication job(s) OK"
        RESULTS["REPLICATION"]="OK ($n jobs)"
    fi
}

# =============================================================================
# SECTION 5 – TIME
# =============================================================================
check_time() {
    hr
    echo -e "${BOLD}║  TIME SYNC${NC}"
    hr

    # chrony is the default since PVE 7.
    if command -v chronyc &>/dev/null; then
        local tr leap offset
        tr=$(chronyc tracking 2>/dev/null)
        leap=$(awk -F': *' '/^Leap status/{print $2}' <<< "$tr")
        # "System time : 0.000012345 seconds slow of NTP time"
        offset=$(awk -F': *' '/^System time/{split($2, a, " "); print a[1]}' <<< "$tr")
        echo "  chrony: $(awk -F': *' '/^Reference ID/{print $2}' <<< "$tr") | leap status: ${leap:-?} | offset: ${offset:-?}s"
        if [[ -z "$tr" ]]; then
            warn "chronyd isn't answering — is it running? (systemctl status chrony)"
            RESULTS["TIME_SYNC"]="CHRONY DOWN"
        elif [[ "$leap" != Normal ]]; then
            warn "This node's clock isn't synchronised (chrony leap status: ${leap:-?}) — check NTP sources: chronyc sources"
            RESULTS["TIME_SYNC"]="NOT SYNCED"
        elif awk -v o="$offset" 'BEGIN{exit !(o > 0.1 || o < -0.1)}'; then
            warn "Clock is ${offset}s off NTP time — chrony is still correcting it"
            RESULTS["TIME_SYNC"]="OFFSET ${offset}s"
        else
            ok "Clock synchronised"
            RESULTS["TIME_SYNC"]="OK"
        fi
    else
        local synced
        synced=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
        if [[ "$synced" == yes ]]; then
            ok "Clock synchronised (timedatectl)"
            RESULTS["TIME_SYNC"]="OK"
        else
            warn "Clock not NTP-synchronised (timedatectl NTPSynchronized=${synced:-?}) — install/enable chrony"
            RESULTS["TIME_SYNC"]="NOT SYNCED"
        fi
    fi

    # ---- Skew between nodes ----
    # Ask each node for its time over the API and compare with the midpoint
    # of the request. pvesh takes a moment to start, so only skew of a few
    # seconds is meaningful here — which is already enough to upset Ceph,
    # certificates and log correlation.
    $CLUSTERED || return
    local skews
    skews=$(printf '%s' "$ONLINE_NODES" | python3 -c '
import json, subprocess, sys, time
for n in sys.stdin.read().split():
    try:
        t0 = time.time()
        out = subprocess.run(["pvesh", "get", "/nodes/%s/time" % n, "--output-format", "json"],
                             capture_output=True, text=True, timeout=20).stdout
        t1 = time.time()
        d = json.loads(out)
        print("%s\t%.0f\t%s" % (n, d["time"] - (t0 + t1) / 2, d.get("timezone", "?")))
    except Exception:
        pass
' 2>/dev/null)
    [[ -z "$skews" ]] && return
    local node skew tz bad=() n_tz
    echo ""
    while IFS=$'\t' read -r node skew tz; do
        printf "  %-20s skew %+ds  %s\n" "$node" "$skew" "$tz"
        (( ${skew#-} >= 3 )) && bad+=("$node(${skew}s)")
    done <<< "$skews"
    if [[ ${#bad[@]} -gt 0 ]]; then
        warn "Clock skew between nodes: ${bad[*]} — check chrony on those nodes"
        RESULTS["TIME_SKEW"]="SKEW: ${bad[*]}"
    else
        ok "Node clocks agree"
        RESULTS["TIME_SKEW"]="OK"
    fi
    n_tz=$(cut -f3 <<< "$skews" | sort -u | wc -l)
    (( n_tz > 1 )) && info "Nodes use different timezones — harmless for the cluster, confusing when comparing logs"
}

# =============================================================================
# SECTION 6 – CEPH
# =============================================================================
check_ceph() {
    [[ -f /etc/pve/ceph.conf ]] && command -v ceph &>/dev/null || return
    hr
    echo -e "${BOLD}║  CEPH${NC}"
    hr

    local health
    health=$(timeout 30 ceph health detail 2>/dev/null)
    case "$health" in
        HEALTH_OK*)
            ok "Ceph: HEALTH_OK"
            RESULTS["CEPH_HEALTH"]="OK" ;;
        HEALTH_WARN*)
            show 15 <<< "$health"
            warn "Ceph: HEALTH_WARN — see details above"
            RESULTS["CEPH_HEALTH"]="HEALTH_WARN" ;;
        HEALTH_ERR*)
            show 15 <<< "$health"
            fail "Ceph: HEALTH_ERR — see details above"
            RESULTS["CEPH_HEALTH"]="CRITICAL: HEALTH_ERR" ;;
        *)
            fail "Ceph is configured but didn't answer within 30s — monitors down or no quorum?"
            RESULTS["CEPH_HEALTH"]="CRITICAL: NO ANSWER"
            return ;;
    esac

    # Ceph's own nearfull warning fires at 85% per OSD; warn on the raw
    # total a little earlier, since recovering from a lost node needs room.
    local pct
    pct=$(timeout 30 ceph df -f json 2>/dev/null | python3 -c '
import json, sys
try:
    print("%.0f" % (json.load(sys.stdin)["stats"]["total_used_raw_ratio"] * 100))
except Exception:
    pass
' 2>/dev/null)
    if [[ -n "$pct" ]]; then
        echo "  Raw usage: ${pct}%"
        if (( pct >= 75 )); then
            warn "Ceph raw usage ${pct}% — above ~75% there may not be room to re-replicate after losing a node"
            RESULTS["CEPH_USAGE"]="${pct}%"
        else
            RESULTS["CEPH_USAGE"]="OK (${pct}%)"
        fi
    fi
}

# =============================================================================
# SECTION 7 – CERTIFICATES
# =============================================================================
# PVE renews its own node certificates, and ACME certificates 30 days before
# expiry, from the daily pve-daily-update job. Anything under 14 days means
# that renewal isn't happening.
check_certs() {
    hr
    echo -e "${BOLD}║  CERTIFICATES${NC}"
    hr
    if ! command -v openssl &>/dev/null; then
        echo "  openssl not found — skipping"
        return
    fi
    local f end days label expired=() soon=() n=0
    for f in /etc/pve/pve-root-ca.pem /etc/pve/nodes/*/pve-ssl.pem /etc/pve/nodes/*/pveproxy-ssl.pem; do
        [[ -f "$f" ]] || continue
        end=$(openssl x509 -enddate -noout -in "$f" 2>/dev/null | cut -d= -f2)
        [[ -z "$end" ]] && continue
        n=$((n + 1))
        days=$(( ($(date -d "$end" +%s) - NOW) / 86400 ))
        label=${f#/etc/pve/}; label=${label#nodes/}
        printf "  %-40s %5s days  (%s)\n" "$label" "$days" "$end"
        if (( days < 0 )); then expired+=("$label")
        elif (( days < 14 )); then soon+=("$label (${days}d)"); fi
    done
    if [[ ${#expired[@]} -gt 0 ]]; then
        fail "Expired certificate(s): ${expired[*]} — web UI/API connections to those nodes fail (pvecm updatecerts --force, or renew the ACME/custom cert)"
    fi
    if [[ ${#soon[@]} -gt 0 ]]; then
        warn "Certificate(s) expiring within 14 days: ${soon[*]} — automatic renewal isn't working; check the pve-daily-update service log"
    fi
    if (( n == 0 )); then
        echo "  No certificates found under /etc/pve"
    elif [[ ${#expired[@]} -eq 0 && ${#soon[@]} -eq 0 ]]; then
        ok "All $n certificate(s) valid for 14+ days"
        RESULTS["CERTIFICATES"]="OK"
    else
        RESULTS["CERTIFICATES"]="EXPIRED: ${#expired[@]}, EXPIRING: ${#soon[@]}"
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
        elif echo "$val" | grep -qiE "CRITICAL|NO QUORUM|NONE|EXPIRED: [1-9]|UNREACHABLE"; then
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
echo -e "${BOLD}PVE Cluster Health Checker — $(date)${NC}"
echo "Node: $NODE | $(pveversion 2>/dev/null) | Log window: $DAYS days"
echo ""

if $CLUSTERED; then
    check_membership
    check_corosync
    check_ha
    check_replication
else
    echo "Standalone node (no /etc/pve/corosync.conf) — skipping cluster, corosync, HA and replication checks."
    echo ""
fi
check_time
check_ceph
check_certs
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
