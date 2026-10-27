# PVE Hardware Health Checker

A read-only bash script that checks the non-storage hardware health of a Proxmox VE host: ECC memory, temperatures, kernel-logged hardware errors, network links and bridges, Proxmox services, and the IPMI/BMC event log. Prints a colored terminal report and a summary table; makes no changes to your system.

It's the companion to [pve-drive-health-check.sh](pve-drive-health-check.md), which covers RAID, ZFS, SMART and IO. Run both after a hardware replacement or an incident.

What it checks

1.  ECC memory / machine checks — EDAC corrected/uncorrected counters (per DIMM where the driver exposes it), rasdaemon history if installed, and MCE/EDAC lines in the kernel log. Warns if the board has ECC but no EDAC driver is loaded, since errors are then corrected silently with nobody counting.
2.  Temperatures — read directly from hwmon sysfs (lm-sensors not required). Uses each sensor's own limits where it publishes them, with sane defaults for AMD, Intel, NVMe and SATA drives. Flags a CCD temperature spread over 20°C on Ryzen/EPYC (cooler contact / paste) and thermal throttling events.
3.  Kernel log — PCIe AER errors (with the offending device named via lspci), OOM kills mapped to the VM or container ID that was killed, block I/O errors, lockups/oopses/panics, and how many times the host booted in the window.
4.  Network — physical NIC link state, negotiated speed, duplex and error counters; every `bridge-ports` entry in `/etc/network/interfaces` checked against the real interfaces (catches the classic "NIC renamed after a hardware swap, vmbr0 has no uplink" failure); bond slave state.
5.  Proxmox — core PVE services, failed systemd units, cluster quorum (if clustered), failed tasks in the window (backups called out), and running guests that won't start on boot.
6.  IPMI / BMC — sensor threshold status and System Event Log entries from the window (PSU, fan, voltage, ECC events the OS may never see). Works with iDRAC/iLO/Supermicro BMCs through ipmitool.

Storage (ZFS pool state, SMART) is deliberately left to the drive health checker.

Requirements

-   Root privileges
-   bash 4+, dmidecode, pciutils — all present on a stock PVE install
-   ipmitool (for section 6 — skipped if missing, or if there's no local BMC interface)
-   rasdaemon (optional — adds ECC error history that survives reboots)
-   A persistent journal (`/var/log/journal`) to see errors from before the last reboot; without it only the current boot is covered

Usage

```bash
sudo ./pve-hardware-health-check.sh            # look back 7 days
sudo ./pve-hardware-health-check.sh -d 2       # look back 2 days
```

`-d DAYS` sets how far back the kernel log, task log and BMC event log are searched (default 7).

Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Clean run, no issues |
| 1 | Warnings only |
| 2 | At least one CRITICAL finding |
| 3 | Could not run (not root, bad arguments) |

Useful for wiring into cron, Nagios/Zabbix, or a Prometheus textfile collector.

Notes

-   Read-only — it only reads sysfs, logs and configs, and queries tools; it never writes to hardware, network config, guests or the BMC (it does not clear the SEL).
-   EDAC counters and NIC error counters are since boot; log-based checks cover the `-d` window.
-   The BMC event log is never cleared automatically, so only entries inside the window are scored. Review older entries yourself and clear with `ipmitool sel clear` once dealt with.
-   A NIC counts as "in use" if its name appears anywhere in `/etc/network/interfaces`. Unused ports that are down are listed but not flagged.
-   Inside a VM most sections have nothing to check and say so.
