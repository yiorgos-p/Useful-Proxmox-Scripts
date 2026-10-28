# PVE ZFS Disk Replacement Helper

Replaces a failed disk in a ZFS pool on Proxmox VE. Swap the disk, run the script, and it works out the rest: which pool and device failed, which disk is the new one, whether the partition layout needs copying, and how to make the new disk bootable.

By default it **only prints the plan** and changes nothing. With `--apply` it shows the same plan, asks you to type the new disk's name, then runs every step.

> This is the one script in the repo that can change your system, and only with `--apply`. Read the plan before confirming. It erases the new disk.

## What it works out

- **The failed device**: the pool that's degraded, and the device in it that's `FAULTED`, `UNAVAIL`, `REMOVED` or `OFFLINE`. It refuses if the vdev has no healthy member left to rebuild from, and stops if a replacement is already in progress.
- **The new disk**: the one disk that is blank, not in any pool, not mounted, not used by LVM/mdraid/device-mapper, and at least as big as the healthy disk. If there's more than one, or the new disk has old partitions on it, you name it with `-n` and the same checks still apply (old contents get wiped).
- **The layout**:
  - *Partitioned* (the PVE installer's `rpool`: BIOS boot, ESP, ZFS): the partition table is copied from a healthy disk in the same vdev, and ZFS goes on the same partition number.
  - *Whole disk* (typical data pools): ZFS partitions the new disk itself.
- **Boot setup**, only when the pool holds the root filesystem:
  - `proxmox-boot-tool format` + `init` on the new disk's ESP, in UEFI or legacy GRUB mode, then `clean` to drop the dead disk's entry
  - `grub-install` for older installs that don't use proxmox-boot-tool

## The plan

For a partitioned root pool it looks like this (from a test run):

```
  1. Wipe old partition tables and signatures from the new disk
       sgdisk --zap-all /dev/disk/by-id/ata-NEW_S2
  2. Copy the partition layout from the healthy disk
       sgdisk /dev/disk/by-id/ata-HEALTHY_S1 -R /dev/disk/by-id/ata-NEW_S2
  3. Give the copied partitions new unique GUIDs
       sgdisk -G /dev/disk/by-id/ata-NEW_S2
  4. Wait for the new partitions to show up
       udevadm settle; wait_for /dev/disk/by-id/ata-NEW_S2-part3
  5. Replace the failed device; the resilver starts
       zpool replace -f rpool 2397207169620814812 /dev/disk/by-id/ata-NEW_S2-part3
  6. Format the new disk's ESP
       proxmox-boot-tool format /dev/disk/by-id/ata-NEW_S2-part2 --force
  7. Install the bootloader on it and register it
       proxmox-boot-tool init /dev/disk/by-id/ata-NEW_S2-part2 grub
  8. Drop the dead disk's ESP from the boot list
       proxmox-boot-tool clean
```

For a whole-disk pool it's just steps 1 and 5.

It follows the procedure from the Proxmox docs ([Changing a failed bootable device](https://pve.proxmox.com/pve-docs/chapter-sysadmin.html#_zfs_administration)). Note that `proxmox-boot-tool reinit` on its own isn't enough: it only refreshes ESPs that are already registered, and the new disk's ESP is neither formatted nor registered yet. That's what `format` and `init` are for.

## Usage

```bash
sudo ./pve-zfs-replace-disk.sh            # show the plan
sudo ./pve-zfs-replace-disk.sh --apply    # show the plan, confirm, run it
```

When it can't decide on its own, it lists the choices and tells you which option to add:

| Option | Use |
| --- | --- |
| `-p POOL` | More than one pool has a failed device |
| `-o OLD` | More than one failed device; use the name or GUID that `zpool status` shows |
| `-n NEW` | More than one blank disk, or the new disk isn't blank. Example: `-n /dev/disk/by-id/ata-...` |

After `--apply`, the resilver runs in the background. Follow it with `watch -n 10 zpool status <pool>`.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Plan printed, or applied successfully |
| 1 | Nothing to replace |
| 2 | Refused (a safety check failed, or it needs `-p`/`-o`/`-n`) or a step failed |
| 3 | Could not run (not root, no ZFS, bad arguments) |

## Notes

- If a step fails, it stops there and prints the remaining commands, so you can finish by hand once the cause is fixed.
- The confirmation is read from the terminal, so it can't be piped in or scripted. That's deliberate.
- The failed disk can still be attached (for example, the new disk went into a spare slot). The script says so, and you can pull the old one after the resilver.
- Requirements: root, `zfsutils-linux`, `gdisk` (for `sgdisk`) and `util-linux`, all on a stock PVE install.
- Tested against real `sgdisk` on loop devices with the PVE installer's partition layout. `zpool` and `proxmox-boot-tool` were stubbed, so try the plan mode on your hardware first.
