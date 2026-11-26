# Ceph Day 2 operations

How to run the cephadm cluster after it is built: health checks, maintenance,
adding and removing disks and nodes, upgrades, backups. The build itself is in
[README.md](README.md).

Lab assumptions: 3 nodes (`ceph01`-`ceph03`) with 2 OSDs each, 3 MONs, 2 MGRs,
pools `images` / `volumes` / `vms` at `size 3` / `min_size 2` with failure
domain = host, release tentacle (upgrades below). `ceph` commands run as root on **ceph01** or **ceph02** (both
carry the `_admin` label, so cephadm keeps `/etc/ceph/ceph.conf` and the admin
keyring on them), or in `cephadm shell`.

The cluster is described in the repo and converged by Ansible, from the
deploy VM (`source ~/venv/bin/activate`, repo root):

| What | Where in the repo | Applied by |
|------|-------------------|------------|
| Hosts, storage IPs, labels (`_admin`, `mon`, `mgr`) | `inventory/hosts.yml` (`ceph_nodes`, `ceph_labels`) | `ceph-cluster.yml --tags specs` |
| MON / MGR placement (hosts with the `mon` / `mgr` label), OSDs on every empty disk | `inventory/group_vars/ceph_nodes.yml`, `playbooks/roles/ceph_specs/templates/cluster-spec.yml.j2` | `ceph-cluster.yml --tags specs` |
| Pools, CephX users, Kolla keyrings | `inventory/group_vars/ceph_nodes.yml` | `ceph-pools.yml` |

Change these files, not the cluster by hand: a later run puts the repo's
state back. Preview with `--check --diff`.

## How cephadm applies a change

cephadm is to Ceph what kolla-ansible is to OpenStack. You declare a **service
spec** (where MONs, MGRs, OSDs run) and the orchestrator converges the cluster
to it, one daemon at a time.

| Control | Use it for |
|---------|------------|
| `ceph-cluster.yml --tags specs --check --diff` | Preview a spec change (the playbook also runs `ceph orch apply --dry-run` before applying) |
| `ceph osd ok-to-stop <id>`, `ceph mon ok-to-stop <id>`, `ceph orch host ok-to-stop <host>` | "Can this go down without losing I/O or quorum?" |
| `ceph orch host maintenance enter/exit <host>` | Take one node down: stops its daemons, sets noout for it |
| `ceph osd set noout` / `norebalance` | No data movement during a short outage |
| `ceph orch upgrade start` | Rolling upgrade in the right order (MGR → MON → OSD …) |

Use the same loop for every change:

```
health.yml passes → change ONE thing → wait for HEALTH_OK and all PGs active+clean → health.yml passes → next
```

**Never have two nodes down at once.** With 3 replicas on 3 hosts and
`min_size 2`, a second node down stops I/O.

Health check, daily and before and after every change, from the deploy VM:

```bash
ansible-playbook playbooks/health.yml --tags ceph    # or without --tags: the whole lab
```

