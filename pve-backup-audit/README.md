# PVE Backup Audit

A read-only bash script that checks the guests on a Proxmox VE node are really being backed up: each one is in a backup job, has a recent backup on storage, the backup tasks aren't failing, and the backup storage is online with room to spare. It prints a colored report and a summary table, and makes no changes.

## What it checks

1. **Backup jobs**: the cluster's scheduled jobs (Datacenter → Backup) with schedule, target storage and which guests they select. Disabled jobs are flagged.
2. **Coverage**: guests on this node that no job includes. This is PVE's own list (the "Guests without backup job" button), so `all`, exclusions, pools and node restrictions are all accounted for.
3. **Last backup**: the newest backup of every guest across all backup storage this node can see, vzdump files and Proxmox Backup Server alike, with its age and how many backups exist. Flags guests whose newest backup is older than `-a DAYS` (default 7), guests that are in a job but have no backup at all, and newest backups that failed PBS verification.
4. **Failed backup tasks**: vzdump tasks on this node in the last `-d DAYS` (default 7) that didn't finish OK, each with the command to read its log. Tasks that only finished with warnings are counted for information.
5. **Backup storage**: storage with `backup` content that's offline (critical, since backups to it fail), 95% full or more (critical), or over 80% full.

Templates are skipped.

## Example output

From a test node (summary section):

```
  Check                               | Status
  ----------------------------------- | ----------------------------
  BACKUP_COVERAGE                     | NOT COVERED: 1
  BACKUP_JOBS                         | 2 job(s), 1 DISABLED
  BACKUP_LAST                         | NONE: 1, OLD: 1, VERIFY FAILED: 1
  BACKUP_STORAGE                      | CRITICAL: 1 inactive, 0 full
  BACKUP_TASKS                        | FAILED: 1

  Issues requiring attention (8):
    → Disabled backup job(s): backup-old — guests that only these jobs cover aren't being backed up
    → Guest(s) not included in any backup job: VM103 (Datacenter → Backup → Guests without backup job)
    → Guest(s) in a backup job but with no backup on any storage: CT201 — check the job's task log
    → Newest backup older than 7 days: VM102(10d)
    → Newest backup failed PBS verification: VM102 — it may not restore; take a new backup
    → 1 backup task(s) failed in the last 7 days — see the task logs above
    → CRITICAL: Backup storage not active: nfs-bk — backups to it will fail (check the mount / PBS connection)
    → Backup storage over 80% full: pbs(87%)
```

## Requirements

- Root privileges, on a Proxmox VE node
- `python3` (included with PVE), used to parse `pvesh` JSON output

## Usage

```bash
sudo ./pve-backup-audit.sh            # backups older than 7 days, failed tasks in the last 7 days
sudo ./pve-backup-audit.sh -a 2       # daily backups: flag anything older than 2 days
sudo ./pve-backup-audit.sh -a 8 -d 14 # weekly backups, look two weeks back for failures
```

Set `-a` a little above your backup interval, so a backup that's still running doesn't trip it.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Clean run, no issues |
| 1 | Warnings |
| 2 | At least one CRITICAL finding (backup storage offline or nearly full) |
| 3 | Could not run (not root, not a PVE host, bad arguments) |

## Notes

- Read-only: it only queries `pvesh`. It never starts a backup, prunes or deletes anything.
- Covers the guests on the node it runs on. In a cluster, run it on each node (or use [pve-check-all](../pve-check-all/)).
- Only backups on storage this node can see are counted. A guest backed up somewhere PVE doesn't know about (a script, a backup inside the guest) will show as having no backup.
- Failed tasks are those of this node. A job's task covers several guests, so open its log to see which guest failed.
