#!/bin/bash
set -euxo pipefail
# Rendered by templatefile (vpc_cidr comes from vpc.tf)

echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-nat.conf
sysctl -p /etc/sysctl.d/99-nat.conf

# Masquerade VPC traffic leaving the VPC. Matching on the CIDR, not the interface, means no
# waiting for the default route. The unit re-adds the rule on every boot (-C keeps it single)
cat <<'UNIT' > /etc/systemd/system/lab-nat.service
[Unit]
Description=Lab NAT masquerade

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'iptables -t nat -C POSTROUTING -s ${vpc_cidr} ! -d ${vpc_cidr} -j MASQUERADE || iptables -t nat -A POSTROUTING -s ${vpc_cidr} ! -d ${vpc_cidr} -j MASQUERADE'

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now lab-nat.service
