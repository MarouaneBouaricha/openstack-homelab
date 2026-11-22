# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Configuration and docs for an OpenStack homelab (Kolla-Ansible on 7 VMware VMs, 3-node cephadm Ceph as the
storage backend). It is the source of truth for the lab: Ansible playbooks/roles, inventories, per-VM netplan,
and the Ceph runbook. There is no application code, build, or test suite.

## Where things run

- This checkout is the **workstation** (Windows). Edit and commit here; nothing is executed against the lab from here.
- Playbooks run on the **deploy VM** (`opadm@10.0.0.10`, `~/openstack-homelab`, Ansible in `~/venv`).
  `git push` updates both GitHub and the deploy VM (origin has two push URLs; the VM repo uses
  `receive.denyCurrentBranch=updateInstead`). `git push deploy` updates only the VM.
- Never expect edits made on the deploy VM: a dirty working tree there makes the push fail.

## Commands (on the deploy VM, from the repo root)

```bash
source ~/venv/bin/activate
ansible-playbook playbooks/preconfig.yml -K                  # all node prep (tags: sudo|hosts|netif|ntp, also clone)
ansible-playbook playbooks/preconfig.yml -K --tags ntp       # one part
ansible-playbook playbooks/ceph-prereqs.yml -K [-e ceph_release=tentacle] [--skip-tags reboot]
ansible-playbook playbooks/ceph-ssh.yml -K                   # after cephadm bootstrap on ceph01
ansible-playbook <playbook> --syntax-check                   # quick validation
ansible all -m ping
```

`-K` is needed because plays set `become: true` themselves. No linter is configured.

## Architecture

- **Two kinds of inventory.** `inventory/hosts.yml` (YAML, set as default in `ansible.cfg`) is this repo's
  inventory: hosts by name with `mgmt_ip` / `storage_ip`, groups `deployment`, `openstack` (`control`, `network`,
  `compute`, `monitoring`) and `ceph_nodes`. `all-in-one` and `inventory/multinode` are **Kolla-Ansible's** INI
  inventories (tracked, but used by kolla-ansible, not by these playbooks). Keep host/IP changes consistent across them.
- **Hosts are reached by name**, not `ansible_host`: the `etc_hosts` role writes every node into `/etc/hosts`. The
  deploy VM is `ansible_connection: local`; its real hostname is `deployment` (`node_hostname` in `host_vars/deploy.yml`),
  `deploy` being an alias.
- **Variables:** `group_vars/all.yml` holds networks, the renamed interface names (`nat01`, `mgmt01`, `stor01`,
  `prov01`) and Kolla vars (`kolla_internal_vip_address` 10.0.0.100, `network_interface`, `neutron_external_interface`).
  Hosts lacking a NIC null it out (`ceph_nodes.yml`, `host_vars/deploy.yml`).
- **Netplan is the source of truth for networking.** `netplan/<inventory_hostname>.yaml` matches NICs by MAC and
  renames them with `set-name`; the `netif_rename` role installs it as `/etc/netplan/01-homelab.yaml`, aborting if any
  MAC is missing on the VM. A new host therefore needs both an inventory entry and a netplan file with its real MACs.
- **Roles** live in `playbooks/roles/` (resolved relative to the playbooks) with defaults in `defaults/main.yml`.
- **Rolling/ordering constraints worth preserving:** reboots (`netif`, ceph `reboot`) run `serial: 1`; the deploy VM is
  never rebooted by a playbook (`netif_reboot: false`) because it runs Ansible; `sudo` runs first in `preconfig.yml`;
  chrony makes the deploy VM the only time source for other nodes (Ceph clock-skew limit).
- **Cloned VMs** (ceph02/ceph03 from ceph01): `clone_identity` detects duplicate machine-ids by comparing across hosts,
  so `preconfig.yml` must run without `--limit` for it to work.
- **Kolla release:** 2026.1 (kolla-ansible 22.x, `~/venv-2026.1` on the deploy VM, Python 3.12); OpenStack nodes
  must be Ubuntu 24.04 (`playbooks/os-upgrade-noble.yml`), Ceph nodes stay on 22.04. `/etc/kolla/globals.yml` and
  `passwords.yml` live only on the deploy VM, not in this repo.
- **Ceph cluster build** is manual: `ceph/ceph-setup.sh` is a runbook copied step by step (it `exit 1`s if run), with
  the explanation in `ceph/README.md`. Ceph public and cluster traffic both use the storage network 10.0.2.0/24.

## Conventions

- Each playbook starts with a `# ===` header block listing its tags and example run commands; the README has a matching
  per-tag table. When adding or changing a tag/role, update the header, `README.md` (and `ceph/README.md` or
  `netplan/README.md` where relevant) together.
- Commit messages: short imperative summary (e.g. "Add passwordless sudo role to preconfig (sudo tag)").
