# OpenStack with Kolla-Ansible

OpenStack **2026.1 (Gazpacho)** deployed with **kolla-ansible 22.x** from the
deploy VM, on top of the external Ceph cluster built in [../ceph](../ceph/README.md).

| File here | Goes to (deploy VM) | What it is |
|-----------|---------------------|------------|
| [globals.yml](globals.yml) | `/etc/kolla/globals.yml` | The lab's Kolla configuration (VIP, interfaces, Ceph backends, enabled services) |
| [config/ceph.conf](config/ceph.conf) | `/etc/kolla/config/{glance,cinder,nova}/ceph.conf` | Minimal Ceph client config (fsid + MONs) of *this* lab's cluster; generate your own (Ceph runbook step 7) |
| [../inventory/multinode](../inventory/multinode) | used in place | Kolla inventory: controller = control/network/monitoring/storage, compute01/02 = compute |

`passwords.yml` and the Ceph keyrings are secrets and are **not** in the repo.

Once deployed, running the cloud (adding/removing nodes and services, config
changes, upgrades, backups, power off/on) is covered in
[OPERATIONS.md](OPERATIONS.md).

## Requirements

- OpenStack nodes (controller, compute01, compute02) on **Ubuntu 24.04**: it is
  the only Ubuntu release that kolla-ansible 22 accepts, and the only one with
  published images.
- Python **≥ 3.11** on the deploy VM (ansible-core 2.19/2.20).
- Passwordless sudo for the Ansible user on every node
  (`ansible-playbook playbooks/preconfig.yml -K --tags sudo`).
- The Ceph pools and users from the Ceph runbook (steps 5-7).

## 1. kolla-ansible on the deploy VM

