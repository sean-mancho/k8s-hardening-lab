#!/usr/bin/env bash
set -euo pipefail
# The lab console.
# Usage: lab.sh [start | init | ssh <control-plane|worker|edge> | status | stop | delete | help]
# With a command it runs that command once. Without one it opens a cks-lab> prompt, your base
# terminal: start the lab, ssh into a node to work, exit back to the prompt, and stop
# or delete the lab when you're done

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"
# In session order, like help. One line under 80 characters, so it never wraps
USAGE="start, init, ssh <node>, status, stop, delete, help"

show_help() {
  cat <<'EOF'
  start    build or start the lab (asks which IP may SSH in, shows the plan).
           It brings up the machines only, not the cluster
  init     build the cluster in one go (kubeadm, Cilium, join); skips finished
           steps. Or skip it and do those steps manually, to see each one
  ssh X    shell on control-plane | worker | edge; exit comes back here. Every
           hop goes through the edge, and to the worker through the control
           plane too. kubectl runs on the control plane, and from there,
           ssh/scp k8s-worker use your forwarded agent
  status   instance states and uptime, cluster nodes
  stop     stop the instances (storage still bills, about $4/month)
  delete   destroy the whole lab (shows the plan, asks for yes)
EOF
}

# epoch ISO-TIME: seconds since 1970 for an AWS UTC timestamp, with GNU date (Linux) or BSD date (macOS)
epoch() {
  date -u -d "$1" +%s 2>/dev/null || date -j -u -f '%Y-%m-%dT%H:%M:%S' "${1%%[.+Z]*}" +%s 2>/dev/null
}

lab_status() {
  require tofu aws ssh
  local tracked
  tracked=$(tracked)
  if [ -z "$tracked" ]; then
    check_no_untracked_lab
    echo "No lab deployed."
    return
  fi
  load_lab

  # One line per instance; uptime counts from the launch time, which every start resets
  local rows name state launch since secs running=0
  rows=$(aws ec2 describe-instances --instance-ids "${IDS[@]}" --output text \
    --query "Reservations[].Instances[].[Tags[?Key=='Name']|[0].Value, State.Name, LaunchTime]")
  while read -r name state launch; do
    if [ "$state" = running ] && since=$(epoch "$launch"); then
      running=$((running + 1))
      secs=$(($(date +%s) - since))
      printf '%-18s %-9s up %dh%02dm\n' "$name" "$state" $((secs / 3600)) $((secs % 3600 / 60))
    else
      [ "$state" != running ] || running=$((running + 1))
      printf '%-18s %s\n' "$name" "$state"
    fi
  done <<< "$rows"

  [ "$running" -eq "${#IDS[@]}" ] || echo "The lab isn't fully running: start brings it up (a stopped lab keeps its cluster)"

  # The cluster, only when every instance runs: exit 3 means kubeadm init hasn't run yet
  [ "$running" -eq "${#IDS[@]}" ] && [ -f "$SSH_CFG" ] || return 0
  local nodes rc=0
  nodes=$(on "$API_HOST" 'test -f ~/.kube/config || exit 3; kubectl get nodes --no-headers --request-timeout=5s' \
    </dev/null 2>/dev/null) || rc=$?
  case "$rc" in
    0)
      awk '{ total++; if ($2 == "Ready") ready++; if (!seen[$5]++) v = v (v ? ", " : "") $5 }
           END { printf "Cluster: %d/%d nodes Ready (%s)\n", ready, total, v }' <<< "$nodes" ;;
    3)   echo "Cluster: not built yet. Build it manually (infra/README.md sections 3-5) or run init" ;;
    255) echo "Cluster: unknown (no SSH to $API_HOST)" ;;
    *)   echo "Cluster: API server not answering (still starting after a start? try again in 30 s)" ;;
  esac
}

# Destroy everything the state tracks. tofu shows the plan and waits for "yes", as with apply
lab_delete() {
  require tofu aws
  local tracked
  tracked=$(tracked)
  if [ -z "$tracked" ]; then
    check_no_untracked_lab
    echo "No lab found (nothing deployed)."
    return
  fi
  lab_key
  close_ssh_masters
  pin_region
  # my_ip_cidr is required, but a destroy ignores its value: any valid /32 will do
  tf destroy -var="my_ip_cidr=192.0.2.1/32" -var="ssh_public_key_path=${KEY}.pub"
  rm -f "$SSH_CFG" "$INFRA_DIR/known_hosts" "$INFRA_DIR/.rebuilt"
  echo "Lab deleted. The lab key stays in $KEY for the next build."
}

