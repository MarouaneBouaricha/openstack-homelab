# Netplan — source of truth

One file per VM. These files are the **source of truth** for host networking:
change them here first, commit, then push them to the host.

| Host       | ens33 · NAT (DHCP) | ens37 · Management (10.0.0.0/24) | ens38 · Storage (10.0.2.0/24) | ens39 · Provider (no IP) |
|------------|--------------------|----------------------------------|-------------------------------|--------------------------|
| deploy     | DHCP               | 10.0.0.10                        | —                             | —                        |
| controller | DHCP               | 10.0.0.20                        | 10.0.2.20                     | up, no IP                |
| compute01  | DHCP               | 10.0.0.30                        | 10.0.2.30                     | up, no IP                |
| compute02  | DHCP               | 10.0.0.40                        | 10.0.2.40                     | up, no IP                |
| ceph       | DHCP               | 10.0.0.50                        | 10.0.2.50                     | —                        |

VIP `10.0.0.100` is **not** configured here — keepalived (kolla) owns it.

> The NAT interface (VMware Workstation NAT) gets its address, default route and
> DNS over DHCP. Management and storage are static with no gateway.
> ⚠️ The NAT NIC is assumed to be `ens33` and the new provider NIC `ens39` (VMware's default first NIC) — check with `ip -br link`.

## Apply

```bash
scp netplan/controller.yaml controller:/tmp/
ssh controller 'sudo install -m 600 /tmp/controller.yaml /etc/netplan/50-cloud-init.yaml && sudo netplan try'
```

`netplan try` rolls back automatically after 120 s if you lose connectivity.
If cloud-init manages networking, disable it first:

```bash
echo 'network: {config: disabled}' | sudo tee /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
```
