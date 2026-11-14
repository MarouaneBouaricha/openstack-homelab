# Netplan — source of truth

One file per VM. These files are the **source of truth** for host networking:
change them here first, commit, then apply them with the playbook.

Each NIC is matched by **MAC address** and renamed with `set-name`, so names
are meaningful and stable:

| Name     | Was     | Network                         | Hosts                  |
|----------|---------|---------------------------------|------------------------|
| `nat01`  | ens33   | VMware NAT — DHCP, default route + DNS | all              |
| `mgmt01` | ens37   | ① Management 10.0.0.0/24        | all                    |
| `prov01` | ens39   | ② Provider — up, **no IP**      | controller, computes   |
| `stor01` | ens38   | ③ Storage 10.0.2.0/24           | all except deploy      |

| Host       | nat01 | mgmt01    | prov01    | stor01    |
|------------|-------|-----------|-----------|-----------|
| deploy     | DHCP  | 10.0.0.10 | —         | —         |
| controller | DHCP  | 10.0.0.20 | up, no IP | 10.0.2.20 |
| compute01  | DHCP  | 10.0.0.30 | up, no IP | 10.0.2.30 |
| compute02  | DHCP  | 10.0.0.40 | up, no IP | 10.0.2.40 |
| ceph01     | DHCP  | 10.0.0.50 | —         | 10.0.2.50 |
| ceph02     | DHCP  | 10.0.0.60 | —         | 10.0.2.60 |
| ceph03     | DHCP  | 10.0.0.70 | —         | 10.0.2.70 |

VIP `10.0.0.100` is **not** configured here — keepalived (kolla) owns it.
Management and storage are static with no gateway; the default route comes
from `nat01`.

## Apply

From the repo root on the deploy VM:

```bash
ansible-playbook playbooks/preconfig.yml -K --tags netif
```

The `netif_rename` role, per host:

1. checks that every MAC in `netplan/<host>.yaml` exists on the VM (aborts otherwise)
2. moves any other `/etc/netplan/*.yaml` to `/etc/netplan.bak/`
3. installs the repo file as `/etc/netplan/01-homelab.yaml` (mode 0600)
4. runs `netplan generate`; on failure, restores the old files and stops
5. reboots (one node at a time) and checks the new names exist

The deploy VM is **not** rebooted by the playbook (it is running it) — reboot it
by hand when the run asks you to.

> If you replace a VM's NIC in VMware its MAC changes: update the MAC in the
> matching file here first, or the playbook will refuse to run on that host.
> The same goes for a **cloned** VM: its copied netplan still names the
> parent's MACs, so none of its NICs match and it boots without an IP. See
> "Adding a cloned VM" in the main README.
