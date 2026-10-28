# PVE Drive Health Checker

A read-only bash script that checks drive and storage health on a Proxmox VE host: RAID controller status, ZFS pool health, SMART health, live IO load, and VM disk config sanity. Prints a colored terminal report and a summary table, and makes no changes to your system.

## What it checks

1. **RAID controller** (if storcli/perccli/MegaCli is found): virtual drive state, battery backup/CacheVault status, and per-drive media errors, shield counter and temperature.
2. **ZFS pools** (if any are imported): pool state, the worst READ/WRITE/CKSUM error seen on any device, scrub/resilver status, capacity and fragmentation.
3. **SMART health** for any drive not fully hidden behind a RAID controller: reallocated/pending sectors, NVMe spare capacity, power-on hours, error log. Devices without SMART (USB sticks, SD-card modules) are noted and skipped. RAID virtual disks (PERC, MegaRAID, Smart Array) are left to the RAID section; without storcli/perccli installed you get one warning that the array isn't being checked.
4. **Live IO stats**: 3 samples of `iostat -x`, 2 seconds apart, flagging devices running hot on utilization or await time. Skipped if sysstat isn't installed.
5. **VM disk config audit**: scans `/etc/pve/qemu-server/*.conf` for risky combinations like `cache=writeback` on ZFS or `discard=on` without `iothread=1`.

## Example output

Excerpt from a real run on a ZFS host (serial numbers masked):

```
╔══════════════════════════════════════════════════════╗
║  ZFS POOL HEALTH
╔══════════════════════════════════════════════════════╗
  Pools found: zfsDatastore_1

  [OK]  zpool status -x → all pools healthy

  Pool: zfsDatastore_1
  ──────────────────────────────────────────────────
    State: ONLINE
  [OK]  zfsDatastore_1 → ONLINE
    Worst READ/WRITE/CKSUM on any device: 0 / 0 / 0
    Scan  : scrub repaired 0B in 00:57:44 with 0 errors on Sun Oct 11 01:21:47 2026
    Capacity: 6%  |  Fragmentation: 57%
╔══════════════════════════════════════════════════════╗
║  DIRECT DRIVE HEALTH (SMART)
╔══════════════════════════════════════════════════════╗

  /dev/sdc
  ──────────────────────────────────────────────────
    Model : VK007680GXAWQ
    Serial: XXXXXXXXXXXX
    Health: SMART overall-health self-assessment test result: PASSED
  [OK]  /dev/sdc → PASSED

    Key Attributes:
        5 Reallocated_Sector_Ct   0x0033   100   100   010    Pre-fail  Always       -       37
        9 Power_On_Hours          0x0032   100   100   000    Old_age   Always       -       37750
      194 Temperature_Celsius     0x0022   075   059   000    Old_age   Always       -       25 (Min/Max 20/41)
      197 Current_Pending_Sector  0x0012   100   100   000    Old_age   Always       -       0
  [WARN] /dev/sdc has 37 reallocated sectors
      → Power-on: 37750h (4.3 years)
```

## Requirements

- Root privileges
- `zfsutils-linux` for section 2 (skipped if there's no `zpool` binary or no imported pools)
- `smartmontools` for section 3
- `sysstat` for section 4 (warns and skips if missing)
- `storcli64` / `storcli` / `perccli64` / `perccli` / `MegaCli64` for section 1 (skipped if none is found, e.g. on a plain JBOD/NVMe box)

## Usage

```bash
sudo ./pve-drive-health-check.sh
```

Save the report to a log file:

```bash
sudo ./pve-drive-health-check.sh > /var/log/drive-health-$(date +%F).log
```

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Clean run, no issues |
| 1 | Warnings only |
| 2 | At least one CRITICAL finding |

Useful for wiring into cron, Nagios/Zabbix, or a Prometheus textfile collector.

## Notes

- Read-only: it only queries drives, controllers and configs, and never writes to them.
- The RAID section parses storcli/perccli text output, which can vary slightly by tool version and controller generation. If something looks off on your hardware, run `storcli64 /call show all` and `storcli64 /call/eall/sall show all` manually and compare.
- On multi-controller hosts, the per-drive state lookup assumes enclosure/slot IDs don't collide across controllers (true for most setups).
