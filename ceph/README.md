# Ceph cluster

3-node Ceph cluster deployed with **cephadm**, the storage backend for Glance,
Cinder and Nova. It is built and kept in shape by Ansible playbooks run from
the deploy VM. [ceph-setup.sh](ceph-setup.sh) holds the equivalent manual
commands, for reference only.

| Host   | Storage IP (③) | Labels            | Daemons         | OSD disks                            |
|--------|----------------|-------------------|-----------------|--------------------------------------|
| ceph01 | 10.0.2.50      | `_admin` `mon` `mgr` | mon · mgr · osd | `/dev/sdb`, `/dev/sdc` (100 GB each) |
| ceph02 | 10.0.2.60      | `_admin` `mon` `mgr` `rgw` | mon · mgr · osd · rgw · haproxy · keepalived | `/dev/sdb`, `/dev/sdc` (100 GB each) |
| ceph03 | 10.0.2.70      | `mon` `rgw`       | mon · osd · rgw · haproxy · keepalived | `/dev/sdb`, `/dev/sdc` (100 GB each) |

- **Release:** squid (19.2.7, upgraded from reef 18.2.8 on 2026-11-26), from
  download.ceph.com (`ceph_release` in `inventory/group_vars/ceph_nodes.yml`).
  Next: tentacle 20.2.5 with [ceph-upgrade.yml](../playbooks/ceph-upgrade.yml)
  ([OPERATIONS.md](OPERATIONS.md#upgrades)); squid reaches end of life on
  2026-12-02.
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
| `rootfs`  | Grows the root LV (`/dev/ubuntu-vg/ubuntu-lv`) into the free space of its volume group, online (`lvextend -r`). Ubuntu's installer leaves half the disk unused; container images fill `/` and the MON warns below 30% free (`MON_DISK_LOW`) |
| `upgrade` | `apt update` + `apt upgrade` |
| `docker`  | `docker.io` (cephadm's container runtime), enabled and started |
| `cephadm` | download.ceph.com repo for `ceph_release` (the release the cluster runs, in `inventory/group_vars/ceph_nodes.yml`) + `cephadm` and `ceph-common` |
| `reboot`  | Reboots only nodes with `/var/run/reboot-required`, one at a time |

| `ceph-cluster.yml` tag | Runbook step | What it does |
|------------------------|--------------|--------------|
| `bootstrap` | 1 | `cephadm bootstrap` on ceph01: first MON + MGR, dashboard. Skipped when `/etc/ceph/ceph.conf` and the admin keyring exist, so re-runs on the live cluster are safe |
| `sshd`, `authkey`, `check` | 2 | [ceph-ssh.yml](../playbooks/ceph-ssh.yml): cephadm's SSH key for root on every Ceph node, then `ceph cephadm check-host` for each |
| `specs` | 3-4 | Renders `/etc/ceph/cluster-spec.yml` from the inventory: one host entry per node (storage IP, labels), MONs on the `mon` hosts, MGRs on the `mgr` hosts, OSDs on every empty disk (`all-available-devices`). When it changed: saves `ceph orch ls --export` to `/root/ceph-backups/`, prints `ceph orch apply --dry-run`, then applies. Waits for `ceph_osd_expected` OSDs. `-e ceph_spec_force=true` re-applies an unchanged file |
| `config` | - | Converges Ceph's config database to `ceph_config` in `group_vars/ceph_nodes.yml`: `ceph config set` for options whose stored value differs, then `ceph config rm` of host-level overrides (`osd/host:<node>`) of those options. Sets a fixed `osd_memory_target` (1.5 GiB per OSD) with autotuning off. Mutes (sticky) the health checks listed in `ceph_health_mutes`, each with its reason |
| `rgw` | - | Standalone S3 ([below](#object-storage-rgw-s3)), when `ceph_rgw_enabled`: creates the realm, zonegroup and zone if missing (`radosgw-admin`, then `period update --commit`), renders `/etc/ceph/rgw-spec.yml` (RGW + ingress) and applies it like the cluster spec (backup, dry run, apply when changed), then waits for the rgw / haproxy / keepalived daemons |
| `pools`, `users`, `clients` | 5-7 | [ceph-pools.yml](../playbooks/ceph-pools.yml), below |

| `ceph-pools.yml` tag | What it does |
|----------------------|--------------|
| `pools` | Creates missing pools from `ceph_pools` (`images`, `volumes`, `vms`), sets size / min_size / application when they differ, `rbd pool init` on new pools only |
| `users` | Creates missing users from `ceph_clients` (`client.glance`, `client.cinder`), updates caps that differ |
| `clients` | Writes the users' keyrings to `/etc/kolla/config/` on the deploy VM (mode 0600; skipped while `/etc/kolla` does not exist). Fails if the repo's `kolla/config/ceph.conf` does not match the cluster, printing the lines to commit |

| `ceph-upgrade.yml` tag | What it does |
|------------------------|--------------|
| `upgrade` | On ceph01, `-e ceph_upgrade_to=<release>`. Preflight (read-only, all of `--check`): target is the next release (no skipping, no downgrade), HEALTH_OK, a standby MGR, no other upgrade running, connected client releases. Then saves the cluster state to `/root/ceph-backups/`, pauses the PG autoscaler, `ceph orch upgrade check` + `start`, waits for cephadm, checks every daemon and `require_osd_release`, resumes the autoscaler, waits for HEALTH_OK. Re-running resumes an upgrade in progress or skips a finished one |
| `packages` | download.ceph.com repo of the new release + latest `cephadm` and `ceph-common` on every Ceph node, after the daemons; then removes the images no container uses (the old release, ~2 GB per node) |

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
- **Specs that don't stick.** cephadm's serve loop reads the specs at the
  start of each pass; a pass already running when `ceph orch apply` lands can
  save the old spec back (seen with the `rgw.s3` networks on Reef 18.2.8). The
  `specs` and `rgw` tags therefore wait `ceph_spec_settle_delay` (30 s) after
  applying and re-apply if `ceph orch ls --export` changed meanwhile. By hand:
  check `ceph orch ls <service> --export` a minute after an apply.
- **OSD memory.** Each OSD sizes its caches to `osd_memory_target`. cephadm's
  autotuning left ceph01/ceph02 at the 4 GiB default (2 OSDs = 8 GiB on a
  7.7 GiB VM), so the `config` tag sets 1.5 GiB per OSD for all and turns
  autotuning off. Raise it with the VMs' RAM.
- **Pools.** 3 replicas, one per node: I/O continues with one node down
  (`min_size 2`). The PG autoscaler resizes the initial 32 PGs.
- **Users.** Nova reuses `client.cinder` (it needs `vms` and read access to
  `images` for copy-on-write clones), so there is no separate Nova user.

## Object storage (RGW, S3)

Standalone S3: RGW users are local to Ceph (no Keystone). Clients use only the
VIP on the management network, the client network for object storage; the
gateways behind it stay on the storage network, internal to Ceph.

```
client ──► http://10.0.0.150:80  (keepalived VIP on mgmt01, haproxy on ceph02 + ceph03)
               └─► rgw.s3 on 10.0.2.60:8080 and 10.0.2.70:8080 (storage network)
                      └─► pools homelab-a.rgw.* (3 replicas, on the existing OSDs)
```

- **Placement:** RGW, haproxy and keepalived run on the hosts labelled `rgw`
  in `inventory/hosts.yml`. Each gateway listens on its storage IP
  (`ceph_rgw_networks`), port `ceph_rgw_port`.
- **Why the storage network:** the dashboard's Object Gateway pages call RGW
  at the daemons' Ceph public address (the storage IP); Reef has no setting
  to change it. Gateways bound to the management IP show "The Object Gateway
  Service is not configured ... Connection refused".
- **Realm / zonegroup / zone:** `homelab` / `homelab` / `homelab-a`, a
  single-site layout that can grow into multisite. The pools are created by
  RGW on first start and named after the zone (`homelab-a.rgw.*`), plus
  `.rgw.root`. The PG autoscaler sizes them.
- **Removal:** dropping the `rgw` label or setting `ceph_rgw_enabled: false`
  removes nothing. Remove by hand: `ceph orch rm ingress.rgw.s3`,
  `ceph orch rm rgw.s3` (the pools and data stay).

An S3 user per application, on ceph01. The keys are secrets: keep them out of
the repo.

```bash
radosgw-admin user create --uid=app1 --display-name="App 1"   # prints access_key / secret_key
radosgw-admin quota set --quota-scope=user --uid=app1 --max-size=10G
radosgw-admin quota enable --quota-scope=user --uid=app1
radosgw-admin user info --uid=app1                            # keys again
```

Clients: endpoint `http://10.0.0.150`, the user's keys, any region (e.g.
`us-east-1`), **path-style** addressing (`http://host/bucket/key`, no wildcard
DNS):

```bash
aws configure --profile ceph
aws --profile ceph --endpoint-url http://10.0.0.150 s3 mb s3://app1-data
aws --profile ceph --endpoint-url http://10.0.0.150 s3 cp ./file s3://app1-data/
```

By hand on ceph01: `ceph orch ls rgw`, `ceph orch ps --daemon-type rgw`,
`radosgw-admin period get`, `radosgw-admin bucket list`,
`curl http://10.0.0.150` (an anonymous empty bucket list). The haproxy status
page is on port `1967` of ceph02 and ceph03. In the dashboard: Object Gateway
(Gateways, Users, Buckets), using the `dashboard` RGW user cephadm created.

## Health checks

```bash
ansible-playbook playbooks/health.yml --tags ceph
```

It fails on anything other than HEALTH_OK (warnings are listed), a MON out of
quorum, an OSD down or out, PGs not `active+clean`, a stopped daemon, or (with
RGW) a gateway or the ingress VIP not answering HTTP 200. By
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
