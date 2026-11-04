# An SG's name and description are fixed: changing either replaces the SG, and the replacement
# can't be created while the old one still holds the name or is attached. Change rules instead;
# each is a separate resource that changes in place. Rules are never written inline
# (ingress/egress blocks): mixing them with rule resources on one SG makes them overwrite each other

resource "aws_security_group" "edge" {
  name        = "cks-edge"
  description = "Edge: SSH from your laptop, NAT for the private subnets"
  vpc_id      = aws_vpc.lab.id
  tags        = { Name = "cks-edge" }
}

resource "aws_vpc_security_group_ingress_rule" "edge_ssh" {
  security_group_id = aws_security_group.edge.id
  description       = "SSH from your laptop only"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = var.my_ip_cidr
}

# The NAT path: everything the private nodes send out arrives here first (Post 5 narrows this)
resource "aws_vpc_security_group_ingress_rule" "edge_nat" {
  for_each          = aws_subnet.private
  security_group_id = aws_security_group.edge.id
  description       = "Forwarded traffic from private nodes (NAT)"
  ip_protocol       = "-1"
  cidr_ipv4         = each.value.cidr_block
}

resource "aws_vpc_security_group_egress_rule" "edge_all" {
  security_group_id = aws_security_group.edge.id
  description       = "All outbound (SSH hops, NAT-forwarded traffic, updates)"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# --- Node security groups ---
# The control-plane and worker SGs reference each other, so inline rules would form a cycle

resource "aws_security_group" "control_plane" {
  name        = "cks-control-plane"
  description = "Control plane node"
  vpc_id      = aws_vpc.lab.id
  tags        = { Name = "cks-control-plane" }
}

resource "aws_security_group" "worker" {
  name        = "cks-worker"
  description = "Worker node"
  vpc_id      = aws_vpc.lab.id
  tags        = { Name = "cks-worker" }
}

# Control plane: SSH from the edge instance only
resource "aws_vpc_security_group_ingress_rule" "control_plane_ssh_from_edge" {
  security_group_id            = aws_security_group.control_plane.id
  description                  = "SSH from edge instance"
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
  referenced_security_group_id = aws_security_group.edge.id
}

# Node to node: the kubeadm and Cilium ports only (Kubernetes "Ports and Protocols", Cilium
# "Firewall Rules"; NodePorts are a separate rule below). The worker accepts nothing from the
# edge instance, and SSH only from the control plane (the ProxyJump hop). ICMP -1 means all
# types (Cilium health pings)
locals {
  control_plane = aws_security_group.control_plane.id
  worker        = aws_security_group.worker.id

  node_ingress = {
    control_plane_api    = { sg = local.control_plane, peer = local.worker, proto = "tcp", port = 6443, desc = "API server (kubelet, Cilium)" }
    control_plane_vxlan  = { sg = local.control_plane, peer = local.worker, proto = "udp", port = 8472, desc = "Cilium VXLAN" }
    control_plane_health = { sg = local.control_plane, peer = local.worker, proto = "tcp", port = 4240, desc = "Cilium health" }
    control_plane_hubble = { sg = local.control_plane, peer = local.worker, proto = "tcp", port = 4244, desc = "Hubble" }
    control_plane_icmp   = { sg = local.control_plane, peer = local.worker, proto = "icmp", port = -1, desc = "Cilium health ping" }
    worker_ssh           = { sg = local.worker, peer = local.control_plane, proto = "tcp", port = 22, desc = "SSH from control plane (ProxyJump)" }
    worker_kubelet       = { sg = local.worker, peer = local.control_plane, proto = "tcp", port = 10250, desc = "kubelet API" }
    worker_vxlan         = { sg = local.worker, peer = local.control_plane, proto = "udp", port = 8472, desc = "Cilium VXLAN" }
    worker_health        = { sg = local.worker, peer = local.control_plane, proto = "tcp", port = 4240, desc = "Cilium health" }
    worker_hubble        = { sg = local.worker, peer = local.control_plane, proto = "tcp", port = 4244, desc = "Hubble" }
    worker_icmp          = { sg = local.worker, peer = local.control_plane, proto = "icmp", port = -1, desc = "Cilium health ping" }
  }
}

resource "aws_vpc_security_group_ingress_rule" "node" {
  for_each                     = local.node_ingress
  security_group_id            = each.value.sg
  referenced_security_group_id = each.value.peer
  description                  = each.value.desc
  ip_protocol                  = each.value.proto
  from_port                    = each.value.port
  to_port                      = each.value.port
}

# NodePort Services (30000-32767) on each node, from the other node only
resource "aws_vpc_security_group_ingress_rule" "nodeport" {
  for_each                     = { control_plane = [local.control_plane, local.worker], worker = [local.worker, local.control_plane] }
  security_group_id            = each.value[0]
  referenced_security_group_id = each.value[1]
  description                  = "NodePort Services"
  ip_protocol                  = "tcp"
  from_port                    = 30000
  to_port                      = 32767
}

# Both nodes: outbound anywhere (goes out through the edge instance)
resource "aws_vpc_security_group_egress_rule" "node_egress" {
  for_each = {
    control_plane = aws_security_group.control_plane.id
    worker        = aws_security_group.worker.id
  }
  security_group_id = each.value
  description       = "All outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# The VPC's default SG allows all traffic between its members. Nothing uses it; this strips its rules
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.lab.id
  tags   = { Name = "cks-lab-default-unused" }
}
