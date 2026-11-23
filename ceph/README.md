# Ceph cluster

3-node Ceph cluster deployed with **cephadm**, the storage backend for Glance,
Cinder and Nova. It is built and kept in shape by Ansible playbooks run from
the deploy VM. [ceph-setup.sh](ceph-setup.sh) holds the equivalent manual
commands, for reference only.

| Host   | Storage IP (③) | Labels            | Daemons         | OSD disks                            |
|--------|----------------|-------------------|-----------------|--------------------------------------|
| ceph01 | 10.0.2.50      | `_admin` `mon` `mgr` | mon · mgr · osd | `/dev/sdb`, `/dev/sdc` (100 GB each) |
| ceph02 | 10.0.2.60      | `_admin` `mon` `mgr` | mon · mgr · osd | `/dev/sdb`, `/dev/sdc` (100 GB each) |
| ceph03 | 10.0.2.70      | `mon`             | mon · osd       | `/dev/sdb`, `/dev/sdc` (100 GB each) |

- **Release:** squid (19.2), from download.ceph.com (`ceph_release` in
  [ceph-prereqs](../playbooks/roles/ceph_prereqs/defaults/main.yml)).
- **Networks:** public and cluster traffic both on the storage network
  `10.0.2.0/24` (bootstrap with `--mon-ip 10.0.2.50 --cluster-network 10.0.2.0/24`).
- **Dashboard:** `https://ceph01:8443`, user `admin`, password set at
  bootstrap.
- **Admin nodes:** ceph01 and ceph02 (label `_admin`). cephadm keeps
  `/etc/ceph/ceph.conf` and the admin keyring on both, so `ceph` / `rbd` work
  there as root without `cephadm shell`. The playbooks run `ceph` commands on
  `ceph_admin_host` (ceph01).
- **Source of truth:** hosts, storage IPs and labels in
  `inventory/hosts.yml` (`ceph_nodes`, `ceph_labels`); OSD policy, pools,
  users and Kolla keyrings in `inventory/group_vars/ceph_nodes.yml`.

## Build

From the repo root on the deploy VM, after `preconfig.yml`
(`source ~/venv/bin/activate`):

```bash
ansible-playbook playbooks/ceph-prereqs.yml -K                    # packages on all 3 nodes
ansible-playbook playbooks/ceph-cluster.yml -e ceph_dashboard_password='<dashboard-password>'
ansible-playbook playbooks/health.yml --tags ceph
```

Without `ceph_dashboard_password`, cephadm generates a password, the playbook
prints it, and the dashboard asks for a new one at first login. Never commit
the password.

| `ceph-prereqs.yml` tag | What it does |
|-----------|--------------|
| `upgrade` | `apt update` + `apt upgrade` |
| `docker`  | `docker.io` (cephadm's container runtime), enabled and started |
| `cephadm` | download.ceph.com repo for `ceph_release` (default `squid`; `-e ceph_release=tentacle` or `reef`) + `cephadm` and `ceph-common` |
| `reboot`  | Reboots only nodes with `/var/run/reboot-required`, one at a time |

| `ceph-cluster.yml` tag | Runbook step | What it does |
|------------------------|--------------|--------------|
| `bootstrap` | 1 | `cephadm bootstrap` on ceph01: first MON + MGR, dashboard. Skipped when `/etc/ceph/ceph.conf` and the admin keyring exist, so re-runs on the live cluster are safe |
| `sshd`, `authkey`, `check` | 2 | [ceph-ssh.yml](../playbooks/ceph-ssh.yml): cephadm's SSH key for root on every Ceph node, then `ceph cephadm check-host` for each |
| `specs` | 3-4 | Renders `/etc/ceph/cluster-spec.yml` from the inventory: one host entry per node (storage IP, labels), MONs on the `mon` hosts, MGRs on the `mgr` hosts, OSDs on every empty disk (`all-available-devices`). When it changed: saves `ceph orch ls --export` to `/root/ceph-backups/`, prints `ceph orch apply --dry-run`, then applies. Waits for `ceph_osd_expected` OSDs. `-e ceph_spec_force=true` re-applies an unchanged file |
| `pools`, `users`, `clients` | 5-7 | [ceph-pools.yml](../playbooks/ceph-pools.yml), below |

| `ceph-pools.yml` tag | What it does |
|----------------------|--------------|
| `pools` | Creates missing pools from `ceph_pools` (`images`, `volumes`, `vms`), sets size / min_size / application when they differ, `rbd pool init` on new pools only |
| `users` | Creates missing users from `ceph_clients` (`client.glance`, `client.cinder`), updates caps that differ |
| `clients` | Writes the users' keyrings to `/etc/kolla/config/` on the deploy VM (mode 0600; skipped while `/etc/kolla` does not exist). Fails if the repo's `kolla/config/ceph.conf` does not match the cluster, printing the lines to commit |

Every playbook previews with `--check --diff`, never deletes a pool, a user or
a host, and needs no `-K` except `ceph-prereqs.yml`.

Notes:

- **Prerequisites.** `systemd-timesyncd` is not installed: it conflicts with
  chrony, which keeps the nodes within Ceph's clock-skew limit
  (`preconfig.yml --tags ntp`).
- **SSH.** cephadm drives every host over SSH as root. Root has no password on
  Ubuntu, so `ssh-copy-id root@ceph02` from ceph01 can't log in. The playbook
  installs the key through the `opadm` account instead, and allows root to log
  in **with a key only** (`PermitRootLogin prohibit-password`).
- **OSDs.** `all-available-devices` takes every empty disk, including disks
  added later. A disk is only usable when `ceph orch device ls` shows it
  available (no partitions, no LVM, no filesystem).
- **Pools.** 3 replicas, one per node: I/O continues with one node down
  (`min_size 2`). The PG autoscaler resizes the initial 32 PGs.
- **Users.** Nova reuses `client.cinder` (it needs `vms` and read access to
  `images` for copy-on-write clones), so there is no separate Nova user.

## Health checks

```bash
ansible-playbook playbooks/health.yml --tags ceph
```

It fails on anything other than HEALTH_OK (warnings are listed), a MON out of
quorum, an OSD down or out, PGs not `active+clean`, or a stopped daemon. By
hand on ceph01: `ceph -s`, `ceph orch host ls`, `ceph orch ps`,
`ceph osd tree`, `ceph df`, `ceph osd pool autoscale-status`.

## Next: hand the cluster to Kolla-Ansible

- **Keyrings:** the `clients` tag writes them to `/etc/kolla/config/`. On a
  first build `/etc/kolla` does not exist yet. After
  [kolla/README.md](../kolla/README.md#2-etckolla) step 2, run
  `ansible-playbook playbooks/ceph-pools.yml --tags clients`.
- **ceph.conf:** a new cluster has a new fsid, so the `clients` tag fails and
  prints the minimal `ceph.conf`. Put those lines in the repo as
  `kolla/config/ceph.conf`, commit and push. `playbooks/kolla-config.yml`
  copies the file into place.

## Day 2

Running the cluster afterwards is covered in [OPERATIONS.md](OPERATIONS.md):
maintenance, adding and removing disks and nodes, pools and users, capacity,
upgrades, and backups.
