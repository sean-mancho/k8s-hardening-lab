variable "region" {
  description = "AWS region for the lab"
  type        = string
  default     = "us-east-1"
}

variable "my_ip_cidr" {
  description = "Your laptop's public IP as /32, e.g. 203.0.113.7/32"
  type        = string

  validation {
    # The regex rules out IPv6 /32s (a huge range); cidrhost rules out octets above 255
    condition     = can(regex("^[0-9]{1,3}(\\.[0-9]{1,3}){3}/32$", var.my_ip_cidr)) && can(cidrhost(var.my_ip_cidr, 0)) && var.my_ip_cidr != "0.0.0.0/32"
    error_message = "my_ip_cidr must be a single IPv4 address as /32, e.g. 203.0.113.7/32. Never 0.0.0.0/0."
  }
}

variable "k8s_minor" {
  description = "Kubernetes minor version to install, matching the CKS exam (v1.35 as of Nov 2026; see the LF exam FAQ). Post 4 upgrades the cluster past it with kubeadm"
  type        = string
  default     = "1.35"

  validation {
    condition     = can(regex("^1\\.[0-9]+$", var.k8s_minor))
    error_message = "k8s_minor is a minor version like 1.35 (no patch, no leading v)."
  }
}

variable "k8s_patch" {
  description = "Patch release a fresh build installs (k8s_minor.k8s_patch, e.g. 1.35.9), so every rebuild gets the same packages. Change it together with k8s_minor"
  type        = string
  default     = "9"

  validation {
    condition     = can(regex("^[0-9]+$", var.k8s_patch))
    error_message = "k8s_patch is the patch number only, like 9 for 1.35.9."
  }
}

variable "ssh_public_key_path" {
  description = "Dedicated lab key, created by lab-start.sh on first run. Keep it separate from your everyday key"
  type        = string
  default     = "~/.ssh/k8s-hardening-lab_ed25519.pub"

  validation {
    condition     = fileexists(pathexpand(var.ssh_public_key_path))
    error_message = "Lab key not found. Run ./infra/scripts/lab-start.sh (it creates the key), or: ssh-keygen -t ed25519 -f ~/.ssh/k8s-hardening-lab_ed25519 -C k8s-hardening-lab"
  }
}
