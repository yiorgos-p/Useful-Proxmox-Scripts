#!/bin/bash
# =============================================================================
# Proxmox VE: run all checks
# =============================================================================
# Runs every health check in this repo, prints one combined summary with
# each script's issues, and optionally saves the full reports and emails
# the summary when something needs attention. Read-only, like the checks.
#
# Runs, in order: hardware, drive, memory, cluster health, guest audit,
# backup audit.
# (Not the ZFS disk replacement helper — that one isn't a check.)
#
# Usage:
#   ./pve-check-all.sh [-o DIR] [-m ADDRESS] [-q]
#     -o DIR       save each full report as DIR/<host>-<date>-<check>.log
#     -m ADDRESS   email the summary to ADDRESS if there are any issues
#                  (needs a working MTA; PVE's postfix forwards root's mail)
#     -q           print only the summary (for cron)
#
# The scripts are looked for next to this one and in the repo layout
# (../<name>/<name>.sh), so it works from a git clone or one folder.
#
# Exit codes:
#   0 = every check clean
#   1 = warnings, or a check couldn't run
#   2 = at least one CRITICAL finding
#   3 = could not run (not root, bad arguments)
#
# =============================================================================

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; NC='\033[0m'; BOLD='\033[1m'

CHECKS=(pve-hardware-health-check pve-drive-health-check pve-memory-check pve-cluster-health pve-guest-audit pve-backup-audit)
MAX_ISSUES=10   # issues listed per check in the summary

usage() {
    echo "Usage: $0 [-o DIR] [-m ADDRESS] [-q]"
    echo "  -o DIR       save each full report in DIR"
    echo "  -m ADDRESS   email the summary to ADDRESS if there are any issues"
    echo "  -q           print only the summary"
}

OUTDIR=""; MAILTO=""; QUIET=false
while getopts ":o:m:qh" opt; do
    case "$opt" in
        o) OUTDIR="$OPTARG" ;;
        m) MAILTO="$OPTARG" ;;
        q) QUIET=true ;;
        h) usage; exit 0 ;;
        *) usage; exit 3 ;;
    esac
done
[[ $EUID -ne 0 ]] && { echo "Run as root."; exit 3; }
if [[ -n "$OUTDIR" ]]; then
    mkdir -p "$OUTDIR" || { echo "Can't create $OUTDIR"; exit 3; }
fi

SELF_DIR=$(dirname "$(readlink -f "$0")")
HOST=$(hostname -s)
STAMP=$(date +%F-%H%M)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

find_check() {
    local f
    for f in "$SELF_DIR/$1.sh" "$SELF_DIR/../$1/$1.sh" "$SELF_DIR/$1/$1.sh"; do
        [[ -f "$f" ]] && { readlink -f "$f"; return; }
    done
}

# ── run ──────────────────────────────────────────────────────────────────────
declare -A RC
$QUIET || echo -e "${BOLD}PVE check-all — $HOST — $(date)${NC}"
for c in "${CHECKS[@]}"; do
    script=$(find_check "$c")
    if [[ -z "$script" ]]; then
        RC[$c]=missing
        continue
    fi
    $QUIET || echo "  running $c ..."
    # Reports are stored without color codes so they read cleanly in a
    # file or an email.
    bash "$script" < /dev/null 2>&1 | sed 's/\x1b\[[0-9;]*m//g' > "$WORK/$c.log"
    RC[$c]=${PIPESTATUS[0]}
    [[ -n "$OUTDIR" ]] && cp "$WORK/$c.log" "$OUTDIR/$HOST-$STAMP-$c.log"
done

# ── summary ──────────────────────────────────────────────────────────────────
# Each check ends with "Issues requiring attention (N):" followed by one
# "→ ..." line per issue; pull those out.
summary() {
    local c rc label issues n
    echo "PVE check-all summary for $HOST — $(date)"
    echo ""
    for c in "${CHECKS[@]}"; do
        rc=${RC[$c]}
        case "$rc" in
            0) label="OK" ;;
            1) label="WARN" ;;
            2) label="CRITICAL" ;;
            missing) label="NOT FOUND" ;;
            *) label="DIDN'T RUN (exit $rc)" ;;
        esac
        printf "  %-28s %s\n" "$c" "$label"
        if [[ "$rc" == 1 || "$rc" == 2 ]]; then
            issues=$(sed -n '/Issues requiring attention/,$p' "$WORK/$c.log" | grep '→' | sed 's/^ *→ */      - /')
            if [[ -n "$issues" ]]; then
                # Keep the summary (and the email) readable when one check
                # finds dozens of issues; the full list is in its report.
                n=$(wc -l <<< "$issues")
                head -n "$MAX_ISSUES" <<< "$issues"
                (( n > MAX_ISSUES )) && echo "      ... and $((n - MAX_ISSUES)) more (full list in the $c report)"
            fi
        elif [[ "$rc" != 0 && "$rc" != missing ]]; then
            # Exit 3: the script says why on its last line.
            echo "      $(grep -v '^$' "$WORK/$c.log" | tail -1)"
        fi
    done
    echo ""
    [[ -n "$OUTDIR" ]] && echo "Full reports: $OUTDIR/$HOST-$STAMP-*.log"
}

summary > "$WORK/summary.txt"

if $QUIET; then
    cat "$WORK/summary.txt"
else
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║  ALL CHECKS${NC}"
    echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
    # Same text as the email, with the status words colored.
    tail -n +3 "$WORK/summary.txt" | sed -E \
        -e "s/ OK$/ $(printf '%b' "$GREEN")OK$(printf '%b' "$NC")/" \
        -e "s/ WARN$/ $(printf '%b' "$YELLOW")WARN$(printf '%b' "$NC")/" \
        -e "s/ CRITICAL$/ $(printf '%b' "$RED")CRITICAL$(printf '%b' "$NC")/"
fi

# ── exit code and mail ───────────────────────────────────────────────────────
worst=0; status=OK
for c in "${CHECKS[@]}"; do
    case "${RC[$c]}" in
        0) ;;
        2) worst=2 ;;
        *) [[ $worst -lt 1 ]] && worst=1 ;;
    esac
done
(( worst == 1 )) && status=WARN
(( worst == 2 )) && status=CRITICAL
if [[ " ${RC[*]} " == *" missing "* ]]; then
    echo ""
    echo "Some checks weren't found next to this script. Easiest fix: git clone https://github.com/yiorgos-p/Useful-Proxmox-Scripts"
fi

if [[ -n "$MAILTO" && $worst -gt 0 ]]; then
    subject="[pve-check-all] $HOST: $status"
    if command -v sendmail &>/dev/null; then
        { echo "To: $MAILTO"; echo "Subject: $subject"; echo ""; cat "$WORK/summary.txt"; } | sendmail -t
    elif command -v mail &>/dev/null; then
        mail -s "$subject" "$MAILTO" < "$WORK/summary.txt"
    else
        echo "No sendmail or mail command found — couldn't send the summary to $MAILTO" >&2
    fi
fi

exit "$worst"
