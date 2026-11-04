# A different public key means a new key pair, which replaces all three instances (and the cluster on them)
resource "aws_key_pair" "lab" {
  key_name_prefix = "cks-lab-" # a fixed name clashes with any existing pair called cks-lab
  public_key      = file(pathexpand(var.ssh_public_key_path))
  tags            = { Name = "cks-lab" }
}
