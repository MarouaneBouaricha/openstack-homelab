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
        p_ctl["controller<br/>ens39"]
        p_c1["compute01<br/>ens39"]
        p_c2["compute02<br/>ens39"]
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

    MGMT -. "ens33 · DHCP" .-> internet

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
| —  | NAT        | DHCP (VMware) | Internet access, default route + DNS (`ens33`)              |
| ① | Management | 10.0.0.0/24   | SSH, Ansible, OpenStack APIs, internal VIP (`network_interface`, `ens37`) |
| ② | Provider   | no IP         | Neutron external network (`neutron_external_interface`) `ens39` on controller/computes |
| ③ | Storage    | 10.0.2.0/24   | Ceph client/public traffic (`storage_interface`, `ens38`)    |

## Repository layout

```
.
├── ansible.cfg          # points at inventory/hosts.yml
├── inventory/
│   ├── hosts.yml        # all VMs, grouped by role
│   ├── group_vars/      # shared vars (networks, interfaces, VIP)
│   └── host_vars/       # per-host overrides
└── netplan/             # per-VM netplan — source of truth for host networking
```

## Quick start

```bash
ansible all -m ping          # from the deploy node, repo root
```

See [netplan/README.md](netplan/README.md) to apply network configs.
