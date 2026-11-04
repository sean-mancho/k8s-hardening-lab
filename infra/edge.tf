locals {
  edge_user_data = templatefile("${path.module}/scripts/nat.sh", { vpc_cidr = local.vpc_cidr })
}

resource "aws_instance" "edge" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = local.edge_instance_type
  subnet_id              = aws_subnet.public.id
  key_name               = aws_key_pair.lab.key_name
  vpc_security_group_ids = [aws_security_group.edge.id]
  source_dest_check      = false # required to act as a NAT
  user_data              = local.edge_user_data

  # Unlimited: T3a gets no launch credits in standard mode, which slows the first boot. Credits
  # above the baseline bill per vCPU-hour; forwarding packets rarely gets there, so expect cents
  credit_specification { cpu_credits = "unlimited" }
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 8
    encrypted   = true
  }

  # To apply an edited nat.sh, rebuild the edge (infra/README.md, "Rebuild one instance"). Run
  # from the repo root; with LAB_SSH_KEY set, also pass
  # -var="ssh_public_key_path=$LAB_SSH_KEY.pub" or every instance is replaced:
  #   tofu -chdir=infra apply -replace=aws_instance.edge \
  #     -var="my_ip_cidr=$(curl -fsS https://checkip.amazonaws.com)/32"
  lifecycle {
    ignore_changes = [ami, user_data]
  }

  tags = { Name = "k8s-edge" } # Project comes from the provider default_tags
}
