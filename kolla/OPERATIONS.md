# Day 2 operations

How to change the running cloud safely with kolla-ansible: add or remove nodes
and services, change config, upgrade, back up, and power the lab off and on.
The initial deployment is in [README.md](README.md).

Lab assumptions: a single `controller` (control, network, monitoring, storage),
`compute01`/`compute02`, external Ceph, Docker, images from
`quay.io/openstack.kolla`, kolla-ansible 22.x in `~/venv-2026.1`.

Every command below runs **on the deploy VM**, from `~/openstack-homelab`:

```bash
source ~/venv-2026.1/bin/activate && cd ~/openstack-homelab
```

The CLI moved to cliff, so some sub-command names changed (`mariadb-backup`
was `mariadb_backup`). When in doubt, check `kolla-ansible help`.

## How kolla-ansible applies a change

Kolla compares the desired state (`globals.yml`, `/etc/kolla/config/*`, the
inventory) with what is running. It regenerates config and restarts only the
containers whose config or image changed. What keeps a change safe:

| Control | What it does | Use it for |
|---------|--------------|------------|
| `--limit <host>` | Runs on those hosts only. Facts are still gathered from all hosts, and cluster-wide steps are handed to the controllers | Adding or removing a node |
| `--tags <svc>` | Runs only that service's role | Config changes to one service |
| `prechecks` | Checks ports, interfaces, versions and config, changes nothing | Before every `deploy`/`upgrade` |
| `validate-config` | Checks the generated config files with oslo-config-validator | After editing overrides |
| `reconfigure` | `deploy` for config changes | Changing a running service |
| `stop` / `destroy` + `--limit` | Stops containers / removes containers, volumes and config | Taking a node out |

**Never run `destroy` without `--limit`: it wipes the whole cloud.**

Use the same loop for every change:

```
workstation: edit → git commit → git push   (this also updates the repo on the deploy VM)
deploy VM:   health.yml → kolla-config.yml → prechecks → pull → deploy/reconfigure (--limit/--tags) 2>&1 | tee log → health.yml
```

`/etc/kolla` is only ever written from the repo, by
`playbooks/kolla-config.yml` (it uses the repo's Ansible venv, not Kolla's):

```bash
source ~/venv/bin/activate
ansible-playbook playbooks/kolla-config.yml --check --diff   # what would change
ansible-playbook playbooks/kolla-config.yml --diff           # apply, then prints the kolla-ansible command to run
source ~/venv-2026.1/bin/activate
```

