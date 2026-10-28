# PVE Check-All

Runs every health check in this repo on a Proxmox VE node and prints one combined summary: each check's status and the issues it found. It can save the full reports and email the summary when something needs attention, which makes it easy to run from cron.

It runs, in order: [hardware](../pve-hardware-health-check/), [drive](../pve-drive-health-check/), [memory](../pve-memory-check/), [cluster health](../pve-cluster-health/) and the [guest audit](../pve-guest-audit/). Like them, it's read-only. The [ZFS disk replacement helper](../pve-zfs-replace-disk/) isn't a check and is never run.

## Example output

```
  pve-hardware-health-check    CRITICAL
      - eno3: link down
      - CRITICAL: PVE service(s) not running: pvestatd
  pve-drive-health-check       OK
  pve-memory-check             WARN
      - Swap 88% full — when it runs out, the OOM killer starts
  pve-cluster-health           OK
  pve-guest-audit              WARN
      - 3 snapshot(s) older than 14 days on: VM101 VM104
```

## Setup

The wrapper looks for the other scripts next to itself and in the repo layout, so the simplest setup is a clone:

```bash
git clone https://github.com/yiorgos-p/Useful-Proxmox-Scripts /root/Useful-Proxmox-Scripts
/root/Useful-Proxmox-Scripts/pve-check-all/pve-check-all.sh
```

Update later with `git -C /root/Useful-Proxmox-Scripts pull`.

## Usage

```bash
./pve-check-all.sh                          # run everything, show the summary
./pve-check-all.sh -o /var/log/pve-checks   # also keep each full report
./pve-check-all.sh -m root                  # email the summary if there are issues
./pve-check-all.sh -q                       # summary only, for cron
```

A daily cron job (`crontab -e` as root) that keeps the reports and mails root only when something's wrong:

```
0 7 * * * /root/Useful-Proxmox-Scripts/pve-check-all/pve-check-all.sh -q -o /var/log/pve-checks -m root > /dev/null
```

PVE's postfix delivers root's mail to the address set for root@pam (Datacenter → Permissions → Users), so `-m root` works on a default install as long as outbound mail does.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Every check clean |
| 1 | Warnings, or a check couldn't run or wasn't found |
| 2 | At least one CRITICAL finding |
| 3 | Could not run (not root, bad arguments) |

## Notes

- The run takes around 15 seconds: the drive and memory checks each sample IO or swap activity for a few seconds.
- Saved reports are plain text (colors stripped), named `<host>-<date>-<check>.log`. Clean up old ones yourself, e.g. with `find /var/log/pve-checks -mtime +30 -delete` in the same cron job.
- Each check runs with its default options. Run a check directly for its options, such as a longer log window.
