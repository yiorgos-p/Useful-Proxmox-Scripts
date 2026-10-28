# Useful Proxmox Scripts

[![ShellCheck](https://github.com/yiorgos-p/Useful-Proxmox-Scripts/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/yiorgos-p/Useful-Proxmox-Scripts/actions/workflows/shellcheck.yml)

Read-only health-check scripts for Proxmox VE hosts. They inspect hardware, storage, memory, guests, the cluster and configuration, print a colored report with a summary table, and **never change anything**, so they're safe to run on a production node at any time. The one exception is the ZFS disk replacement helper, which only changes anything with `--apply` and asks first.

## Scripts

| Script | What it checks |
|---|---|
| [**pve-drive-health-check**](pve-drive-health-check/) | RAID controller, ZFS pools, SMART, live IO load, VM disk cache/discard settings |
| [**pve-hardware-health-check**](pve-hardware-health-check/) | ECC memory, temperatures, kernel hardware errors, NIC and bridge uplinks, PVE services and failed tasks, IPMI sensors and event log |
| [**pve-cluster-health**](pve-cluster-health/) | Quorum, corosync link redundancy and packet loss, HA states, replication, time sync and skew, Ceph, certificate expiry |
| [**pve-memory-check**](pve-memory-check/) | ZFS ARC size and limits vs guest RAM, ignored or inactive zfs_arc_max, swap per VM/CT, active swapping, swap on zvol |
| [**pve-check-all**](pve-check-all/) | Runs all the checks above, prints one combined summary, saves reports, emails when something needs attention; cron-friendly |
| [**pve-zfs-replace-disk**](pve-zfs-replace-disk/) | Not a check: works out how to replace a failed ZFS disk (pool, new disk, partition layout, boot setup) and prints the plan; runs it with `--apply` |
| [**pve-guest-audit**](pve-guest-audit/) | Old snapshots, stale locks, dead guest agents, start-on-boot vs HA, cpu=host on mixed clusters, detached and orphaned disks |

Each folder has the script and a README with full details.

## Quick start

Run on the Proxmox host as root:

```bash
wget https://raw.githubusercontent.com/yiorgos-p/Useful-Proxmox-Scripts/main/pve-hardware-health-check/pve-hardware-health-check.sh
chmod +x pve-hardware-health-check.sh
./pve-hardware-health-check.sh
```

Swap in the name of any other script for its checks. As with any script from the internet, read it before running it as root.

## Common behavior

- **Read-only**: queries tools, sysfs, logs and configs; writes nothing (except `pve-zfs-replace-disk --apply`).
- **Skips what isn't there**: no RAID controller, no ZFS, no BMC or not a PVE host means that section is skipped instead of erroring.
- **Monitoring-friendly exit codes**: `0` clean, `1` warnings, `2` critical (the guest audit only uses `0` and `1`). Easy to wire into cron, Nagios/Zabbix or a Prometheus textfile collector.

## License

MIT, see [LICENSE](LICENSE).
