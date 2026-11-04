#!/bin/bash
set -euxo pipefail
# Rendered by templatefile (hostname, hosts, k8s_minor and k8s_patch come from kubernetes.tf).
# Bash's own brace variables need a doubled dollar sign, like the dpkg-query format below.
# Steps follow the kubeadm install guide (v1.35 docs: "Installing kubeadm")

# Hostname from tofu (k8s-control-plane / k8s-worker), kept across reboots, and both
# nodes in /etc/hosts so sudo and kubectl output use the names
hostnamectl set-hostname ${hostname}
echo 'preserve_hostname: true' > /etc/cloud/cloud.cfg.d/99-lab-hostname.cfg
%{ for name, ip in hosts ~}
grep -qxF '${ip} ${name}' /etc/hosts || echo '${ip} ${name}' >> /etc/hosts
%{ endfor ~}

# retry TRIES DELAY CMD...: run CMD until it succeeds, at most TRIES times
retry() {
  local tries=$1 delay=$2
  shift 2
  for _ in $(seq "$tries"); do
    "$@" && return 0
    sleep "$delay"
  done
  return 1
}

# Wait until egress through the edge instance works: 60 tries of up to 5 s curl + 5 s sleep
# is 10 minutes, then cloud-init fails instead of hanging
retry 60 5 curl -s -o /dev/null --max-time 5 https://pkgs.k8s.io ||
  { echo "No egress through the edge after 10 min" >&2; exit 1; }

# Swap off, now and after reboots: the kubelet refuses to start when it finds swap (Ubuntu's
# EC2 images have none, so this only guards against an image that does)
swapoff -a
# Comment out entries whose third field (the filesystem type) is swap, and only those
sed -Ei '/^[[:space:]]*#/! s/^([[:space:]]*[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+swap([[:space:]]|$))/#\1/' /etc/fstab

# Kernel prerequisites
cat <<'CONF' > /etc/modules-load.d/k8s.conf
overlay
br_netfilter
CONF
modprobe -a overlay br_netfilter

cat <<'CONF' > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
CONF
sysctl --system

# Ubuntu's first-boot apt-daily run can hold the locks: the timeout covers install, but
# update has no timeout, so retry it
export DEBIAN_FRONTEND=noninteractive # no debconf or needrestart prompts without a tty
apt_get() { apt-get -o DPkg::Lock::Timeout=600 "$@"; }
retry 60 10 apt_get update || { echo "apt-get update kept failing for 10 min" >&2; exit 1; }
# The guide's prerequisites, plus git: posts clone the repo on the control plane. The image
# ships all four (the egress check above already needs curl), so this makes the dependency explicit
apt_get install -y ca-certificates curl gpg git

# Kubernetes repo for one minor release
REPO=https://pkgs.k8s.io/core:/stable:/v${k8s_minor}/deb
mkdir -p -m 755 /etc/apt/keyrings
retry 5 3 curl -fsSLo /tmp/k8s-release.key "$REPO/Release.key" ||
  { echo "Couldn't download the Kubernetes repo key" >&2; exit 1; }
gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg /tmp/k8s-release.key
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] $REPO/ /" > /etc/apt/sources.list.d/kubernetes.list

# containerd and the Kubernetes packages, pinned to one patch release so every rebuild matches
# (kubeadm no longer pulls in cri-tools, so crictl is listed explicitly). All four are held:
# the Kubernetes ones move only with kubeadm upgrade, and containerd must not be upgraded
# and restarted by unattended-upgrades mid-session
K8S=${k8s_minor}.${k8s_patch}
retry 60 10 apt_get update || { echo "apt-get update kept failing for 10 min" >&2; exit 1; }
apt_get install -y containerd cri-tools "kubelet=$K8S-*" "kubeadm=$K8S-*" "kubectl=$K8S-*"
apt-mark hold kubelet kubeadm kubectl containerd

# Newer Kubernetes releases drop containerd 1.x. noble-updates ships 2.x, but a mirror
# without the updates pocket would install 1.7, so check instead of finding out at the upgrade
CTRD=$(dpkg-query -W -f='$${Version}' containerd)
[[ "$CTRD" == 2.* ]] || { echo "Need containerd 2.x, got $CTRD" >&2; exit 1; }

# containerd with systemd cgroups
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
grep -q 'SystemdCgroup = true' /etc/containerd/config.toml # sed is silent if the line moves
systemctl restart containerd

# So crictl finds containerd without -r on every call
cat <<'CONF' > /etc/crictl.yaml
runtime-endpoint: unix:///var/run/containerd/containerd.sock
image-endpoint: unix:///var/run/containerd/containerd.sock
CONF
