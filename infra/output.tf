output "node_private_ips" {
  description = "Each node's static private IP"
  value       = { for name, node in aws_instance.node : name => node.private_ip }
}

# The rest is used by lab-start.sh and lab-stop.sh, so they never depend on the CLI's default region or tag lookups
output "region" {
  description = "Region the lab runs in"
  value       = var.region
}

output "instance_ids" {
  description = "Space-separated, for the AWS CLI. The edge comes first: lab-start.sh reads its public IP"
  value       = join(" ", concat([aws_instance.edge.id], [for node in aws_instance.node : node.id]))
}

output "k8s_version" {
  description = "Kubernetes version a fresh build installs; cluster-init.sh passes it to kubeadm init"
  value       = "${var.k8s_minor}.${var.k8s_patch}"
}

output "node_hosts" {
  description = "One \"name ip jump\" line per node, for the ssh_config that lab-start.sh writes"
  value       = join("\n", [for name, node in aws_instance.node : "${name} ${node.private_ip} ${local.nodes[name].jump}"])
}
