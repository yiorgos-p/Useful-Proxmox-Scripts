#!/bin/bash
# =============================================================================
# Proxmox VE Backup Audit
# =============================================================================
# Read-only check that the guests on this node are actually being backed
# up: covered by a job, with a recent backup on storage, no failed backup
# tasks, and backup storage that isn't about to fill up. Doesn't start,
# edit or delete anything.
#
# Checks, in order:
#   1. Backup jobs — the cluster's scheduled jobs; disabled ones.
#   2. Coverage — guests on this node that no backup job includes.
#   3. Last backup — newest backup of each guest on every backup storage
#      this node can see (vzdump files and PBS); too old, none at all, or
#      failed PBS verification.
#   4. Failed backup tasks — vzdump tasks on this node that didn't end OK.
#   5. Backup storage — inactive, or getting full.
#
# Usage:
#   ./pve-backup-audit.sh [-a DAYS] [-d DAYS]
#     -a DAYS   flag guests whose newest backup is older than this (default 7)
#     -d DAYS   look for failed backup tasks this far back (default 7)
#
# Requirements:
#   - root, on a Proxmox VE node
#   - python3 (ships with PVE) for parsing pvesh JSON
#
# Exit codes (see bottom of script):
#   0 = clean run, no issues
#   1 = warnings
#   2 = at least one CRITICAL finding (backup storage offline or full)
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

usage() {
    echo "Usage: $0 [-a DAYS] [-d DAYS]"
    echo "  -a DAYS   flag guests whose newest backup is older than this (default 7)"
    echo "  -d DAYS   look for failed backup tasks this far back (default 7)"
}

# ── arguments ────────────────────────────────────────────────────────────────
MAX_AGE=7
TASK_DAYS=7
while getopts ":a:d:h" opt; do
    case "$opt" in
        a) MAX_AGE="$OPTARG" ;;
        d) TASK_DAYS="$OPTARG" ;;
        h) usage; exit 0 ;;
        *) usage; exit 3 ;;
    esac
done
[[ "$MAX_AGE" =~ ^[1-9][0-9]*$ ]] || { echo "-a needs a positive number of days"; exit 3; }
[[ "$TASK_DAYS" =~ ^[1-9][0-9]*$ ]] || { echo "-d needs a positive number of days"; exit 3; }

[[ $EUID -ne 0 ]] && { echo "Run as root."; exit 3; }
command -v pveversion &>/dev/null || { echo "Not a Proxmox VE host."; exit 3; }

NODE=$(hostname -s)
NOW=$(date +%s)

# ── gather guests ────────────────────────────────────────────────────────────
# Guests on this node, templates left out (they rarely change, and many
# setups deliberately don't back them up). "VMID TYPE NAME" per line.
GUESTS=$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null | python3 -c '
import json, sys
node = sys.argv[1]
try:
    for g in sorted(json.load(sys.stdin), key=lambda g: g["vmid"]):
        if g.get("node") == node and not g.get("template"):
            print(g["vmid"], "VM" if g.get("type") == "qemu" else "CT", g.get("name") or "-")
except Exception:
    pass
' "$NODE" 2>/dev/null)
declare -A GTYPE GNAME
GIDS=()
while read -r id t n; do
    [[ -z "$id" ]] && continue
    GIDS+=("$id"); GTYPE[$id]=$t; GNAME[$id]=$n
done <<< "$GUESTS"

