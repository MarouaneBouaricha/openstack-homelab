# openstack-homelab

OpenStack homelab deployed with **[Kolla-Ansible](https://docs.openstack.org/kolla-ansible/latest/)**
on 7 VMs, with a 3-node **Ceph** cluster as the storage backend. This repo holds all configuration
and docs; it is the source of truth for the lab.

## Architecture

```mermaid
---
config:
  look: handDrawn
  theme: neutral
---
flowchart TB
    admin(["👤 Admin / Workstation"])
    internet(("🌐 Internet<br/>VMware NAT"))

    subgraph MGMT["① Management Network — 10.0.0.0/24"]
        direction LR
        deploy["🛠️ <b>deploy</b><br/>10.0.0.10<br/><i>kolla-ansible</i>"]
        vip(("VIP<br/>10.0.0.100"))
        controller["🧠 <b>controller</b><br/>10.0.0.20<br/><i>control · network · monitoring</i>"]
        compute01["⚙️ <b>compute01</b><br/>10.0.0.30<br/><i>nova-compute</i>"]
        compute02["⚙️ <b>compute02</b><br/>10.0.0.40<br/><i>nova-compute</i>"]
        ceph01["💾 <b>ceph01</b><br/>10.0.0.50<br/><i>mon · mgr · osd</i>"]
        ceph02["💾 <b>ceph02</b><br/>10.0.0.60<br/><i>mon · mgr · osd</i>"]
        ceph03["💾 <b>ceph03</b><br/>10.0.0.70<br/><i>mon · osd</i>"]
    end

    subgraph PROVIDER["② Provider Network — no IP (Neutron external)"]
        direction LR
        p_ctl["controller<br/>prov01"]
        p_c1["compute01<br/>prov01"]
        p_c2["compute02<br/>prov01"]
    end

    subgraph STORAGE["③ Storage Network — 10.0.2.0/24 (Ceph)"]
        direction LR
        s_ctl["controller<br/>10.0.2.20"]
        s_c1["compute01<br/>10.0.2.30"]
        s_c2["compute02<br/>10.0.2.40"]
        s_ceph01["ceph01<br/>10.0.2.50"]
        s_ceph02["ceph02<br/>10.0.2.60"]
        s_ceph03["ceph03<br/>10.0.2.70"]
    end

    admin -- "SSH / Horizon" --> vip
    deploy -. "ansible over SSH" .-> controller & compute01 & compute02 & ceph01 & ceph02 & ceph03
    vip -. "keepalived" .- controller

    controller --- p_ctl
    compute01 --- p_c1
    compute02 --- p_c2

    controller --- s_ctl
    compute01 --- s_c1
    compute02 --- s_c2
    ceph01 --- s_ceph01
    ceph02 --- s_ceph02
    ceph03 --- s_ceph03
    s_ctl & s_c1 & s_c2 == "RBD" ==> s_ceph01 & s_ceph02 & s_ceph03

    MGMT -. "nat01 · DHCP" .-> internet

    classDef vipStyle stroke:#e03131,color:#e03131,stroke-width:2px
    class vip vipStyle
```

## Hosts

| Host       | Role                              | Management (①) | Storage (③) |
|------------|-----------------------------------|----------------|-------------|
| deploy     | Kolla-Ansible deployment node     | 10.0.0.10      | —           |
| controller | Control plane, Neutron, monitoring | 10.0.0.20      | 10.0.2.20   |
| compute01  | Nova compute (hypervisor)         | 10.0.0.30      | 10.0.2.30   |
| compute02  | Nova compute (hypervisor)         | 10.0.0.40      | 10.0.2.40   |
| ceph01     | Ceph node (Glance/Cinder/Nova)    | 10.0.0.50      | 10.0.2.50   |
| ceph02     | Ceph node (clone of ceph01)       | 10.0.0.60      | 10.0.2.60   |
| ceph03     | Ceph node (clone of ceph01)       | 10.0.0.70      | 10.0.2.70   |
| **VIP**    | `kolla_internal_vip_address`      | **10.0.0.100** | —           |

## Networks

| # | Name       | CIDR          | Purpose                                                     |
|---|------------|---------------|-------------------------------------------------------------|
| —  | NAT        | DHCP (VMware) | Internet access, default route + DNS (`nat01`)              |
| ① | Management | 10.0.0.0/24   | SSH, Ansible, OpenStack APIs, internal VIP (`network_interface`, `mgmt01`) |
| ② | Provider   | no IP         | Neutron external network (`neutron_external_interface`, `prov01`) on controller/computes |
| ③ | Storage    | 10.0.2.0/24   | Ceph client/public traffic (`storage_interface`, `stor01`)    |

## Repository layout

```
.
├── ansible.cfg          # points at inventory/hosts.yml
├── inventory/
│   ├── hosts.yml        # all VMs by name, grouped by role (mgmt_ip / storage_ip)
│   ├── group_vars/      # shared vars (networks, interfaces, VIP)
│   └── host_vars/       # per-host overrides
├── netplan/             # per-VM netplan — source of truth for host networking
└── playbooks/
    ├── preconfig.yml    # node prep: hosts, NIC names, time sync (tags below)
    └── roles/           # clone_identity, etc_hosts, ssh_client, netif_rename, chrony
```

## Quick start

On the deploy VM (`opadm@10.0.0.10`), Ansible lives in a virtualenv:

```bash
source ~/venv/bin/activate
cd ~/openstack-homelab
ansible-playbook playbooks/preconfig.yml -K   # node prep (idempotent)
ansible all -m ping
```

`preconfig.yml` runs in three tagged parts (`--tags hosts|netif|ntp`):

| Tag     | What it does |
|---------|--------------|
| `hosts` | On cloned VMs, regenerates `/etc/machine-id` and the SSH host keys (only on a host whose machine-id matches an earlier host's; also `--tags clone`). Sets hostnames and writes every node into `/etc/hosts` (`10.0.0.10 deployment deploy`, `10.0.0.20 controller`, …); drops the `127.0.1.1` line. On the deploy VM, trusts host keys by name and adds `~/.ssh/config`, so `ssh controller` works. |
| `netif` | Renames NICs by MAC to `nat01` / `mgmt01` / `stor01` / `prov01` from [netplan/](netplan/README.md). Reboots nodes one at a time; reboot the deploy VM yourself afterwards. |
| `ntp`   | Installs chrony. The deploy VM syncs from the internet and serves `10.0.0.0/24`, with `local stratum 10` as a fallback; every other node uses only `deployment`, so the nodes stay within Ceph's 0.05 s clock-skew limit. Time zone: UTC. |

Plays that need root set `become: true` themselves; pass `-K` for the sudo
password.

## Adding a cloned VM

A clone starts with its parent's netplan, MACs and identity, so it comes up
with no management IP. Example: ceph02/ceph03, cloned from ceph01.

1. **VM powered off, in VMware:** the NAT adapter of these VMs has a *static*
   MAC, which cloning copies. Give the clone its own: *VM Settings → Network
   Adapter (NAT) → Advanced → MAC Address* (ceph02 `00:50:56:28:6C:E3`,
   ceph03 `00:50:56:28:6C:E2`). The other adapters get new generated MACs.
2. **In the repo:** add the host to `inventory/hosts.yml` and write
   `netplan/<host>.yaml` with the MACs from the VM's `.vmx` file
   (`ethernet0.address`, `ethernet1/2.generatedAddress`).
3. **On the clone's VMware console**, give the management NIC a temporary IP
   (gone at the next reboot):
   ```bash
   sudo ip addr add 10.0.0.60/24 dev ens37 && sudo ip link set ens37 up
   ```
4. **On the deploy VM**, run the whole playbook *without* `--limit` (the clone
   check compares machine-ids across hosts):
   ```bash
   ansible-playbook playbooks/preconfig.yml -K
   ```
   The clone keeps the deploy VM's SSH key from its parent, so Ansible gets in;
   the run then gives it a new identity, its hostname, its own netplan
   (reboot), and time sync.