A virtualenv with a standalone Python 3.12 from [uv](https://docs.astral.sh/uv/)
works whatever the deploy VM's own Python is (here Ubuntu 22.04, Python 3.10):

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
uv venv --python 3.12 ~/venv-2026.1
source ~/venv-2026.1/bin/activate
uv pip install 'kolla-ansible==22.*'
kolla-ansible install-deps
```

## 2. /etc/kolla

```bash
sudo install -d -o $USER -g $USER /etc/kolla
cp ~/venv-2026.1/share/kolla-ansible/etc_examples/kolla/passwords.yml /etc/kolla/
kolla-genpwd                                   # fills every empty password
source ~/venv/bin/activate                     # the repo's Ansible
ansible-playbook playbooks/kolla-config.yml --diff
```

`/etc/kolla` is written **only from the repo**: edit `kolla/globals.yml` or a
file under `kolla/config/` on the workstation, commit and push, then run
`playbooks/kolla-config.yml` on the deploy VM. Never edit the copies in `/etc/kolla`.

| Repo file | Copied to |
|-----------|-----------|
| `kolla/globals.yml` | `/etc/kolla/globals.yml` |
| `kolla/config/ceph.conf` | `/etc/kolla/config/{glance,cinder,nova}/ceph.conf` |
| any other `kolla/config/<path>` (Kolla [config overrides](OPERATIONS.md#change-the-config-of-a-running-service)) | `/etc/kolla/config/<path>` |

| `kolla-config.yml` | What it does |
|--------------------|--------------|
| *(always)* | Fails if `/etc/kolla` is not writable, or if a `.conf`/`.ini` under `kolla/config/` has an indented line |
| *(always)* | Dry-run comparison of every file (diffs with `--diff`), then copies only the files that differ |
| `backup` | Before any change, `~/kolla-backups/kolla-config-<UTC time>.tgz` of `globals.yml` + `config/` (keyrings included, last 20 kept) |
| *(always)* | Reports files in `/etc/kolla/config` that the repo does not manage, missing secrets, and the `kolla-ansible` command to run next |

It only adds and updates files: it never deletes one (remove an override by
hand), and never touches `passwords.yml` or the keyrings. Preview with
`--check --diff`.

Settings in `globals.yml` that matter for this lab:

| Setting | Value | Why |
|---------|-------|-----|
| `openstack_release` | `2026.1` | |
| `kolla_internal_vip_address` | `10.0.0.100` | HAProxy/keepalived VIP on the management network |
| `network_interface` / `storage_interface` / `neutron_external_interface` | `mgmt01` / `stor01` / `prov01` | NIC names set by [netplan](../netplan/README.md) |
| `kolla_test_images` | `yes` | Images come from `quay.io/openstack.kolla`; since 2026.1 the prechecks refuse them otherwise (same as `--use-test-images`) |
| `glance_backend_ceph`, `cinder_backend_ceph`, `nova_backend_ceph` | `yes` | External Ceph for images, volumes and VM disks |
| `ceph_nova_user` | `cinder` | Nova reuses `client.cinder` (no separate Nova user) |
| `enable_cinder_backup` | `no` | On by default; would need a `backups` pool and `client.cinder-backup` |

Ceph client files, from ceph01 (Ceph runbook steps 6-7):

| File on ceph01 | Goes to |
|----------------|---------|
| `/tmp/ceph.conf` | the repo, as `kolla/config/ceph.conf` (commit it; `kolla-config.yml` copies it) |
| `/etc/ceph/ceph.client.glance.keyring` | `/etc/kolla/config/glance/`, by hand (secret) |
| `/etc/ceph/ceph.client.cinder.keyring` | `/etc/kolla/config/cinder/cinder-volume/` and `/etc/kolla/config/nova/`, by hand (secret) |

`ceph.conf` must have **no indented lines** (see Troubleshooting); the
playbook refuses to copy one that has.

## 3. Deploy

```bash
source ~/venv-2026.1/bin/activate && cd ~/openstack-homelab
kolla-ansible bootstrap-servers -i inventory/multinode   # Docker + host setup
kolla-ansible prechecks         -i inventory/multinode
kolla-ansible pull              -i inventory/multinode
kolla-ansible deploy            -i inventory/multinode
kolla-ansible post-deploy       -i inventory/multinode   # writes /etc/kolla/admin-openrc.sh
```

The deploy VM (`localhost` in the inventory) has
`prechecks_enable_host_os_checks=false`: it runs no containers, so it may stay
on Ubuntu 22.04 while the prechecks accept only 24.04.

## 4. Use it

- **Horizon:** `http://10.0.0.100/`, domain `Default`, user `admin`, password
  `keystone_admin_password` from `/etc/kolla/passwords.yml`.
- **CLI:**
  ```bash
  uv pip install python-openstackclient
  source /etc/kolla/admin-openrc.sh
  openstack service list
  ```
- **Smoke test** (CirrOS image, networks, router, flavors):
  `~/venv-2026.1/share/kolla-ansible/init-runonce`. Its defaults
  (`DEMO_NET_CIDR=10.0.0.0/24`, `EXT_NET_CIDR=10.0.2.0/24`) are exactly this
  lab's management and storage networks: override them, with `EXT_NET_*` set
  to the subnet of the VMware network behind `prov01`:
  ```bash
  DEMO_NET_CIDR=192.168.100.0/24 DEMO_NET_GATEWAY=192.168.100.1 \
  EXT_NET_CIDR=<provider-cidr> EXT_NET_GATEWAY=<provider-gw> \
  EXT_NET_RANGE='start=<first>,end=<last>' \
  ~/venv-2026.1/share/kolla-ansible/init-runonce
  ```

### Adding a service later

See [OPERATIONS.md](OPERATIONS.md#enable-a-service). In short: set
`enable_<service>: "yes"` in `globals.yml`, merge and generate the new passwords
(`kolla-mergepwd`, `kolla-genpwd`), run `prechecks` and `pull`, and then run a
full `kolla-ansible deploy`. A `--tags <service>` run would miss the HAProxy,
Keystone and Horizon changes. To change the config of a deployed service:
`kolla-ansible reconfigure -i inventory/multinode --tags <service>`.

## Troubleshooting

Problems hit while building this lab, and their fixes:

| Symptom | Cause | Fix |
|---------|-------|-----|
| `pull`/`deploy`: `failed to resolve reference "quay.io/openstack.kolla/fluentd:2024.1-ubuntu-jammy"` | Images of releases past their maintained phase are removed from quay.io; every release still there is built for Ubuntu 24.04 only | Use 2026.1 on Ubuntu 24.04 nodes ([upgrading existing 22.04 nodes](#upgrading-existing-ubuntu-2204-nodes)) |
| `prechecks`: *Kolla images from quay.io/openstack.kolla namespace are meant only for testing* | New guard in 2026.1 | `kolla_test_images: "yes"` in `globals.yml` |
| `prechecks` on `localhost`: *Ubuntu release jammy … is not supported* | The deploy VM is checked too | `prechecks_enable_host_os_checks=false` on `localhost` in the inventory |
| `bootstrap-servers`: `Get Docker API version` fails, `docker.sock` missing | Kolla masks `docker.service` before installing Docker and unmasks it only from the handler of a *changed* `/etc/docker/daemon.json`; a leftover identical file from a previous install keeps it masked | `sudo systemctl unmask docker && sudo systemctl enable --now docker`, then re-run |
| `deploy`, Glance: `Unexpected continuation line: '    fsid = …'` | Kolla merges `ceph.conf` with Python's INI parser: any indented line (tabs **or** spaces) is a continuation | `sed -i 's/^[[:space:]]\+//' /etc/kolla/config/*/ceph.conf` |
| No VIP / HAProxy never answers | `kolla_internal_vip_address` missing from `globals.yml` (it has no usable default) | Set it to a free management IP (`10.0.0.100`) |

Save the output of long runs to read the first error:
`kolla-ansible deploy -i inventory/multinode 2>&1 | tee ~/deploy.log`.

## Upgrading existing Ubuntu 22.04 nodes

If the OpenStack nodes were installed with 22.04, upgrade them in place
(one node at a time, take VM snapshots first):

```bash
ansible-playbook playbooks/os-upgrade-noble.yml -K
```

| Tag        | What it does |
|------------|--------------|
| *(always)* | Preflight: refuses a node with containers or Docker volumes (`kolla-ansible destroy` first), less than 6 GB free on `/`, or an OS other than jammy/noble; nodes already on noble are skipped |
| `prepare`  | Backs up apt sources to `/root/noble-upgrade/`, puts the archive sources in `/etc/apt/sources.list` (the only file the upgrader rewrites), purges Docker (packages, repo, `/etc/docker`), full jammy upgrade, reboot if required |
| `upgrade`  | `do-release-upgrade -f DistUpgradeViewNonInteractive`, keeping local config files (netplan, chrony, sshd, sudoers), then reboot |
| `verify`   | Noble running, `mgmt01`/`stor01`/`prov01` and their IPs present, chrony synced |

After it, `bootstrap-servers` installs the noble Docker packages.
