#!/usr/bin/env bash
set -euo pipefail
# Build or start the lab: what lab.sh start runs, at the start of every session.
# Usage: lab-start.sh (no arguments)
#   0. create the dedicated lab key (first run only)
#   1. tofu apply, with the IP you allow SSH from (you read the plan and type yes)
#   2. start the instances        3. read the edge's new public IP
#   4. write infra/ssh_config     5. wait for each instance's first boot
# It doesn't build the cluster: infra/README.md sections 3-5 manually, or lab.sh init

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
require tofu aws ssh ssh-keygen curl

# 0. Dedicated lab key (created once; set a passphrase when asked)
lab_key
[ -f "$KEY" ] || ssh-keygen -t ed25519 -f "$KEY" -C "k8s-hardening-lab"
# tofu uploads the .pub. Written via a temp file, so a mistyped passphrase can't leave an empty one
if [ ! -s "$KEY.pub" ]; then
  ssh-keygen -y -f "$KEY" > "$KEY.pub.tmp" || { rm -f "$KEY.pub.tmp"; die "Couldn't read $KEY (wrong passphrase?)"; }
  mv "$KEY.pub.tmp" "$KEY.pub"
fi

# 1. First run on a fresh clone: download the provider. Then refresh the edge SG rule,
#    since your home IP may have changed
[ -d "$INFRA_DIR/.terraform" ] || tf init
TRACKED=$(tracked)
if [ -n "$TRACKED" ]; then pin_region; else check_no_untracked_lab; fi
# The edge allows SSH from one IPv4 address only. The detected one is the default; type another
# when it's wrong for the session (a VPN you're about to switch on, CGNAT, an IPv6-only lookup)
IPV4='^[0-9]{1,3}(\.[0-9]{1,3}){3}$'
DETECTED=$(curl -fsS --max-time 10 https://checkip.amazonaws.com 2>/dev/null) || DETECTED=
[[ "$DETECTED" =~ $IPV4 ]] || DETECTED=
while :; do
  if [ -n "$DETECTED" ]; then
    read -r -p "Public IP allowed to SSH to the edge [$DETECTED]: " MY_IP || MY_IP=
    MY_IP=${MY_IP:-$DETECTED}
  else
    read -r -p "Couldn't detect your public IP. Enter the IPv4 address to allow SSH from: " MY_IP ||
      die "No IP entered"
  fi
  MY_IP=${MY_IP%/32}
  [[ "$MY_IP" =~ $IPV4 ]] && break
  echo "Not a single IPv4 address: $MY_IP" >&2
done
# No -auto-approve, on purpose: you read every plan before it touches your account
tf apply -var="my_ip_cidr=${MY_IP}/32" -var="ssh_public_key_path=${KEY}.pub"

# 2. Start the lab's instances
load_lab
# An interrupted lab-stop can leave instances "stopping", which start-instances rejects
STOPPING=$(ids_in_state stopping)
if [ -n "$STOPPING" ]; then
  echo "Waiting for instances that are still stopping..."
  read -r -a STOPPING_IDS <<< "$STOPPING"
  aws ec2 wait instance-stopped --instance-ids "${STOPPING_IDS[@]}"
fi
echo "Starting the instances (usually under a minute)..."
aws ec2 start-instances --instance-ids "${IDS[@]}" >/dev/null
aws ec2 wait instance-running --instance-ids "${IDS[@]}"

# 3. Grab the edge instance's fresh public IP (it changes on every start)
EDGE_IP=$(aws ec2 describe-instances --instance-ids "${IDS[0]}" \
  --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
[[ "$EDGE_IP" =~ $IPV4 ]] || die "No public IP on the edge instance (got: $EDGE_IP)"

# 4. Regenerate the lab-only SSH config; host keys go to infra/known_hosts, not ~/.ssh.
#    New instance IDs (a rebuild) mean new host keys, so the old ones are dropped. infra/.rebuilt
#    remembers that the control plane still needs its cleanup (below), even if this run stops first:
#    the new ssh_config won't show the rebuild to the next run
NODE_HOSTS=$(tf output -raw node_hosts) # "name ip jump" per node, no newline after the last
REBUILT_MARK="$INFRA_DIR/.rebuilt"
grep -qxF "# instances: ${IDS[*]}" "$SSH_CFG" 2>/dev/null || { rm -f "$INFRA_DIR/known_hosts"; touch "$REBUILT_MARK"; }
{
  cat <<EOF
# instances: ${IDS[*]}
Host k8s-*
    User ubuntu
    IdentityFile "${KEY}"
    IdentitiesOnly yes
    AddKeysToAgent yes
    StrictHostKeyChecking accept-new
    UserKnownHostsFile "${INFRA_DIR}/known_hosts"
    ServerAliveInterval 30
    ServerAliveCountMax 3
    # Reuse each hop's connection: later ssh/scp skip the handshakes. The socket sits in
    # ~/.ssh because infra/ paths can exceed the Unix socket length limit (about 104 chars)
    ControlMaster auto
    ControlPath ~/.ssh/k8s-lab-%C
    ControlPersist 10m

Host k8s-edge
    HostName ${EDGE_IP}
    HostKeyAlias k8s-edge
EOF
  # From tofu (kubernetes.tf). Only the control plane is reachable from the edge; the other nodes
  # are reached through it (security.tf)
  # (<<< adds the final newline that read needs to see the last node)
  while read -r name ip jump; do
    printf '\nHost %s\n    HostName %s\n    ProxyJump %s\n' "$name" "$ip" "$jump"
  done <<< "$NODE_HOSTS"
  # Only the control plane gets your agent: ssh and scp from there to the worker use your laptop's
  # key, which never leaves it (Kubernetes the Hard Way copies a key onto its jumpbox instead)
  printf '\nHost %s\n    ForwardAgent yes\n' "$API_HOST"
} > "$SSH_CFG"

echo "Instances running."

# 5. nat.sh and node.sh run on first boot only, and their errors land in the instance's
#    cloud-init log. Wait for them here, so a failed boot shows now rather than at kubeadm init.
#    cloud-init status exits 0 when done, 2 when done with warnings, anything else on failure;
#    ssh itself exits 255. Retry while sshd comes up, but not on errors waiting won't fix
echo "Checking first boot (a few minutes on a new lab, seconds after that)..."
FAILED=0
NODES=$(node_names) # own line: set -e ignores a failing $(...) in a for list
for name in k8s-edge $NODES; do
  for _ in $(seq 1 "$TRIES"); do
    # Keep ssh's stderr, drop stdout (the redirect order matters)
    rc=0
    err=$(on "$name" cloud-init status --wait 2>&1 >/dev/null </dev/null) || rc=$?
    [ "$rc" = 255 ] || break
    ssh_fatal "$err"
    sleep 5
  done
  case "$rc" in
    0) echo "$name: ready" ;;
    2) echo "$name: ready, with warnings (sudo cloud-init status --long shows them)" ;;
    255)
      echo "$name: unreachable over SSH. Last ssh error:" >&2
      printf '%s\n' "$err" >&2
      FAILED=1 ;;
    *)
      echo "$name: first boot failed. End of /var/log/cloud-init-output.log:" >&2
      on "$name" sudo tail -20 /var/log/cloud-init-output.log </dev/null >&2 || true
      FAILED=1 ;;
  esac
