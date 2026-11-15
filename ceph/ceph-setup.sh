#!/usr/bin/env bash
# =============================================================================
# Ceph cluster setup — the steps used to build the lab's 3-node cluster
# (ceph01, ceph02, ceph03) with cephadm. See ceph/README.md for the why.
#
# This is a RUNBOOK, not an unattended script: run each step by hand, as root,
# on the host named in its header, and check the output before moving on.
# Running the file as a whole exits immediately.
#
# Every `ceph ...` / `rbd ...` command below works directly on ceph01 as root
# (ceph-common is installed and bootstrap wrote /etc/ceph/ceph.conf plus the
# admin keyring), or inside `cephadm shell`.
# =============================================================================
echo "ceph/ceph-setup.sh is a runbook: copy the steps one at a time (see ceph/README.md)." >&2
exit 1

# -----------------------------------------------------------------------------
# 0. Prerequisites — all 3 Ceph nodes          (now: Ansible, from deploy VM)
# -----------------------------------------------------------------------------
# Replaced by:  ansible-playbook playbooks/ceph-prereqs.yml -K
# What it does, by hand, on each node:
apt update && apt upgrade -y
apt install -y curl wget gnupg lsb-release ca-certificates chrony lvm2 vim \
    net-tools software-properties-common python3
apt install -y docker.io
systemctl enable --now docker
# Do NOT install systemd-timesyncd: it conflicts with chrony and removes it.

# Ceph repo (signed-by keyring; apt-key is deprecated) + cephadm, Ubuntu 22.04
install -d -m 0755 /etc/apt/keyrings
wget -qO /etc/apt/keyrings/ceph.asc https://download.ceph.com/keys/release.asc
echo "deb [signed-by=/etc/apt/keyrings/ceph.asc] https://download.ceph.com/debian-squid/ $(lsb_release -sc) main" \
    > /etc/apt/sources.list.d/ceph.list
apt update
apt install -y cephadm ceph-common
cephadm version

lsblk     # the OSD disks (nvme1n1, nvme2n1) must be empty: no partitions, no LVM

# -----------------------------------------------------------------------------
# 1. Bootstrap the cluster — ceph01
# -----------------------------------------------------------------------------
# First MON + MGR on ceph01. Public and cluster traffic both on the storage
# network (10.0.2.0/24). Dashboard: https://ceph01:8443 (admin / below).
cephadm bootstrap \
    --mon-ip 10.0.2.50 \
    --cluster-network 10.0.2.0/24 \
    --initial-dashboard-user admin \
    --initial-dashboard-password 'opensesame!@#' \
    --dashboard-password-noupdate \
    --allow-fqdn-hostname

cephadm shell          # optional: containerized CLI; `ceph` also works on the host
ceph -s
ceph health detail
ceph orch status

# -----------------------------------------------------------------------------
# 2. cephadm SSH key to the other nodes        (now: Ansible, from deploy VM)
# -----------------------------------------------------------------------------
# cephadm manages every host over SSH as root, with the cluster key from
# bootstrap (/etc/ceph/ceph.pub). Root has no password on Ubuntu, so the
# original `ssh-copy-id -f -i /etc/ceph/ceph.pub root@ceph02` can't log in.
# Replaced by:  ansible-playbook playbooks/ceph-ssh.yml -K
# (installs the key for root on every Ceph node, then runs
#  `ceph cephadm check-host` for each one from ceph01)

# -----------------------------------------------------------------------------
# 3. Add hosts, place MONs and MGRs — ceph01
# -----------------------------------------------------------------------------
# The name must match the node's hostname; the address is its storage IP.
ceph orch host add ceph02 10.0.2.60
ceph orch host add ceph03 10.0.2.70
ceph orch host ls

# 3 MONs (quorum survives one node down), 2 MGRs (active + standby)
ceph orch apply mon --placement="ceph01,ceph02,ceph03"
ceph orch apply mgr --placement="ceph01,ceph02"
ceph mon stat

# -----------------------------------------------------------------------------
# 4. OSDs — ceph01                                       (pick ONE option)
# -----------------------------------------------------------------------------
ceph orch device ls        # disks must show AVAILABLE = Yes

# Option A — every empty disk on every host, now and in the future
ceph orch apply osd --all-available-devices

# Option B — explicit disks, 2 per node
ceph orch daemon add osd ceph01:/dev/nvme1n1
ceph orch daemon add osd ceph01:/dev/nvme2n1
ceph orch daemon add osd ceph02:/dev/nvme1n1
ceph orch daemon add osd ceph02:/dev/nvme2n1
ceph orch daemon add osd ceph03:/dev/nvme1n1
ceph orch daemon add osd ceph03:/dev/nvme2n1

ceph osd tree && ceph -s && ceph df

# -----------------------------------------------------------------------------
# 5. RBD pools for OpenStack — ceph01
# -----------------------------------------------------------------------------
#   images  -> Glance     volumes -> Cinder     vms -> Nova ephemeral disks
# 32 PGs to start; the PG autoscaler adjusts them as data grows.
ceph osd pool create images 32
ceph osd pool create volumes 32
ceph osd pool create vms 32

# 3 copies, one per node; I/O keeps going with 2 (one node down)
ceph osd pool set images size 3
ceph osd pool set volumes size 3
ceph osd pool set vms size 3
ceph osd pool set images min_size 2
ceph osd pool set volumes min_size 2
ceph osd pool set vms min_size 2

# Tag the pools for RBD and initialize them
ceph osd pool application enable images rbd
ceph osd pool application enable volumes rbd
ceph osd pool application enable vms rbd
rbd pool init images
rbd pool init volumes
rbd pool init vms

ceph osd pool ls detail
ceph osd pool autoscale-status

# -----------------------------------------------------------------------------
# 6. CephX users for OpenStack — ceph01
# -----------------------------------------------------------------------------
# Glance: read/write on images only
ceph auth get-or-create client.glance \
    mon 'profile rbd' \
    osd 'profile rbd pool=images' \
    mgr 'profile rbd pool=images'
ceph auth get client.glance -o /etc/ceph/ceph.client.glance.keyring

# Cinder (also used by Nova): read/write on volumes + vms, read-only on images
# (copy-on-write clones of Glance images)
ceph auth get-or-create client.cinder \
    mon 'profile rbd' \
    osd 'profile rbd pool=volumes, profile rbd pool=vms, profile rbd-read-only pool=images' \
    mgr 'profile rbd pool=volumes, profile rbd pool=vms'
ceph auth get client.cinder -o /etc/ceph/ceph.client.cinder.keyring

ceph auth ls | grep client.

# -----------------------------------------------------------------------------
# 7. Client config for Kolla-Ansible — ceph01
# -----------------------------------------------------------------------------
# Minimal ceph.conf (fsid + mon addresses) for the OpenStack services.
# Kolla's config merge breaks on tab-indented lines, so tabs become spaces.
ceph config generate-minimal-conf > /tmp/ceph.conf
sed -i 's/\t/    /g' /tmp/ceph.conf
ceph fsid
# Next: copy /tmp/ceph.conf and the glance/cinder keyrings to the deploy VM,
# under /etc/kolla/config/ (see ceph/README.md).
