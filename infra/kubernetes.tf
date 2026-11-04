locals {
  # Each node gets its own private subnet (vpc.tf) in its own AZ. host is the IP's last octet
  # (10.0.2.10 and 10.0.3.11), subnet the private subnet's key, jump the host ssh hops through
  # (it must match the SSH rules in security.tf)
  nodes = {
    "k8s-control-plane" = {
      subnet = "control-plane"
      cidr   = cidrsubnet(local.vpc_cidr, 8, 2) # 10.0.2.0/24
      host   = 10
      az     = local.azs[1]
      sg     = aws_security_group.control_plane.id
      jump   = "k8s-edge"
    }
    "k8s-worker" = {
      subnet = "worker"
      cidr   = cidrsubnet(local.vpc_cidr, 8, 3) # 10.0.3.0/24
      host   = 11
      az     = local.azs[2]
      sg     = aws_security_group.worker.id
      jump   = "k8s-control-plane"
    }
  }
  node_ips = { for name, node in local.nodes : name => cidrhost(node.cidr, node.host) }

  node_user_data = {
    for name in keys(local.nodes) : name => templatefile("${path.module}/scripts/node.sh", {
      k8s_minor = var.k8s_minor
      k8s_patch = var.k8s_patch
      hostname  = name
      hosts     = local.node_ips
    })
  }
}

resource "aws_instance" "node" {
  for_each               = local.nodes
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = local.node_instance_type
  subnet_id              = aws_subnet.private[each.value.subnet].id
  private_ip             = local.node_ips[each.key]
  key_name               = aws_key_pair.lab.key_name
  vpc_security_group_ids = [each.value.sg]
  user_data              = local.node_user_data[each.key]

  credit_specification { cpu_credits = "standard" }
  # Hop limit 1: IMDS answers the node itself, not ordinary pods; hostNetwork pods still reach it (Post 5)
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 20
    encrypted   = true
  }

  # New Ubuntu images and k8s_minor changes must not replace nodes; upgrades go through kubeadm (Post 4).
  # To apply an edited node.sh, rebuild a node (infra/README.md, "Rebuild one instance"). Run
  # from the repo root; with LAB_SSH_KEY set, also pass
  # -var="ssh_public_key_path=$LAB_SSH_KEY.pub" or every instance is replaced:
  #   tofu -chdir=infra apply -replace='aws_instance.node["k8s-worker"]' \
  #     -var="my_ip_cidr=$(curl -fsS https://checkip.amazonaws.com)/32"
  lifecycle {
    ignore_changes = [ami, user_data]
  }

  # Nodes need the NAT path for first-boot package installs. Without the private route table
  # association, a node can boot on the VPC's main route table, which has no default route
  depends_on = [aws_route.private_default, aws_route_table_association.private]

  tags = { Name = each.key }
}

# ignore_changes keeps edited boot scripts out of the plan, so edits wait for the next rebuild.
# The state holds the user_data each instance was built with; a mismatch is a warning
locals {
  stale_boot_scripts = concat(
    aws_instance.edge.user_data == local.edge_user_data ? [] : ["k8s-edge (nat.sh)"],
    [for name, node in aws_instance.node : "${name} (node.sh)" if node.user_data != local.node_user_data[name]]
  )
}

check "boot_scripts_applied" {
  assert {
    condition     = length(local.stale_boot_scripts) == 0
    error_message = "Changed after these instances were built, so not applied: ${join(", ", local.stale_boot_scripts)}. To apply, rebuild with -replace (comments in edge.tf and kubernetes.tf)."
  }
}