# Storages on this node that hold backups: "name active used_pct type".
BSTORES=$(pvesh get "/nodes/$NODE/storage" --content backup --enabled 1 --output-format json 2>/dev/null | python3 -c '
import json, sys
try:
    for s in sorted(json.load(sys.stdin), key=lambda s: s["storage"]):
        total, used = s.get("total") or 0, s.get("used") or 0
        pct = int(round(100 * used / total)) if total else -1
        print(s["storage"], 1 if s.get("active") else 0, pct, s.get("type", "?"))
except Exception:
    pass
' 2>/dev/null)

# =============================================================================
# SECTION 1 – BACKUP JOBS
# =============================================================================
check_jobs() {
    hr
    echo -e "${BOLD}║  BACKUP JOBS${NC}"
    hr
    local jobs
    jobs=$(pvesh get /cluster/backup --output-format json 2>/dev/null | python3 -c '
import json, sys
try:
    for j in json.load(sys.stdin):
        if j.get("all"):
            sel = "all guests"
            if j.get("exclude"):
                sel += " except " + j["exclude"]
        elif j.get("pool"):
            sel = "pool " + j["pool"]
        else:
            sel = "guests " + str(j.get("vmid", "?"))
        if j.get("node"):
            sel += " (node " + j["node"] + " only)"
        en = "yes" if str(j.get("enabled", 1)) != "0" else "no"
        print("\t".join([j.get("id", "?"), en, j.get("schedule") or j.get("starttime") or "?",
                         j.get("storage", "?"), sel]))
except Exception:
    pass
' 2>/dev/null)
    if [[ -z "$jobs" ]]; then
        warn "No scheduled backup jobs in this cluster (Datacenter → Backup)"
        RESULTS["BACKUP_JOBS"]="NONE"
        return
    fi
    printf "  %-22s %-8s %-18s %-20s %s\n" JOB ENABLED SCHEDULE STORAGE SELECTION
    local id en sched st sel disabled=() n=0
    while IFS=$'\t' read -r id en sched st sel; do
        printf "  %-22.22s %-8s %-18.18s %-20.20s %s\n" "$id" "$en" "$sched" "$st" "$sel"
        n=$((n + 1))
        [[ "$en" == no ]] && disabled+=("$id")
    done <<< "$jobs"
    echo ""
    if [[ ${#disabled[@]} -gt 0 ]]; then
        warn "Disabled backup job(s): ${disabled[*]} — guests that only these jobs cover aren't being backed up"
        RESULTS["BACKUP_JOBS"]="$n job(s), ${#disabled[@]} DISABLED"
    else
        ok "$n backup job(s), all enabled"
        RESULTS["BACKUP_JOBS"]="OK: $n job(s)"
    fi
}

# =============================================================================
# SECTION 2 – COVERAGE
# =============================================================================
# PVE's own answer to "which guests does no job include" — the same list as
# Datacenter → Backup → "Guests without backup job". It accounts for "all",
# exclusions, pools and node restrictions, so there's no need to re-derive
# job selection here.
UNCOVERED=" "
check_coverage() {
    hr
    echo -e "${BOLD}║  COVERAGE${NC}"
    hr
    if [[ ${#GIDS[@]} -eq 0 ]]; then
        echo "  No guests on this node."
        return
    fi
    local out id list=()
    if ! out=$(pvesh get /cluster/backup-info/not-backed-up --output-format json 2>/dev/null); then
        echo "  Couldn't query /cluster/backup-info/not-backed-up — skipping"
        RESULTS["BACKUP_COVERAGE"]="INFO: not checked"
        return
    fi
    for id in $(python3 -c '
import json, sys
try:
    print(" ".join(str(g["vmid"]) for g in json.load(sys.stdin)))
except Exception:
    pass
' <<< "$out"); do
        [[ -n "${GTYPE[$id]}" ]] || continue     # on another node
        list+=("${GTYPE[$id]}$id")
        UNCOVERED+="$id "
    done
    if [[ ${#list[@]} -gt 0 ]]; then
        warn "Guest(s) not included in any backup job: ${list[*]} (Datacenter → Backup → Guests without backup job)"
        RESULTS["BACKUP_COVERAGE"]="NOT COVERED: ${#list[@]}"
    else
        ok "All ${#GIDS[@]} guest(s) on this node are in a backup job"
        RESULTS["BACKUP_COVERAGE"]="OK"
    fi
}

# =============================================================================
# SECTION 3 – LAST BACKUP
# =============================================================================
check_last_backup() {
    hr
    echo -e "${BOLD}║  LAST BACKUP${NC}"
    hr
    if [[ ${#GIDS[@]} -eq 0 ]]; then
        echo "  No guests on this node."
        return
    fi
    local s active stores=()
    while read -r s active _ _; do
        [[ -n "$s" && "$active" == 1 ]] && stores+=("$s")
    done <<< "$BSTORES"
    if [[ ${#stores[@]} -eq 0 ]]; then
        warn "No active backup storage on this node — can't look for backups"
        RESULTS["BACKUP_LAST"]="NO STORAGE"
        return
    fi
    echo "  Storages scanned: ${stores[*]}"
    echo ""

    # Newest backup per VMID across all storages:
    # "vmid ctime count storage verify" (verify is PBS only, "-" otherwise).
    local newest
    newest=$(for s in "${stores[@]}"; do
                 pvesh get "/nodes/$NODE/storage/$s/content" --content backup --output-format json 2>/dev/null \
                     | python3 -c '
import json, sys
try:
    for v in json.load(sys.stdin):
        if v.get("vmid") is not None and v.get("ctime"):
            print(v["vmid"], v["ctime"], sys.argv[1], (v.get("verification") or {}).get("state", "-"))
except Exception:
    pass
' "$s" 2>/dev/null
             done | awk '{ n[$1]++; if ($2 > t[$1]) { t[$1] = $2; s[$1] = $3; v[$1] = $4 } }
                         END { for (i in t) print i, t[i], n[i], s[i], v[i] }')

    declare -A B_TIME B_COUNT B_STORE B_VERIFY
    local id t c st v
    while read -r id t c st v; do
        [[ -z "$id" ]] && continue
        B_TIME[$id]=$t; B_COUNT[$id]=$c; B_STORE[$id]=$st; B_VERIFY[$id]=$v
    done <<< "$newest"

    printf "  %-7s %-4s %-24s %-17s %-8s %-6s %s\n" VMID TYPE NAME "NEWEST BACKUP" AGE COUNT STORAGE
    local old=() never=() badver=() age_d
    for id in "${GIDS[@]}"; do
        if [[ -z "${B_TIME[$id]}" ]]; then
            printf "  %-7s %-4s %-24.24s %-17s %-8s %-6s %s\n" "$id" "${GTYPE[$id]}" "${GNAME[$id]}" "none" "-" 0 "-"
            # Uncovered guests were already reported above.
            [[ "$UNCOVERED" == *" $id "* ]] || never+=("${GTYPE[$id]}$id")
            continue
        fi
        age_d=$(( (NOW - B_TIME[$id]) / 86400 ))
        printf "  %-7s %-4s %-24.24s %-17s %-8s %-6s %s\n" "$id" "${GTYPE[$id]}" "${GNAME[$id]}" \
            "$(date -d "@${B_TIME[$id]}" '+%F %H:%M')" "${age_d}d" "${B_COUNT[$id]}" "${B_STORE[$id]}"
        (( age_d >= MAX_AGE )) && old+=("${GTYPE[$id]}$id(${age_d}d)")
        [[ "${B_VERIFY[$id]}" == failed ]] && badver+=("${GTYPE[$id]}$id")
    done
    echo ""

    local bad=0
    if [[ ${#never[@]} -gt 0 ]]; then
        warn "Guest(s) in a backup job but with no backup on any storage: ${never[*]} — check the job's task log"
        bad=1
    fi
    if [[ ${#old[@]} -gt 0 ]]; then
        warn "Newest backup older than $MAX_AGE days: ${old[*]}"
        bad=1
    fi
    if [[ ${#badver[@]} -gt 0 ]]; then
        warn "Newest backup failed PBS verification: ${badver[*]} — it may not restore; take a new backup"
        bad=1
    fi
    if (( bad )); then
        RESULTS["BACKUP_LAST"]="NONE: ${#never[@]}, OLD: ${#old[@]}, VERIFY FAILED: ${#badver[@]}"
    else
        ok "Every backed-up guest has a backup newer than $MAX_AGE days"
        RESULTS["BACKUP_LAST"]="OK"
    fi
}

# =============================================================================
# SECTION 4 – FAILED BACKUP TASKS
# =============================================================================
check_tasks() {
    hr
    echo -e "${BOLD}║  BACKUP TASKS (last $TASK_DAYS days)${NC}"
    hr
    local since=$((NOW - TASK_DAYS * 86400)) out
    if ! out=$(pvesh get "/nodes/$NODE/tasks" --typefilter vzdump --since "$since" --limit 1000 --output-format json 2>/dev/null); then
        echo "  Couldn't list tasks via pvesh — skipping"
        RESULTS["BACKUP_TASKS"]="INFO: not checked"
        return
    fi
    # One line per finished task: "kind<TAB>start<TAB>guest<TAB>status<TAB>upid"
    # kind is ok, warn (finished with warnings) or failed. A job's task has
    # no guest id — it covers several guests.
    local tasks
    tasks=$(python3 -c '
import json, sys, time
try:
    for t in sorted(json.load(sys.stdin), key=lambda t: t.get("starttime", 0)):
        st = t.get("status")
        if not st or not t.get("endtime"):
            continue            # still running
        kind = "ok" if st == "OK" else "warn" if st.startswith("WARNINGS") else "failed"
        print("\t".join([kind, time.strftime("%Y-%m-%d %H:%M", time.localtime(t.get("starttime", 0))),
                         ("guest " + str(t["id"])) if t.get("id") else "backup job", st, t.get("upid", "")]))
except Exception:
    pass
' <<< "$out")
    local n_ok n_warn n_fail
    n_ok=$(grep -c '^ok' <<< "$tasks")
    n_warn=$(grep -c '^warn' <<< "$tasks")
    n_fail=$(grep -c '^failed' <<< "$tasks")
    echo "  Finished backup tasks: $n_ok OK, $n_warn with warnings, $n_fail failed"
    if (( n_fail > 0 )); then
        echo ""
        local kind start gid st upid
        while IFS=$'\t' read -r kind start gid st upid; do
            [[ "$kind" == failed ]] || continue
            echo "    $start  $gid  $st"
            echo "      log: pvenode task log $upid"
        done <<< "$tasks"
        echo ""
        warn "$n_fail backup task(s) failed in the last $TASK_DAYS days — see the task logs above"
        RESULTS["BACKUP_TASKS"]="FAILED: $n_fail"
    else
        (( n_warn > 0 )) && info "$n_warn task(s) finished with warnings (often a guest agent that didn't answer) — check them in the task log"
        ok "No failed backup tasks"
        RESULTS["BACKUP_TASKS"]="OK"
    fi
}

# =============================================================================
# SECTION 5 – BACKUP STORAGE
# =============================================================================
check_storage() {
    hr
    echo -e "${BOLD}║  BACKUP STORAGE${NC}"
    hr
    if [[ -z "$BSTORES" ]]; then
        warn "No enabled storage with content 'backup' on this node"
        RESULTS["BACKUP_STORAGE"]="NONE"
        return
    fi
    printf "  %-20s %-8s %-8s %s\n" STORAGE TYPE ACTIVE USED
    local s active pct type down=() full=() high=()
    while read -r s active pct type; do
        [[ -z "$s" ]] && continue
        printf "  %-20s %-8s %-8s %s\n" "$s" "$type" "$([[ $active == 1 ]] && echo yes || echo NO)" \
            "$([[ $pct -ge 0 ]] && echo "$pct%" || echo "?")"
        if [[ "$active" != 1 ]]; then down+=("$s")
        elif (( pct >= 95 )); then full+=("$s($pct%)")
        elif (( pct >= 80 )); then high+=("$s($pct%)")
        fi
    done <<< "$BSTORES"
    echo ""
    [[ ${#down[@]} -gt 0 ]] && fail "Backup storage not active: ${down[*]} — backups to it will fail (check the mount / PBS connection)"
    [[ ${#full[@]} -gt 0 ]] && fail "Backup storage almost full: ${full[*]} — the next backups may fail; prune or add space"
    [[ ${#high[@]} -gt 0 ]] && warn "Backup storage over 80% full: ${high[*]}"
    if [[ ${#down[@]} -gt 0 || ${#full[@]} -gt 0 ]]; then
        RESULTS["BACKUP_STORAGE"]="CRITICAL: ${#down[@]} inactive, ${#full[@]} full"
    elif [[ ${#high[@]} -gt 0 ]]; then
        RESULTS["BACKUP_STORAGE"]="HIGH: ${#high[@]} over 80%"
    else
        ok "All backup storage active and under 80% full"
        RESULTS["BACKUP_STORAGE"]="OK"
    fi
}

# =============================================================================
# SUMMARY
# =============================================================================
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
echo -e "${BOLD}PVE Backup Audit — $(date)${NC}"
echo "Node: $NODE | $(pveversion 2>/dev/null) | Max backup age: $MAX_AGE days | Task window: $TASK_DAYS days"
[[ -f /etc/pve/corosync.conf ]] && echo "Cluster member — checking this node's guests only"
echo ""

check_jobs
check_coverage
check_last_backup
check_tasks
check_storage
print_summary

# ------------------------------------------------------------------------
# Exit code — same convention as the other scripts in this repo.
#   0 = clean run, no issues
#   1 = warnings only (nothing CRITICAL)
#   2 = at least one CRITICAL finding
#   3 = could not run (handled at the top)
# ------------------------------------------------------------------------
for issue in "${ISSUES[@]}"; do
    [[ "$issue" == CRITICAL:* ]] && exit 2
done
[[ ${#ISSUES[@]} -gt 0 ]] && exit 1
exit 0