Never edit `/etc/kolla/globals.yml` or the overrides on the deploy VM: the next
sync overwrites them. Secrets (`passwords.yml`, keyrings) are the exception;
they stay outside the repo. Details in [README.md](README.md#2-etckolla).

Verify the same way every time, before the change and after it, with the
read-only health check (repo venv). It covers every node, Ceph, the Kolla
containers and the OpenStack services, and fails if any check fails:

```bash
source ~/venv/bin/activate
ansible-playbook playbooks/health.yml                  # or --tags nodes|ceph|openstack
```

For details: `source /etc/kolla/admin-openrc.sh`, then
`openstack compute service list`, `openstack network agent list`,
`openstack volume service list`, `openstack hypervisor list`.

## Add a compute node

Example: `compute03`, 10.0.0.80 / 10.0.2.80.

1. **VMware:** create an Ubuntu 24.04 VM with the same 4 networks as compute01.
   Tick *Virtualize Intel VT-x/EPT or AMD-V/RVI*, because
   `nova_compute_virt_type` is `kvm`.
2. **Repo (workstation):**
   - `inventory/hosts.yml`: add it under `compute`, with `mgmt_ip` and `storage_ip`.
   - `inventory/multinode`: add
     `compute03 ansible_host=10.0.0.80 ansible_user=opadm ansible_become=True`
     under `[compute]`.
   - `netplan/compute03.yaml`: write it with the VM's real MACs.
   - Update the hosts table in the [README](../README.md), then commit and push.
3. **Node prep, without `--limit`.** Every existing node needs the new
   `/etc/hosts` entry: live migration uses host names. The clone check also
   compares machine-ids across hosts.
   ```bash
   source ~/venv/bin/activate
   ansible-playbook playbooks/preconfig.yml -K
   ```
4. **Kolla, on the new node only:**
   ```bash
   source ~/venv-2026.1/bin/activate
   kolla-ansible bootstrap-servers -i inventory/multinode --limit compute03
   kolla-ansible prechecks         -i inventory/multinode --limit compute03
   kolla-ansible pull              -i inventory/multinode --limit compute03
   kolla-ansible deploy            -i inventory/multinode --limit compute03 2>&1 | tee ~/add-compute03.log
   ```
   The deploy registers the host in the Nova cell (`discover_hosts` runs on the
   controller). It also copies the `client.cinder` keyring from
   `/etc/kolla/config/nova/`.
5. **Verify:**
   - compute03 shows in `openstack hypervisor list` and in
     `openstack network agent list --host compute03`.
   - `ping 10.0.2.50` works from compute03 (RBD traffic goes over `stor01`).
   - A test VM boots there with
     `openstack server create --availability-zone nova:compute03 ...`.

## Remove a compute node

```bash
source /etc/kolla/admin-openrc.sh
# 1. No new instances on it
openstack compute service set --disable --disable-reason "decommission" compute02 nova-compute
# 2. Move its instances away (Ceph-backed disks: a live migration copies only memory)
openstack server list --all-projects --host compute02
openstack server migrate --live-migration <server-id>      # each one; or: nova host-evacuate-live compute02
# 3. Stop its containers
kolla-ansible stop -i inventory/multinode --limit compute02 --yes-i-really-really-mean-it
# 4. Remove it from the service catalogue
openstack compute service delete $(openstack compute service list --host compute02 -f value -c ID)
openstack network agent delete $(openstack network agent list --host compute02 -f value -c ID)
openstack resource provider list   # delete any provider left for compute02
# 5. Optional: wipe Kolla from the host
kolla-ansible destroy -i inventory/multinode --limit compute02 --yes-i-really-really-mean-it
```

Then remove the host from both inventories and `netplan/`, and run
`ansible-playbook playbooks/preconfig.yml -K --tags hosts`. Commit and push.
If Prometheus is enabled, run `kolla-ansible reconfigure --tags prometheus` so
it stops scraping the old host.

## Compute maintenance (patching, reboot, resize)

1. Drain the host: steps 1-2 of [Remove a compute node](#remove-a-compute-node).
   With 2 computes, check first that the other one has enough free RAM.
2. Patch and reboot it, then check its containers are healthy.
3. `openstack compute service set --enable compute02 nova-compute`

## The controller

- **Reboot or patching:** a full outage of the APIs and Horizon. Running
  instances keep running, but floating IPs and SNAT stop: they go through the
  L3 agent on the controller.
- **Moving to HA** takes 3 controllers, because Galera and RabbitMQ need an
  odd-sized quorum:
  1. Back up MariaDB.
  2. Add the hosts to `[control]`, `[network]` and `[monitoring]`.
  3. Run `bootstrap-servers` and `pull` on them.
  4. Run `deploy --limit control`, so MariaDB, RabbitMQ and keepalived
     re-cluster.
  5. Run a full `deploy`.
- **Removing a controller** (3-node setup only):
  1. Move its routers and DHCP to other agents (`openstack network agent
     remove router` / `add router`).
  2. Run `stop --limit <host>`.
  3. Remove it from the inventory.
  4. Run `deploy --limit control`.

## Enable a service

Example: Designate, Octavia, Prometheus/Grafana.

1. Read the service's guide under
   `https://docs.openstack.org/kolla-ansible/2026.1/reference/`. Many services
   need more than a flag: Octavia needs certificates and a management
   network, Designate a backend.
2. Set `enable_<svc>: "yes"` in [globals.yml](globals.yml), commit and push.
   Then run `ansible-playbook playbooks/kolla-config.yml --diff`.
3. Add the new passwords. A `passwords.yml` from an older release lacks keys, so
   merge before generating:
   ```bash
   cp /etc/kolla/passwords.yml ~/passwords.yml.bak-$(date +%F)
   kolla-mergepwd --old /etc/kolla/passwords.yml \
     --new ~/venv-2026.1/share/kolla-ansible/etc_examples/kolla/passwords.yml \
     --final /etc/kolla/passwords.yml
   kolla-genpwd
   ```
4. Deploy:
   ```bash
   kolla-ansible prechecks -i inventory/multinode
   kolla-ansible pull      -i inventory/multinode
   kolla-ansible deploy    -i inventory/multinode 2>&1 | tee ~/enable-<svc>.log
   ```
   Use a **full `deploy`**, not `--tags <svc>`. A new service also touches
   HAProxy (`loadbalancer`), Keystone endpoints, Horizon panels and sometimes
   Neutron or Nova. A full deploy is idempotent: services it does not change
   are not restarted.

## Disable a service

Setting `enable_<svc>: "no"` does **not** remove anything. Kolla just stops
managing the service. To clean it up fully:

1. Set `enable_<svc>: "no"`, commit, push, and run `playbooks/kolla-config.yml`.
2. Stop it with
   `kolla-ansible stop -i inventory/multinode --tags <svc> --yes-i-really-really-mean-it`.
   If `stop` ignores the tag, run `docker stop` / `docker rm` on the
   `<svc>_*` containers.
3. On the hosts: `docker volume rm` its volumes, and remove `/etc/kolla/<svc>-*`.
4. Control plane:
   - `openstack service delete`, `openstack endpoint delete`,
     `openstack user delete <svc>`
   - drop its MariaDB database
   - delete its RabbitMQ user/vhost
5. Run `kolla-ansible reconfigure -i inventory/multinode --tags loadbalancer,horizon`
   to drop its HAProxy frontend and dashboard.

## Change the config of a running service

Kolla merges override files over its generated config. Create them in the
repo under `kolla/config/`, at the path they need under `/etc/kolla/config/`:

```
kolla/config/nova.conf                 # every nova container
kolla/config/nova/nova-compute.conf    # one container
kolla/config/nova/compute02/nova.conf  # one host
```

Commit and push, then on the deploy VM:

```bash
ansible-playbook playbooks/kolla-config.yml --diff     # repo venv (~/venv)
kolla-ansible validate-config -i inventory/multinode --tags nova
kolla-ansible reconfigure     -i inventory/multinode --tags nova [--limit compute01]
```

Override files must have **no indented lines**: this is the same INI-parser
problem as `ceph.conf` (see [Troubleshooting](README.md#troubleshooting)).

## Upgrades

- **Within 2026.1** (new images, bug fixes):
  ```bash
  uv pip install -U 'kolla-ansible==22.*' && kolla-ansible install-deps
  kolla-ansible prechecks -i inventory/multinode
  kolla-ansible pull      -i inventory/multinode
  kolla-ansible upgrade   -i inventory/multinode 2>&1 | tee ~/upgrade.log
  ```
- **To the next release.** 2026.1 is a SLURP release, so you can go straight
  to 2027.1:
  1. Create a new venv (`~/venv-2027.1`) and keep the old one for rollback.
  2. Read the kolla-ansible *Upgrade Notes*.
  3. Run `kolla-mergepwd`.
  4. Bump `openstack_release`. Upgrade the nodes' Ubuntu first if the new
     release requires it.
  5. Back up MariaDB.
  6. Run `bootstrap-servers`, `prechecks`, `pull`, `upgrade`, `post-deploy`.
- **Do not fall behind.** quay.io deletes the images of releases past their
  maintained phase. After that you can neither redeploy nor add a node,
  unless the images are mirrored in a local registry.

## Backup and restore

| What | How |
|------|-----|
| Database | Set `enable_mariabackup: "yes"` and run `deploy --tags mariadb` once. Back up with `kolla-ansible mariadb-backup -i inventory/multinode [--incremental]`. Backups land in the `mariadb_backup` Docker volume **on the controller**: copy them off it |
| Secrets | `/etc/kolla/passwords.yml`, the Ceph keyrings and `admin-openrc.sh` exist only on the deploy VM. Keep an encrypted copy (ansible-vault, age) off it. Without `passwords.yml` the cloud cannot be managed |
| After a full power loss | `kolla-ansible mariadb-recovery -i inventory/multinode`: Galera does not start by itself after an unclean shutdown |
| VMware snapshots | Only with **every OpenStack and Ceph VM powered off, as one consistent set**. Never revert a single Ceph node. Reverting the controller alone leaves the database out of step with Ceph (orphaned volumes, lost references) |

## Power off / power on the lab

- **Shutdown:**
  1. Stop the instances.
  2. Shut down compute01 and compute02, then the controller.
  3. On ceph01, run `ceph osd set noout`, then shut down ceph03, ceph02, ceph01.
  4. Shut down the deploy VM last: it is the NTP source.
- **Startup**, in reverse:
  1. Start the deploy VM.
  2. Start Ceph and wait for `HEALTH_OK` (apart from the noout flag). Then run
     `ceph osd unset noout`.
  3. Start the controller and check its containers are healthy.
  4. Start the computes.

To restart instances by themselves after a reboot, put
`resume_guests_state_on_host_boot = true` in `[DEFAULT]` of
`/etc/kolla/config/nova/nova-compute.conf`.