done
[ "$FAILED" = 0 ] || exit 1

# When the instance IDs changed (any rebuild, e.g. -replace of the worker), the control plane's
# ~/.ssh/known_hosts still holds the old worker host keys, and ssh/scp from there would refuse:
# "REMOTE HOST IDENTIFICATION HAS CHANGED". Forget them; the next connection learns the new ones
if [ -e "$REBUILT_MARK" ]; then
  while read -r name ip _; do
    [ "$name" = "$API_HOST" ] && continue
    on "$API_HOST" "ssh-keygen -R $name; ssh-keygen -R $ip" </dev/null >/dev/null 2>&1 || true
  done <<< "$NODE_HOSTS"
  rm -f "$REBUILT_MARK"
fi

# A new lab has no cluster yet: say what comes next. Exit 1 means no admin.conf, so no kubeadm init
rc=0
on "$API_HOST" test -f /etc/kubernetes/admin.conf </dev/null 2>/dev/null || rc=$?
if [ "$rc" = 1 ]; then
  echo "Lab ready, but there is no cluster yet. Two options:"
  echo "  1. Build it manually (kubeadm init, Cilium, join): infra/README.md sections 3-5. You see every step."
  echo "  2. Type init (lab.sh init) to do all of it in one go."
else
  echo "Lab ready. lab.sh ssh control-plane opens a shell on the control plane, where kubectl runs."
fi
