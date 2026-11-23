# Ceph Day 2 operations

How to run the cephadm cluster after it is built: health checks, maintenance,
adding and removing disks and nodes, upgrades, backups. The build itself is in
[README.md](README.md).

Lab assumptions: 3 nodes (`ceph01`-`ceph03`) with 2 OSDs each, 3 MONs, 2 MGRs,
pools `images` / `volumes` / `vms` at `size 3` / `min_size 2` with failure
domain = host, release squid. `ceph` commands run as root on **ceph01** (the
admin node), or in `cephadm shell`.

## How cephadm applies a change

cephadm is to Ceph what kolla-ansible is to OpenStack. You declare a **service
spec** (where MONs, MGRs, OSDs run) and the orchestrator converges the cluster
to it, one daemon at a time.

| Control | Use it for |
|---------|------------|
| `ceph orch apply -i spec.yml --dry-run` | Preview a placement change |
| `ceph osd ok-to-stop <id>`, `ceph mon ok-to-stop <id>`, `ceph orch host ok-to-stop <host>` | "Can this go down without losing I/O or quorum?" |
| `ceph orch host maintenance enter/exit <host>` | Take one node down: stops its daemons, sets noout for it |
| `ceph osd set noout` / `norebalance` | No data movement during a short outage |
| `ceph orch upgrade start` | Rolling upgrade in the right order (MGR → MON → OSD …) |

Use the same loop for every change:

```
ceph -s shows HEALTH_OK → change ONE thing → wait for HEALTH_OK and all PGs active+clean → next
```

**Never have two nodes down at once.** With 3 replicas on 3 hosts and
`min_size 2`, a second node down stops I/O.

Health check, daily and before and after every change:

```bash
ceph -s
ceph health detail
ceph osd df tree
ceph orch ps --refresh | grep -v running    # daemons that are not running
ceph crash ls-new
```

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
2. **Repo (workstation):** add it to `ceph_nodes` in `inventory/hosts.yml`,
   write `netplan/ceph04.yaml` with its MACs, and update the README hosts
   table. Commit and push.
3. **Deploy VM:**
   ```bash
   source ~/venv/bin/activate
   ansible-playbook playbooks/preconfig.yml -K              # no --limit (clone check, /etc/hosts everywhere)
   ansible-playbook playbooks/ceph-prereqs.yml -K --limit ceph04
   ansible-playbook playbooks/ceph-ssh.yml -K
   ```
4. **ceph01:**
   ```bash
   ceph orch host add ceph04 10.0.2.80
   ceph orch device ls --refresh        # then add its OSDs (above)
   ```

Keep 3 MONs, or go to 5. Never use an even number. If the MONs change,
update the Kolla clients ([below](#keep-the-openstack-clients-in-step)).

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

Afterwards, remove it from `inventory/hosts.yml` and `netplan/`, and run
`ansible-playbook playbooks/preconfig.yml -K --tags hosts`.

## Capacity

If one of a host's 2 OSDs fails, its data moves to the other OSD **on the
same host**: there is no other host to take it. To stay under the 85%
`nearfull` alarm after that, keep each OSD below about **40% used**.

- Watch `ceph osd df` and `ceph df`.
- Cap a pool with `ceph osd pool set-quota <pool> max_bytes <n>`.
- Before reaching 40%, add OSDs (the same on every host) or a 4th node.

## Upgrades

- **Within squid:**
  ```bash
  ceph orch upgrade check --ceph-version 19.2.x
  ceph orch upgrade start --ceph-version 19.2.x
  ceph orch upgrade status        # ceph -W cephadm to follow it
  ```
- **squid → tentacle:**
  1. Read the release notes.
  2. Update the host CLI (`cephadm`, `ceph-common`):
     `ansible-playbook playbooks/ceph-prereqs.yml -K -e ceph_release=tentacle --tags cephadm`,
     and change `ceph_release` in the role defaults.
  3. Run `ceph orch upgrade start --ceph-version 20.2.x`.
  4. Check that `ceph osd dump | grep require_osd_release` shows the new release.

  The Kolla containers bring their own Ceph client libraries, so OpenStack
  keeps working as long as the release gap stays small.
- **Operating system:** standard support for Ubuntu 22.04 ends in 2027. Move
  the Ceph nodes to 24.04 one at a time in maintenance mode. Check first that
  download.ceph.com publishes noble builds of your Ceph release.

## Keep the OpenStack clients in step

Kolla's Glance, Cinder and Nova read `kolla/config/ceph.conf` (fsid + MON
addresses). If a MON is added, removed or changes IP:

```bash
# ceph01
ceph config generate-minimal-conf > /tmp/ceph.conf
sed -i 's/^[[:space:]]\+//' /tmp/ceph.conf
```

1. Put it in the repo as `kolla/config/ceph.conf`, then commit and push.
2. On the deploy VM: `ansible-playbook playbooks/kolla-config.yml --diff`.
3. Then: `kolla-ansible reconfigure -i inventory/multinode --tags glance,cinder,nova`.

The keyrings change only if the `client.glance` / `client.cinder` keys
change. Copy them to `/etc/kolla/config/` by hand, as in
[kolla/README.md](../kolla/README.md#2-etckolla).

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
