# PVE Drive Health Checker

A read-only bash script that checks drive and storage health on a Proxmox VE host: RAID controller status, SMART health, live IO load, and VM disk config sanity. Prints a colored terminal report and a summary table; makes no changes to your system.

What it checks

1.  RAID controller (if storcli/perccli/MegaCli is found) — virtual drive state, battery backup/CacheVault status, per-physical-drive media errors, shield counter, temperature.
2.  ZFS pools (if any are imported) — pool state, worst READ/WRITE/CKSUM error seen on any device, scrub/resilver status, capacity and fragmentation.
3.  SMART health for any drive not fully hidden behind a RAID controller — reallocated/pending sectors, NVMe spare capacity, power-on hours, error log.
4.  Live IO stats — 3 samples of iostat -x, 2 seconds apart, flags devices running hot on utilization or await time.
5.  VM disk config audit — scans /etc/pve/qemu-server/.conf for risky combinations like cache=writeback on ZFS or discard=on without iothread=1.

Requirements

-   Root privileges
-   zfsutils-linux (for section 2 — skipped entirely if no zpool binary or no imported pools are found)
-   smartmontools (for section 3)
-   sysstat (for section 4 — script warns and skips this section if missing)
-   storcli64 / storcli / perccli64 / perccli / MegaCli64 (for section 1 — script skips RAID checks entirely if none is found, e.g. on a plain JBOD/NVMe box)

Usage

bash
sudo ./pve-drive-health-check.sh

Redirect to a file if you want a log:

bash
sudo ./pve-drive-health-check.sh > /var/log/drive-health-$(date +%F).log

Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Clean run, no issues |
| 1 | Warnings only |
| 2 | At least one CRITICAL finding |

Useful for wiring into cron, Nagios/Zabbix, or a Prometheus textfile collector.

Notes

-   Read-only — it only queries drives/controllers/configs, never writes to them.
-   The RAID section parses storcli/perccli text output, which can vary slightly by tool version and controller generation. If something looks off on your hardware, run the underlying storcli64 /call show all and /call/eall/sall show all commands manually and compare.
-   On multi-controller hosts, per-drive state lookup assumes enclosure/slot IDs don't collide across controllers (true for most setups).
