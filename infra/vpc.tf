locals {
  edge_instance_type = "t3a.nano"
  node_instance_type = "t3a.medium"

  # The address plan starts here: subnets are /24s carved from it (here and in
  # kubernetes.tf), and nat.sh masquerades it
  vpc_cidr = "10.0.0.0/16"

  # AZs offering both instance types, in a stable order: [0] is the edge's, nodes pick theirs in kubernetes.tf
  azs = sort(tolist(setintersection([
    for offering in data.aws_ec2_instance_type_offerings.lab : toset(offering.locations)
  ]...)))
}

data "aws_ec2_instance_type_offerings" "lab" {
  for_each      = toset([local.edge_instance_type, local.node_instance_type])
  location_type = "availability-zone"
  filter {
    name   = "instance-type"
    values = [each.key]
  }
}

resource "aws_vpc" "lab" {
  cidr_block           = local.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "cks-lab-vpc" }

  lifecycle {
    precondition {
      condition     = length(local.azs) >= 3
      error_message = "This lab needs 3 AZs offering ${local.node_instance_type} and ${local.edge_instance_type}; ${var.region} has ${length(local.azs)}. Pick another region."
    }
  }
}

resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id
  tags   = { Name = "cks-lab-igw" }
}

# --- Public subnet: edge instance (bastion + NAT) only ---
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.lab.id
  cidr_block              = cidrsubnet(local.vpc_cidr, 8, 1) # 10.0.1.0/24
  availability_zone       = local.azs[0]
  map_public_ip_on_launch = true
  tags                    = { Name = "cks-lab-public" }

  lifecycle {
    ignore_changes = [availability_zone]
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.lab.id
  tags   = { Name = "cks-lab-public-rt" }
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.lab.id
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# --- Private subnets: one per node (local.nodes), no public IPs ---
resource "aws_subnet" "private" {
  for_each                = { for node in local.nodes : node.subnet => node }
  vpc_id                  = aws_vpc.lab.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = false
  tags                    = { Name = "cks-lab-private-${each.key}" }

  lifecycle {
    ignore_changes = [availability_zone]
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.lab.id
  tags   = { Name = "cks-lab-private-rt" }
}

# Egress via the edge instance acting as a NAT (no NAT Gateway)
resource "aws_route" "private_default" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.edge.primary_network_interface_id
}

resource "aws_route_table_association" "private" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}
