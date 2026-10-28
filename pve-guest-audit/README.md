# PVE Guest Audit

A read-only bash script that audits the VMs and containers on a Proxmox VE node for housekeeping problems: old snapshots, stuck locks, dead guest agents, guests that won't come back after a reboot, settings that break live migration, and disks that are using space for nothing. It prints a colored report and a summary table, and makes no changes. Every finding includes the command you'd use to fix it.

## What it checks

1. **Inventory**: every guest on the node with its status, snapshot count and lock.
2. **Snapshots**: snapshots older than `-s DAYS` (default 14). On ZFS, LVM-thin and Ceph each snapshot keeps every block changed since it was taken, so old ones slowly fill the pool. Also finds `vzdump` snapshots left on containers by snapshot-mode backups that didn't finish.
3. **Locks and pending changes**: guests still locked (`backup`, `migrate`, `snapshot`...) with no task running, which usually means a task died. Config changes sitting in `[PENDING]` that only apply after a full stop and start.
4. **QEMU guest agent**: VMs with the agent enabled but not answering. Backups of those run without a filesystem freeze, and nothing tells you. Running VMs without the agent are listed for information.
5. **Start on boot**: running guests without `onboot`, which won't come back after a host reboot. HA-managed guests are skipped, since the HA stack starts them.
6. **CPU type** (clusters only): VMs using `cpu: host` when the cluster's nodes have different CPU models, which can make live migration fail. With identical nodes it's only noted.
7. **Containers**: privileged containers, for information.
8. **Disks**: detached `unusedN` disks, plus volumes on storage that no guest config in the cluster refers to (left behind by failed migrations, restores or hand-deleted guests), with their size.

## Example output

From a test node (summary section):

```
  Check                               | Status
  ----------------------------------- | ----------------------------
  CT_PRIVILEGED                       | INFO: 1 privileged
  DISK_ORPHANED                       | UNREFERENCED: 3 (26 GiB)
  DISK_UNUSED                         | DETACHED: 1
  GUEST_AGENT                         | NOT RESPONDING: 1
  GUEST_CPU_HOST                      | MIXED CPUS: 1 VM(s)
  GUEST_LOCKS                         | STALE: 1
  GUEST_ONBOOT                        | NO ONBOOT: 1
  GUEST_PENDING                       | PENDING: 1
  SNAPSHOTS_OLD                       | OLD: 1 on 1 guest(s)
  SNAPSHOTS_VZDUMP                    | LEFTOVER: CT200

  Issues requiring attention (10):
    → 1 snapshot(s) older than 14 days on: VM101 (remove with: qm delsnapshot / pct delsnapshot <id> <name>)
    → Guest(s) locked with no task running: VM103(migrate) — left over from a failed task? Check the task log, then: qm unlock / pct unlock <id>
    → Guest agent enabled but not responding: VM102 — service not installed or not running inside the guest; backups run without a filesystem freeze
    → 2 volume(s) belong to guests that no longer exist — check nothing needs them, then: pvesm free <volid>
    ...
```

## Requirements

- Root privileges, on a Proxmox VE node
- `python3` (included with PVE), used to parse `pvesh` JSON output

## Usage

```bash
sudo ./pve-guest-audit.sh          # flag snapshots older than 14 days
sudo ./pve-guest-audit.sh -s 30    # flag snapshots older than 30 days
```

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Clean run, no issues |
| 1 | Warnings |
| 3 | Could not run (not root, not a PVE host, bad arguments) |

There's no `2`: unlike the health checkers, nothing here is an outage, so nothing is CRITICAL.

## Notes

- Read-only: it reads guest configs and queries `qm`, `pct` and `pvesh`. It never unlocks, deletes or changes a guest. The suggested commands are for you to run after checking.
- Covers the guests on the node it runs on. In a cluster, run it on each node. The unreferenced-volume check compares against every config in the cluster, so a volume belonging to a guest on another node isn't flagged.
- If a shared storage is also used by **another** cluster or standalone host, that host's volumes will show as belonging to guests that don't exist. Check before freeing anything.
- The guest agent check pings each running VM that has the agent enabled, with a 15-second timeout, so a node with many broken agents takes a little longer.
