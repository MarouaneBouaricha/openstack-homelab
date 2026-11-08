# openstack-homelab

OpenStack homelab deployed with **[Kolla-Ansible](https://docs.openstack.org/kolla-ansible/latest/)**
on 5 VMs, with **Ceph** as the storage backend. This repo holds all configuration
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
        ceph["💾 <b>ceph</b><br/>10.0.0.50<br/><i>mon · mgr · osd</i>"]
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
        s_ceph["ceph<br/>10.0.2.50"]
    end

    admin -- "SSH / Horizon" --> vip
    deploy -. "ansible over SSH" .-> controller & compute01 & compute02 & ceph
    vip -. "keepalived" .- controller

    controller --- p_ctl
    compute01 --- p_c1
    compute02 --- p_c2

    controller --- s_ctl
    compute01 --- s_c1
    compute02 --- s_c2
    ceph --- s_ceph
    s_ctl & s_c1 & s_c2 == "RBD" ==> s_ceph

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
| ceph       | Ceph cluster (Glance/Cinder/Nova) | 10.0.0.50      | 10.0.2.50   |
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
    └── roles/           # etc_hosts, ssh_client, netif_rename, chrony
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
| `hosts` | Sets hostnames and writes every node into `/etc/hosts` (`10.0.0.10 deployment deploy`, `10.0.0.20 controller`, …); drops the `127.0.1.1` line. On the deploy VM, trusts host keys by name and adds `~/.ssh/config`, so `ssh controller` works. |
| `netif` | Renames NICs by MAC to `nat01` / `mgmt01` / `stor01` / `prov01` from [netplan/](netplan/README.md). Reboots nodes one at a time; reboot the deploy VM yourself afterwards. |
| `ntp`   | Installs chrony. The deploy VM syncs from the internet and serves `10.0.0.0/24`, with `local stratum 10` as a fallback; every other node uses only `deployment`, so the nodes stay within Ceph's 0.05 s clock-skew limit. Time zone: UTC. |

Plays that need root set `become: true` themselves; pass `-K` for the sudo
password.
