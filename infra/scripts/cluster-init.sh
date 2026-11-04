#!/usr/bin/env bash
set -euo pipefail
# Bootstrap the cluster the way infra/README.md sections 3-5 do manually: what lab.sh init runs.
# Usage: cluster-init.sh (no arguments; the lab must be running)
# Follows the kubeadm guide (v1.35 docs: "Creating a cluster with kubeadm"):
#   1. kubeadm init from a config file    2. admin kubeconfig    3. cgroup-driver check
#   4. super-admin.conf put away          5. Cilium              6. join the workers    7. wait for Ready
# Runs from your laptop over the lab's SSH config. Safe to re-run: finished steps are skipped

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
require tofu aws ssh
require_running

# Pinned versions; list them under "Tested with" in CHANGELOG.md when they change
CILIUM_CLI_VERSION=v0.20.1
CILIUM_VERSION=1.20.4
# Cilium (ipam.mode=kubernetes) hands out pod IPs from this range. It must not overlap the
# VPC (10.0.0.0/16) or the Service range (kubeadm's default 10.96.0.0/12)
POD_CIDR=192.168.0.0/16

K8S_VERSION=$(tf output -raw k8s_version) # the patch release node.sh installed
CONTROL_PLANE_IP=$(tf output -raw node_hosts | awk -v control_plane="$API_HOST" '$1 == control_plane { print $2 }')
WORKERS=$(worker_names)

# 1. kubeadm init from a config file. controlPlaneEndpoint is a name (it resolves through
#    /etc/hosts, written by node.sh), so a second control plane stays possible later; the
#    guide says a cluster built without one can't be made highly available. The file stays in
#    ~ on the control plane; later posts (audit logging, encryption at rest) extend it
#
# kubeadm init writes admin.conf early, before the control plane is up, so the file alone
# doesn't prove init finished: the API server must answer too. After a start it can take a
# minute to come back, hence the retries
if on_test "$API_HOST" 'test -f /etc/kubernetes/admin.conf'; then
  echo "Control plane initialized earlier: checking the API server answers..."
  on_test "$API_HOST" "for _ in \$(seq 1 $TRIES); do sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get --raw=/readyz >/dev/null 2>&1 && exit 0; sleep 5; done; exit 1" ||
    die "/etc/kubernetes/admin.conf exists on $API_HOST, but the API server isn't answering." \
        "If kubeadm init failed partway, reset and rerun: lab.sh ssh control-plane, sudo kubeadm reset -f, exit, then init." \
        "If the cluster worked before, don't reset (it wipes the cluster): check sudo crictl ps -a | grep kube-apiserver first."
  echo "Skipping kubeadm init"
else
  echo "Writing ~/kubeadm-config.yaml on $API_HOST and running kubeadm init (Kubernetes $K8S_VERSION)..."
  on "$API_HOST" 'cat > kubeadm-config.yaml' <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: $CONTROL_PLANE_IP
  bindPort: 6443
nodeRegistration:
  name: $API_HOST
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v$K8S_VERSION
controlPlaneEndpoint: $API_HOST:6443
networking:
  podSubnet: $POD_CIDR
EOF
  # Validate first, so a typo fails before kubeadm changes anything. The join command is
  # created below with a short-lived token, so init doesn't print one
  on "$API_HOST" 'kubeadm config validate --config kubeadm-config.yaml'
  on "$API_HOST" 'sudo kubeadm init --config kubeadm-config.yaml --skip-token-print'
fi

# 2. Admin kubeconfig for the ubuntu user (the guide's "regular user" steps)
on "$API_HOST" 'mkdir -p ~/.kube && sudo cp /etc/kubernetes/admin.conf ~/.kube/config && sudo chown "$(id -u):$(id -g)" ~/.kube/config'

# 3. The kubelet's cgroup driver must match containerd's (node.sh sets SystemdCgroup = true)
on_test "$API_HOST" 'sudo grep -q "^cgroupDriver: systemd$" /var/lib/kubelet/config.yaml' ||
  die "The kubelet's cgroup driver isn't systemd (/var/lib/kubelet/config.yaml), but containerd's is"

