# PVE Cluster Health Checker

A read-only bash script that checks what holds a Proxmox VE cluster together: quorum, corosync links, HA, storage replication, time sync, Ceph and certificates. It prints a colored report and a summary table, and makes no changes.

The point is to catch problems that are invisible until they turn into an outage. A redundant corosync link that died weeks ago, a clock that drifted, or a certificate whose auto-renewal stopped working all look fine in the web UI until the day they aren't.

## What it checks

1. **Membership**: quorum, offline nodes, two-node clusters without a QDevice (where losing either node loses quorum), and PVE version mismatches between nodes.
2. **Corosync**: the status of every link to every node, from `corosync-cfgtool -s`. If one of two links is down, the cluster keeps running and nothing alerts, but you're one failure away from nodes dropping out. Also counts token timeouts, retransmits and link-down events in the corosync log for the `-d` window, which point at a congested or flaky cluster network.
3. **HA**: HA quorum, the active master, LRM state on each node, resources in `error` / `fence` / `recovery`, and nodes left in maintenance mode.
4. **Replication**: failing storage replication jobs on any node, with the error message.
5. **Time**: chrony sync status and offset on this node, clock skew between nodes, and nodes in different timezones.
6. **Ceph** (if configured): `ceph health detail` and raw usage. Warns above 75%, since recovering from a lost node needs free space.
7. **Certificates**: expiry of the cluster CA and every node's `pve-ssl.pem` / `pveproxy-ssl.pem`. PVE and ACME renew these automatically, so anything expiring within 14 days means renewal has stopped.

On a standalone node, sections 1–4 are skipped and time, Ceph and certificates still run.

## Example output

From a test cluster (summary section):

```
  Check                               | Status
  ----------------------------------- | ----------------------------
  CEPH_HEALTH                         | HEALTH_WARN
  CERTIFICATES                        | EXPIRED: 0, EXPIRING: 1
  CLUSTER_NODES                       | OFFLINE: pve3
  CLUSTER_QUORUM                      | OK
  COROSYNC_LINKS                      | DEGRADED
  COROSYNC_LOG                        | TOKENS: 4 RETRANS: 1
  HA_RESOURCES                        | CRITICAL: 1 error, 1 fencing
  REPLICATION                         | FAILING: 1 of 2
  TIME_SKEW                           | SKEW: pve2(6s)
  TIME_SYNC                           | OK

  Issues requiring attention (12):
    → Node(s) offline: pve3
    → Corosync redundancy lost — link down to: pve2 (link 1). The cluster runs on the remaining link; one more failure and those nodes drop out
    → CRITICAL: HA resource(s) in error state: vm:101 — HA has stopped managing them. ...
    → Certificate(s) expiring within 14 days: pve2/pve-ssl.pem (5d) — automatic renewal isn't working; ...
    ...
```

## Requirements

- Root privileges, on a Proxmox VE node
- `python3` (included with PVE), used to parse `pvesh` JSON output

## Usage

```bash
sudo ./pve-cluster-health.sh         # corosync log: last 7 days
sudo ./pve-cluster-health.sh -d 30   # corosync log: last 30 days
```

Running it on one node is enough for the cluster-wide checks (membership, HA, replication, skew, certificates). The corosync link status is from the point of view of the node it runs on, so to check every link, run it on each node.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Clean run, no issues |
| 1 | Warnings only |
| 2 | At least one CRITICAL finding (no quorum, HA resources in error or being fenced, Ceph HEALTH_ERR, expired certificates) |
| 3 | Could not run (not root, not a PVE host, bad arguments) |

## Notes

- Read-only: it only runs status commands (`pvecm`, `corosync-cfgtool -s`, `ha-manager status`, `pvesh get`, `chronyc tracking`, `ceph health`, `openssl x509`). It never changes cluster, HA, Ceph or certificate config.
- Corosync log thresholds (3+ token timeouts or 100+ retransmit lines in the window) leave room for the events a planned node reboot causes.
- Clock skew between nodes is measured over the API, so only skew of 3 seconds or more is reported. The chrony offset on the local node is far more precise.