It checks HEALTH_OK, MON quorum, OSDs up/in, PGs active+clean, the fullest OSD
against the 40% rule ([Capacity](#capacity)), cephadm daemons and new crashes,
and fails if anything is wrong. For details, on ceph01: `ceph health detail`,
`ceph osd df tree`, `ceph orch ps --refresh`, `ceph crash ls-new`.

## Node maintenance

Patching or rebooting a node, one node at a time:

```bash
ceph orch host ok-to-stop ceph02
ceph orch host maintenance enter ceph02
# patch / reboot ceph02
ceph orch host maintenance exit ceph02
ceph -s          # wait for active+clean before the next node
```

## Add a disk (OSD)

1. Add the virtual disk to the VM in VMware.
2. Run `ceph orch device ls --refresh`. The disk must show `AVAILABLE = Yes`.
3. If the cluster was built with runbook option A (`--all-available-devices`),
   the OSD is created automatically. Otherwise:
   `ceph orch daemon add osd ceph02:/dev/sdd`.

Add the same capacity on every host. CRUSH puts one replica per host, so
the smallest host limits usable space.

## Replace a failed OSD

```bash
ceph orch osd rm 4 --replace --zap     # drains it, keeps id 4 reserved
ceph orch osd rm status                # wait until it is gone
# swap the disk: cephadm recreates osd.4 on it (option A), or `ceph orch daemon add osd`
```

## Add a node

Example: `ceph04`, 10.0.0.80 / 10.0.2.80.

1. **VMware:** create a VM with 3 NICs (NAT, management, storage), Ubuntu
   22.04 like the other Ceph nodes, and empty OSD disks.
2. **Repo (workstation):**
   - Add it to `ceph_nodes` in `inventory/hosts.yml`, with `storage_ip` and
     `ceph_labels` (`[]` for an OSD-only node).
   - Write `netplan/ceph04.yaml` with its MACs.
   - Raise `ceph_osd_expected` in `inventory/group_vars/ceph_nodes.yml`.
   - Update the README hosts table. Commit and push.
3. **Deploy VM:**
   ```bash
   source ~/venv/bin/activate
   ansible-playbook playbooks/health.yml
   ansible-playbook playbooks/preconfig.yml -K              # no --limit (clone check, /etc/hosts everywhere)
   ansible-playbook playbooks/ceph-prereqs.yml -K --limit ceph04
   ansible-playbook playbooks/ceph-cluster.yml --tags sshd,authkey,check,specs --check --diff
   ansible-playbook playbooks/ceph-cluster.yml --tags sshd,authkey,check,specs
   ansible-playbook playbooks/health.yml
   ```
   The `specs` tag adds the host and its labels. The OSD spec then creates OSDs
   on its empty disks, and the run waits for `ceph_osd_expected` OSDs.

Keep 3 MONs, or go to 5: never an even number of `mon` labels. If the MONs
change, update the Kolla clients ([below](#keep-the-openstack-clients-in-step)).

## Remove a node

First, think about replicas. With `size 3` and failure domain = host, a
2-host cluster leaves every PG undersized for good. Either add the
replacement node first, or knowingly drop the pools to `size 2` /
`min_size 1`, which risks data loss. Then:

```bash
ceph orch host drain ceph03      # removes its daemons, drains its OSDs
ceph orch osd rm status          # wait until empty
ceph orch host rm ceph03
```

Afterwards:
1. Remove it from `inventory/hosts.yml` and `netplan/`, and lower
   `ceph_osd_expected`. Commit and push.
2. Run `ansible-playbook playbooks/preconfig.yml -K --tags hosts`.
3. Run `ansible-playbook playbooks/ceph-cluster.yml --tags specs`, so the
   applied spec matches the repo again.

If it carried `mon` or `_admin`, give those labels to another host in
`hosts.yml` first and apply the specs, so 3 MONs and 2 admin nodes remain.

## Pools and users

Pools (size, min_size, application) and CephX users (caps) are lists in
`inventory/group_vars/ceph_nodes.yml`. Edit them, commit and push, then:

```bash
ansible-playbook playbooks/ceph-pools.yml --check --diff
ansible-playbook playbooks/ceph-pools.yml
```

The playbook creates what is missing and changes what differs. It never
deletes a pool or a user: do that by hand (`ceph osd pool rm`, `ceph auth rm`)
after removing it from the lists.

## Capacity

If one of a host's 2 OSDs fails, its data moves to the other OSD **on the
same host**: there is no other host to take it. To stay under the 85%
`nearfull` alarm after that, keep each OSD below about **40% used**.

- Watch `ceph osd df` and `ceph df`.
- Cap a pool with `ceph osd pool set-quota <pool> max_bytes <n>`.
- Before reaching 40%, add OSDs (the same on every host) or a 4th node.

## Upgrades

[ceph-upgrade.yml](../playbooks/ceph-upgrade.yml) moves the cluster one
release per run: **reef 18.2.8 → squid 19.2.7 → tentacle 20.2.5** (versions in
`ceph_upgrade_versions`, `inventory/group_vars/ceph_nodes.yml`). Ceph tests
upgrades from the last two stable releases only, so reef never jumps straight
to tentacle; the playbook refuses skips and downgrades.

**There is no way back**: Ceph cannot downgrade, and the upgrade raises
`require_osd_release`. Before each run:

1. Read the target's release notes, in particular the *critical upgrade steps*
   of squid 19.2.6+ and tentacle 20.2.4+ (CVE fixes).
2. Power off the 3 Ceph VMs (OpenStack VMs first, or stop their I/O) and take a
   VMware snapshot of each: the only rollback. Power them back on.
3. `ansible-playbook playbooks/health.yml --tags ceph` must pass.
4. Note the OpenStack Ceph client, with OpenStack up:
   `ssh compute01 sudo docker exec nova_compute dpkg -l librbd1`.

Then, per release:

```bash
ansible-playbook playbooks/ceph-upgrade.yml -e ceph_upgrade_to=squid --check   # preflight only
ansible-playbook playbooks/ceph-upgrade.yml -e ceph_upgrade_to=squid           # 30-60 min
# on ceph01, meanwhile: ceph -W cephadm   /   ceph orch upgrade status
```

Set `ceph_release: squid` in `inventory/group_vars/ceph_nodes.yml`, commit,
push. Check `health.yml`, the S3 test through the VIP, and OpenStack (boot an
instance from a Glance image, attach a Cinder volume). Repeat with
`ceph_upgrade_to=tentacle`.

- **OpenStack:** the Kolla containers bring their own Ceph client libraries.
  A cluster keeps serving older clients, so nothing changes on the OpenStack
  side, as long as `require_min_compat_client` stays `luminous` (the playbook
  never raises it) and `rbd_default_features` is left alone.
- **During the upgrade:** cephadm restarts mgr → mon → crash → osd → rgw one
  at a time. With 3 replicas and `min_size 2`, I/O continues; each OSD restart
  pauses it for a few seconds. RGW traffic moves to the other gateway via the
  VIP.
- **CephX key types (squid 19.2.6+, CVE-2025-30156):** after the upgrade the
  cluster raises `AUTH_INSECURE_*` warnings for keys of type `aes`. cephadm
  moves the daemon keys to `aes256k` itself; `AUTH_INSECURE_ROTATING_SERVICE_KEY_TYPE`
  clears within ~1 h. The client keys (admin, bootstrap, crash, exporter,
  RGW, and OpenStack's `client.glance` / `client.cinder`) stay `aes`, with
  `aes` still allowed and the three remaining warnings muted
  (`ceph_health_mutes`, `ceph-cluster.yml --tags config`). Rotating them is a
  separate step, once OpenStack's librbd is known to support `aes256k`:
  `ceph auth rotate --key-type=aes256k client.<id>`, then the new keyring
  wherever the key is used (`ceph-pools.yml --tags clients` + Kolla reconfigure
  for glance/cinder/nova, including nova's libvirt secret). Only then
  `ceph mon set auth_allowed_ciphers aes256k` and remove the mutes.
- **Tentacle specifics (seen 2026-11-26):** after the last OSD, cephadm
  rotates each OSD's key to `aes256k` and redeploys it one by one (the
  progress counter goes down for a while; normal). When it completes it
  unmutes every AUTH check; the playbook re-applies `ceph_health_mutes`.
- **Slow internet:** cephadm pulls the ~2 GB image on each host during the
  upgrade and `upgrade check` gives up after 15 min. Pre-pull it first on
  every Ceph node (`sudo docker pull quay.io/ceph/ceph:v<version>`, it resumes
  where it stopped), then run the playbook. The monitoring images (prometheus,
  grafana, ...) are pulled during the run.
- **If it stops:** `ceph orch upgrade status` and `ceph health detail`
  (`UPGRADE_*` alerts) say why. Fix it, then re-run the playbook: it resumes.
  `ceph orch upgrade stop` abandons it; the daemons already upgraded stay
  upgraded.
- **Within a release** (e.g. 20.2.5 → 20.2.6): change the version in
  `ceph_upgrade_versions` and re-run with the same `ceph_upgrade_to`.
- **Not fixed by upgrading:** the dashboard's Object Gateway *Overview* page
  slows down and freezes in the browser (it piles up requests on every
  refresh; the code is the same in squid and tentacle). The Gateways, Users
  and Buckets pages are fine.
- **Operating system:** standard support for Ubuntu 22.04 ends in 2027. Move
  the Ceph nodes to 24.04 one at a time in maintenance mode. Check first that
  download.ceph.com publishes noble builds of your Ceph release.

## Keep the OpenStack clients in step

Kolla's Glance, Cinder and Nova read `kolla/config/ceph.conf` (fsid + MON
addresses). If a MON is added, removed or changes IP:

`ansible-playbook playbooks/ceph-pools.yml --tags clients` checks this: it
fails when the repo's `kolla/config/ceph.conf` no longer matches the cluster,
and prints the lines to put in it. Then:

1. Replace `kolla/config/ceph.conf` with those lines on the workstation,
   commit and push.
2. On the deploy VM: `ansible-playbook playbooks/kolla-config.yml --diff`.
3. Then: `kolla-ansible reconfigure -i inventory/multinode --tags glance,cinder,nova`.

The same `clients` tag writes the `client.glance` / `client.cinder` keyrings
to `/etc/kolla/config/` on the deploy VM, so a changed key only needs that run
and the same `reconfigure`.

## Backup and recovery

- **Ceph is not a backup.** A deleted volume is gone from all 3 replicas.
  - For important RBD images: take snapshots (`rbd snap create`) and export
    them (`rbd export`, or `rbd export-diff` for increments) to storage
    outside the cluster.
  - Or enable `cinder-backup` with a `backups` pool.
- **Cluster metadata:** ship it off the lab nightly, encrypted, with the Kolla
  backups:
  ```bash
  tar czf ceph-meta-$(date +%F).tgz /etc/ceph
  ceph config dump > config-dump.txt
  ceph auth export > auth-export.txt        # contains every key: secret
  ceph orch ls --export > specs.yml
  ceph mon dump > monmap.txt
  ```
- **Power off / power on** order (Ceph after OpenStack, with `noout`): see
  [kolla/OPERATIONS.md](../kolla/OPERATIONS.md#power-off--power-on-the-lab).