lab_ssh() {
  local host
  case "${1:-}" in
    "")  die "Usage: ssh <control-plane|worker|edge>" ;;
    *)   host="k8s-${1#k8s-}" ;;
  esac
  require tofu aws ssh
  [ -f "$SSH_CFG" ] || die "No infra/ssh_config yet: start the lab first"

  # Only names the lab has (the edge plus the nodes in kubernetes.tf), so a typo gets the list
  # instead of an ssh error, even on a stopped lab. The list uses the short names you type
  local n nodes names="" found=""
  nodes=$(node_names) # own line: set -e ignores a failing $(...) in a for list
  for n in k8s-edge $nodes; do
    if [ "$n" = "$host" ]; then found=yes; fi
    names+="${names:+, }${n#k8s-}"
  done
  [ -n "$found" ] || die "Unknown node: $1 (nodes: $names)"
  require_running

  # From a shell on the control plane, ssh and scp to the worker use your forwarded agent, so
  # make sure the lab key is in it. Without an agent the shell still works, just without that hop
  if [ "$host" = "$API_HOST" ]; then
    if [ -n "${SSH_AUTH_SOCK:-}" ]; then
      agent_has_lab_key || echo "Note: couldn't add the lab key to your agent; ssh/scp to the worker from the control plane won't work" >&2
    else
      echo "Note: no ssh-agent running, so ssh/scp from the control plane to the worker won't work this session" >&2
    fi
  fi

  # -t: an interactive shell, so this is plain ssh rather than on (which runs one command)
  ssh -t -F "$SSH_CFG" -o ConnectTimeout=10 "$host"
}

# Leaving with the lab running keeps the bill running, so offer to stop it
offer_stop() {
  local tracked running ans
  tracked=$(tracked)
  [ -n "$tracked" ] || return 0
  load_lab
  running=$(ids_in_state pending,running)
  [ -n "$running" ] || return 0
  read -r -p "The lab is still running. Stop it now? [y/N] " ans || ans=
  if [[ "$ans" == [yY]* ]]; then exec "$DIR/lab-stop.sh"; fi
  echo "Still running. lab.sh stop stops it."
}

run() {
  case "${1:-}" in
    start)  exec "$DIR/lab-start.sh" ;;
    init)   exec "$DIR/cluster-init.sh" ;;
    stop)   exec "$DIR/lab-stop.sh" ;;
    delete) lab_delete ;;
    status) lab_status ;;
    ssh)    lab_ssh "${2:-}" ;;
    help|-h|--help) echo "Usage: lab.sh [command], or no command for the cks-lab> console"; show_help ;;
    _offer_stop) offer_stop ;; # the console's exit check, run as a child like every command
    *)      die "Unknown command: $1" "Commands: $USAGE" ;;
  esac
}

if [ $# -gt 0 ]; then
  run "$@"
  exit
fi

# Each command runs in a child lab.sh, so a failure (die, set -e) ends that command, not the
# prompt. Ctrl-C stops the running command, or clears the line at the prompt; quit or Ctrl-D leaves.
# History is on only while the prompt runs, so the up arrow recalls typed commands and nothing
# else; it stays in memory (HISTFILE is empty)
console() {
  local cmd arg quit=
  while read -r -e -p "cks-lab> " cmd arg; do
    [ -z "$cmd" ] || history -s "$cmd${arg:+ $arg}"
    case "$cmd" in
      "") ;;
      quit|exit) quit=yes; break ;;
      help) show_help; echo "  help     this list"; echo "  quit     leave (offers to stop a running lab; Ctrl-D too)" ;;
      *) "$DIR/lab.sh" "$cmd" ${arg:+"$arg"} || true ;;
    esac
  done
  [ -n "$quit" ] || echo # Ctrl-D: end the prompt line, so what follows starts on its own line
}

trap 'echo' INT
echo "cks-lab: $USAGE, quit" # quit exists only at this prompt
HISTFILE='' HISTCONTROL=ignoredups
set -o history
console
set +o history

"$DIR/lab.sh" _offer_stop ||
  die "Couldn't check whether the lab is still running, so it may still be billing. Check: lab.sh status"
