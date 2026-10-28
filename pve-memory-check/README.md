# PVE Memory Checker

A read-only bash script that shows where a Proxmox VE host's RAM and swap are going: how much the ZFS ARC is taking and whether its limit is really in effect, how much of each VM and container is sitting in swap, and whether the host is swapping right now. It prints a colored report and a summary table, and makes no changes.

## What it checks

1. **Host memory**: available RAM, counting what the ARC can give back (the kernel's own "available" figure treats the ARC as used, so ZFS hosts always look fuller than they are). KSM savings, and the RAM assigned to running guests compared with physical RAM.
2. **ZFS ARC** (if ZFS is loaded):
   - Current size, target, min, max and hit ratio.
   - **ARC + guests vs RAM**: whether ARC max plus the RAM of running guests plus 2 GiB for the host fits in physical RAM. The ARC shrinks under pressure, but not instantly, so a guest that suddenly needs its memory can get the host OOM-killing before the ARC lets go. Suggests a `zfs_arc_max` that would fit.
   - **Limit ignored**: `zfs_arc_max` set but not in effect. OpenZFS silently ignores a value below `zfs_arc_min` (by default 1/32 of RAM), so setting a small limit on a big host does nothing.
   - **Limit not active**: a value in `/etc/modprobe.d` that differs from the running one. With root on ZFS, the module loads from the initramfs, so the change needs `update-initramfs -u -k all` and a reboot.
3. **Swap**:
   - Usage and swappiness, with a warning above 80% full.
   - **Swapping right now**: samples `/proc/vmstat` for a few seconds. Swap that's merely in use is usually idle pages and harmless; pages being read back in mean something is waiting on disk.
   - **Swap on a ZFS zvol**: known to be able to hang the host under memory pressure.
   - **Swap per VM/CT**: from each guest's cgroup, with assigned and resident memory alongside, plus the host processes using the most swap.

## Example output

From a test host (swap section and summary):

```
  Swap: 7.0 GiB of 8.0 GiB used (88%) | swappiness: 20
  [WARN] Swap 88% full — when it runs out, the OOM killer starts
  [WARN] Swap on a ZFS zvol (/dev/zd0) — can deadlock the host under memory pressure; use a plain partition, or no swap
  Swap activity over 5s: 0 pages/s in, 0 pages/s out
  [OK]  No heavy swapping right now

  --- Swap per guest ---
  VMID    TYPE NAME                     ASSIGNED     IN RAM       SWAP
  101     VM  big                      24.0 GiB   20.0 GiB    3.0 GiB
  200     CT  web                       4.0 GiB    3.0 GiB    512 MiB
  Guests total: 3.5 GiB of 7.0 GiB swap used

  Check                               | Status
  ----------------------------------- | ----------------------------
  ARC_LIMIT                           | NOT ACTIVE
  ARC_VS_GUESTS                       | TOO BIG: 109% of RAM
  MEM_AVAILABLE                       | OK (41%)
  MEM_OVERCOMMIT                      | OK (56%)
  SWAP_ACTIVITY                       | OK
  SWAP_GUESTS                         | INFO: 3.5 GiB
  SWAP_USAGE                          | FULL: 88%
  SWAP_ZVOL                           | SWAP ON ZVOL
```

## Requirements

- Root privileges
- cgroup v2 (PVE 7 and later) for exact per-guest numbers. On older hosts it adds up per-process `VmSwap` instead.

## Usage

```bash
sudo ./pve-memory-check.sh          # sample swap activity for 5 seconds
sudo ./pve-memory-check.sh -i 30    # sample for 30 seconds
```

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Clean run, no issues |
| 1 | Warnings only |
| 2 | At least one CRITICAL finding (under 5% of RAM available, ARC included) |
| 3 | Could not run (not root, bad arguments) |

## Notes

- Read-only: it reads `/proc`, sysfs, cgroup files and guest configs. It never changes ARC limits, swappiness or guest memory.
- Guest RAM is the configured (maximum) memory of running guests, so ballooning VMs count at their maximum. That's deliberate: it's what they can grow to.
- OOM kills from the past are covered by the [hardware health checker](../pve-hardware-health-check/)'s kernel log section, which names the VM or container that was killed.