# 4. super-admin.conf is in system:masters, which bypasses RBAC entirely. The guide says to move
#    it to a safe location; root-only on the node is the lab's version (Post 3 comes back to it)
on "$API_HOST" 'sudo sh -c "[ ! -f /etc/kubernetes/super-admin.conf ] || { install -d -m 700 /root/break-glass && mv /etc/kubernetes/super-admin.conf /root/break-glass/; }"'

# 5. Cilium CLI (checked against its published checksum), then Cilium itself
echo "Control plane ready. Setting up Cilium $CILIUM_VERSION..."
if on_test "$API_HOST" "cilium version --client 2>/dev/null | grep -q 'cilium-cli: $CILIUM_CLI_VERSION '"; then
  echo "Cilium CLI $CILIUM_CLI_VERSION already installed"
else
  on "$API_HOST" 'bash -s' <<EOF
set -euo pipefail
cd "\$(mktemp -d)"
curl -fsSL --remote-name-all https://github.com/cilium/cilium-cli/releases/download/$CILIUM_CLI_VERSION/cilium-linux-amd64.tar.gz{,.sha256sum}
sha256sum --check cilium-linux-amd64.tar.gz.sha256sum
sudo tar xzfC cilium-linux-amd64.tar.gz /usr/local/bin
EOF
fi
if on_test "$API_HOST" 'kubectl -n kube-system get daemonset cilium >/dev/null 2>&1'; then
  echo "Cilium already installed: skipping cilium install"
else
  on "$API_HOST" "cilium install --version $CILIUM_VERSION --set ipam.mode=kubernetes"
fi

# 6. Join each worker. The join command carries a bootstrap token (a secret), so it gets a
#    15-minute TTL and goes to the worker on stdin, never on a command line
#    "Joined" needs both sides: the node registered with the API server, and kubelet.conf on the
#    worker. Registered without kubelet.conf means the worker was rebuilt (-replace) and its old
#    Node object is stale, so it's deleted and the new instance joins. kubelet.conf without
#    registration means a failed join, whose leftovers make kubeadm join's preflight refuse, so
#    they're reset first
for worker in $WORKERS; do
  registered='' configured=''
  # Only NotFound means unregistered. Any other error (the API server restarting, a lost connection)
  # stops here, because reading it as "not registered" would reset a healthy worker below
  if node=$(on "$API_HOST" "kubectl get node $worker 2>&1" </dev/null); then
    registered=yes
  elif ! grep -q NotFound <<< "$node"; then
    die "Couldn't check whether $worker has joined: $node"
  fi
  on_test "$worker" 'test -f /etc/kubernetes/kubelet.conf' && configured=yes
  if [ -n "$registered" ] && [ -n "$configured" ]; then
    echo "$worker already joined"
    continue
  fi
  if [ -n "$registered" ]; then
    echo "$worker was rebuilt: deleting its old Node object before it joins again"
    on "$API_HOST" "kubectl delete node $worker" </dev/null
  fi
  if [ -n "$configured" ]; then
    echo "$worker has leftovers from an earlier failed join: running kubeadm reset first"
    on "$worker" 'sudo kubeadm reset -f'
  fi
  echo "Joining $worker..."
  JOIN=$(on "$API_HOST" 'sudo kubeadm token create --ttl 15m --print-join-command')
  on "$worker" 'sudo bash -s' <<< "$JOIN"
done

# 7. Done when Cilium is healthy on every node and every node is Ready
echo "Waiting for Cilium and every node to be Ready (about 4 minutes on a new cluster)..."
on "$API_HOST" 'cilium status --wait >/dev/null && kubectl wait --for=condition=Ready nodes --all --timeout=5m && kubectl get nodes -o wide'
echo "Cluster ready. kubectl runs on the control plane: lab.sh ssh control-plane"
