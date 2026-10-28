# Useful Proxmox Scripts

[![ShellCheck](https://github.com/yiorgos-p/Useful-Proxmox-Scripts/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/yiorgos-p/Useful-Proxmox-Scripts/actions/workflows/shellcheck.yml)

Read-only health-check scripts for Proxmox VE hosts. They inspect hardware, storage and configuration, print a colored report with a summary table, and **never change anything**, so they're safe to run on a production node at any time.

## Scripts

| Script | What it checks |
|---|---|
| [**pve-drive-health-check**](pve-drive-health-check/) | RAID controller, ZFS pools, SMART, live IO load, VM disk cache/discard settings |
| [**pve-hardware-health-check**](pve-hardware-health-check/) | ECC memory, temperatures, kernel hardware errors, NIC and bridge uplinks, PVE services and failed tasks, IPMI sensors and event log |

Each folder has the script and a README with full details.

## Quick start

Run on the Proxmox host as root:

```bash
wget https://raw.githubusercontent.com/yiorgos-p/Useful-Proxmox-Scripts/main/pve-hardware-health-check/pve-hardware-health-check.sh
chmod +x pve-hardware-health-check.sh
./pve-hardware-health-check.sh
```

Swap in `pve-drive-health-check` for the storage checks. As with any script from the internet, read it before running it as root.

## Common behavior

- **Read-only**: queries tools, sysfs, logs and configs; writes nothing.
- **Skips what isn't there**: no RAID controller, no ZFS, no BMC or not a PVE host means that section is skipped instead of erroring.
- **Monitoring-friendly exit codes**: `0` clean, `1` warnings, `2` critical. Easy to wire into cron, Nagios/Zabbix or a Prometheus textfile collector.

## License

MIT, see [LICENSE](LICENSE).
