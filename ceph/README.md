# Ceph cluster

3-node Ceph cluster deployed with **cephadm**, the storage backend for Glance,
Cinder and Nova. The step-by-step commands are in
[ceph-setup.sh](ceph-setup.sh), a runbook you copy one step at a time (running
the whole file exits right away).

| Host   | Storage IP (③) | Daemons             | OSD disks                   |
|--------|----------------|---------------------|-----------------------------|
| ceph01 | 10.0.2.50      | mon · mgr · osd     | `/dev/nvme1n1`, `/dev/nvme2n1` |
| ceph02 | 10.0.2.60      | mon · mgr · osd     | `/dev/nvme1n1`, `/dev/nvme2n1` |
| ceph03 | 10.0.2.70      | mon · osd           | `/dev/nvme1n1`, `/dev/nvme2n1` |

- **Release:** squid (19.2), from download.ceph.com (`ceph_release` in
  [ceph-prereqs](../playbooks/roles/ceph_prereqs/defaults/main.yml)).
- **Networks:** public and cluster traffic both on the storage network
  `10.0.2.0/24` (`--mon-ip 10.0.2.50 --cluster-network 10.0.2.0/24`).
- **Dashboard:** `https://ceph01:8443`, user `admin`, password
  `opensesame!@#` (lab only).
- **Admin node:** ceph01 holds `/etc/ceph/ceph.conf` and the admin keyring, so
  `ceph` / `rbd` work there as root without `cephadm shell`.

## Steps

Prerequisites and SSH keys are Ansible playbooks run from the deploy VM
(`~/openstack-homelab`, venv active); the rest runs as root on ceph01.

| # | Where | What | How |
|---|-------|------|-----|
| 0 | deploy VM | Upgrade, Docker, Ceph repo, `cephadm` + `ceph-common` on all 3 nodes | `ansible-playbook playbooks/ceph-prereqs.yml -K` |
| 1 | ceph01 | `cephadm bootstrap`: first MON + MGR, dashboard | runbook step 1 |
| 2 | deploy VM | cephadm's SSH key for root on every Ceph node, then `ceph cephadm check-host` for each | `ansible-playbook playbooks/ceph-ssh.yml -K` |
| 3 | ceph01 | `ceph orch host add` ceph02/ceph03; 3 MONs, 2 MGRs | runbook step 3 |
| 4 | ceph01 | OSDs on the NVMe disks | runbook step 4 |
| 5 | ceph01 | `images` / `volumes` / `vms` RBD pools, size 3 / min_size 2 | runbook step 5 |
| 6 | ceph01 | `client.glance` and `client.cinder` users + keyrings | runbook step 6 |
| 7 | ceph01 | Minimal `ceph.conf` for Kolla | runbook step 7 |

Notes on the steps:

- **Step 0.** `systemd-timesyncd` is not installed: it conflicts with chrony,
  which keeps the nodes within Ceph's clock-skew limit (`preconfig.yml --tags ntp`).
- **Step 2.** cephadm drives every host over SSH as root. Root has no password
  on Ubuntu, so `ssh-copy-id root@ceph02` from ceph01 can't log in; the
  playbook installs the key through the `opadm` account instead and allows
  root to log in **with a key only** (`PermitRootLogin prohibit-password`).
  Tags: `sshd`, `authkey`, `check`.
- **Step 4.** Use one option: `--all-available-devices` (every empty disk,
  including disks added later) or explicit `ceph orch daemon add osd` per
  disk. A disk is only usable when `ceph orch device ls` shows it available
  (no partitions, no LVM, no filesystem).
- **Step 5.** 3 replicas, one per node: I/O continues with one node down
  (`min_size 2`). The PG autoscaler resizes the initial 32 PGs.
- **Step 6.** Nova reuses `client.cinder` (it needs `vms` and read access to
  `images` for copy-on-write clones), so there is no separate Nova user.

## Health checks

```bash
ceph -s                       # HEALTH_OK, 3 mons in quorum, 6 OSDs up/in
ceph orch host ls
ceph orch ps                  # every daemon running
ceph osd tree
ceph df
ceph osd pool autoscale-status
```

## Next: hand the cluster to Kolla-Ansible

Copy from ceph01 to the deploy VM, into Kolla's config overrides:

| File on ceph01 | Under `/etc/kolla/config/` on the deploy VM |
|----------------|---------------------------------------------|
| `/tmp/ceph.conf` | `glance/`, `cinder/`, `nova/` (as `ceph.conf`) |
| `/etc/ceph/ceph.client.glance.keyring` | `glance/` |
| `/etc/ceph/ceph.client.cinder.keyring` | `cinder/cinder-volume/`, `nova/` |

Then enable the Ceph backends in `globals.yml` (`glance_backend_ceph`,
`cinder_backend_ceph`, `nova_backend_ceph`). Check the exact paths against the
[Kolla-Ansible external Ceph guide](https://docs.openstack.org/kolla-ansible/latest/reference/storage/external-ceph-guide.html)
for the release in use.
