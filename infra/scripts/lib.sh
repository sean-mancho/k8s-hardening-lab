# shellcheck shell=bash
# Helpers shared by the lab scripts (sourced, not run): paths, the lab key, tofu outputs, and
# running commands on the instances over the generated SSH config

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSH_CFG="$INFRA_DIR/ssh_config" # written by lab-start.sh
TRIES=24                        # 5 s apart: how long ssh retries wait for a booting instance

# The control plane (kubernetes.tf): the lab's admin host, like the jumpbox in Kubernetes the Hard
# Way. kubectl runs there, it pulls files from GitHub, and it reaches the worker with your
# forwarded agent. The API server is never reachable from outside the VPC
API_HOST=k8s-control-plane

# Used only when there's no state to read the region from; the default must match variables.tf
LAB_REGION="${TF_VAR_region:-us-east-1}"

tf() { tofu -chdir="$INFRA_DIR" "$@"; }

# die LINE...: print each argument as a line on stderr and exit 1
die() { printf '%s\n' "$@" >&2; exit 1; }

# require CMD...: fail early with a clear message instead of halfway through
require() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null || die "$cmd not found. See the prerequisites in infra/README.md."
  done
}

# --- The lab key ---

# Sets KEY: the dedicated lab key, separate from your everyday key. LAB_SSH_KEY may use ~ or a
# relative path; it's made absolute, since tofu runs from infra/
lab_key() {
  KEY="${LAB_SSH_KEY:-$HOME/.ssh/k8s-hardening-lab_ed25519}"
  KEY="${KEY/#\~/$HOME}"
  mkdir -p -m 700 "$(dirname "$KEY")"
  KEY="$(cd "$(dirname "$KEY")" && pwd)/$(basename "$KEY")"
}

# The control plane reaches the worker with your forwarded agent (ssh_config), so the lab key must
# be in a running agent. Loads it if it isn't (asks for its passphrase once)
agent_has_lab_key() {
  lab_key
  [ -n "${SSH_AUTH_SOCK:-}" ] ||
    die "No ssh-agent running, so the control plane can't reach the worker." 'Start one: eval "$(ssh-agent)"'
  local fingerprint
  fingerprint=$(ssh-keygen -lf "$KEY.pub" | awk '{ print $2 }')
  ssh-add -l 2>/dev/null | grep -qF "$fingerprint" || ssh-add "$KEY"
}

# --- What tofu built ---

# Sets AWS_REGION and IDS from tofu, never from the CLI's defaults. IDS[0] is the edge
load_lab() {
  AWS_REGION=$(tf output -raw region)
  export AWS_REGION
  local ids
  ids=$(tf output -raw instance_ids) # own line: set -e ignores a failing $(...) inside <<<
  read -r -a IDS <<< "$ids"
}

# Use the region the lab was built in, for tofu commands on an existing lab. var.region otherwise
# comes from the shell: without TF_VAR_region, tofu looks in the default region, finds nothing, and
# a delete drops the real lab from the state while it keeps billing
pin_region() {
  local region
  region=$(tf output -raw region 2>/dev/null) && [ -n "$region" ] || return 0
  export TF_VAR_region="$region"
}

# The Kubernetes nodes (kubernetes.tf), one name per line; worker_names leaves out the control plane
node_names()   { tf output -raw node_hosts | awk '{ print $1 }'; }
worker_names() { tf output -raw node_hosts | awk -v control_plane="$API_HOST" '$1 != control_plane { print $1 }'; }

# ids_in_state STATE[,STATE...]: the lab's instances in those states, space-separated
ids_in_state() {
  aws ec2 describe-instances --instance-ids "${IDS[@]}" \
    --filters Name=instance-state-name,Values="$1" \
    --query "Reservations[].Instances[].InstanceId" --output text
}

# Stop early when the lab isn't up: ssh to a stopped instance only times out, retry after retry
require_running() {
  [ -f "$SSH_CFG" ] || die "No infra/ssh_config yet: start the lab first"
  load_lab
  local running
  running=$(ids_in_state running)
  [ "$(wc -w <<< "$running")" -eq "${#IDS[@]}" ] || die "The lab isn't running: start it first"
}

# What the local state tracks: empty on a fresh clone or after tofu destroy
tracked() {
  [ -f "$INFRA_DIR/terraform.tfstate" ] || return 0
  tf state list
}

# Stop if AWS has lab instances the local state doesn't track. A lost or moved terraform.tfstate
# must not hide a lab that's still billing, or build a second lab next to it
check_no_untracked_lab() {
  local found
  found=$(aws ec2 describe-instances --region "$LAB_REGION" \
    --filters Name=tag:Project,Values=cks-lab Name=instance-state-name,Values=pending,running,stopping,stopped \
    --query "Reservations[].Instances[].InstanceId" --output text)
  [ -z "$found" ] || die \
    "The local state tracks no lab, but AWS has instances tagged Project=cks-lab: ${found//$'\t'/ }" \
    "Restore infra/terraform.tfstate (or run from the clone that has it)." \
    "If that lab is abandoned, terminating the instances isn't enough: also delete the VPC cks-lab-vpc and the cks-lab-... key pair."
}

# --- Running commands on the instances ---

# on HOST CMD...: run CMD on a lab instance (k8s-edge, k8s-control-plane, k8s-worker)
on() {
  local host=$1
  shift
  ssh -F "$SSH_CFG" -o ConnectTimeout=10 "$host" "$@"
}

# on_test HOST CMD...: CMD's exit status on HOST, for if/||. A lost SSH connection (255) stops
# the script instead of reading as "no". No stdin: a check never needs it, and ssh would
# otherwise swallow whatever you type at the console while it runs
on_test() {
  local rc=0
  on "$@" </dev/null || rc=$?
  [ "$rc" != 255 ] || die "Lost the SSH connection to $1"
  return "$rc"
}

# Close the shared connections (ControlMaster in ssh_config) before the instances stop or go.
# The nodes keep their private IPs, so a leftover connection would be reused by the next start
# within ControlPersist, and ssh would hang on it until ServerAlive gives up (about 90 s)
close_ssh_masters() {
  [ -f "$SSH_CFG" ] || return 0
  local host
  for host in $(awk '$1 == "Host" && $2 != "k8s-*" { print $2 }' "$SSH_CFG" | sort -u); do
    ssh -F "$SSH_CFG" -O exit "$host" 2>/dev/null || true
  done
}

# ssh_fatal ERR: stop retrying on ssh errors that waiting won't fix
ssh_fatal() {
  case "$1" in
    *'REMOTE HOST IDENTIFICATION HAS CHANGED'*)
      die "A lab host key changed although the instances didn't. Find out why before you trust it." \
          "If it's expected: rm \"$INFRA_DIR/known_hosts\" and start the lab again" ;;
    *'Permission denied'*)
      die "The lab rejected your key ($KEY). Use the key the lab was built with (LAB_SSH_KEY)." "$1" ;;
  esac
}
