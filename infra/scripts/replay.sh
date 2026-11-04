#!/usr/bin/env bash
set -euo pipefail
# Bring a running lab to the state before post NN, for working on that post.
# Usage: replay.sh [NN] [REF]
#   NN   replay every post folder numbered below NN (default: all of them)
#   REF  branch or tag of the repo on GitHub (default: main). Only pushed commits are replayed:
#        push your post/NN-topic branch first to replay it
# It runs cluster-init.sh (what lab.sh init runs), then does on the control plane what a reader
# does manually: clone the repo from GitHub, and for each post folder run on-node.sh there and
# (copied over with scp) on every worker, then apply.sh and verify.sh. Stops at the first failure

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"
require tofu aws ssh ssh-add

REPO_URL="${LAB_REPO_URL:-https://github.com/sean-mancho/k8s-hardening-lab.git}"
UPTO=100
REF=main
if [ $# -gt 0 ]; then
  [[ "$1" =~ ^[0-9]{1,2}$ ]] || die "Usage: replay.sh [NN] [REF] (e.g. replay.sh 05 replays posts 02-04)"
  UPTO=$((10#$1))
fi
if [ $# -gt 1 ]; then
  [[ "$2" =~ ^[A-Za-z0-9._/-]+$ ]] || die "Not a branch or tag name: $2"
  REF=$2
fi

agent_has_lab_key   # the control plane reaches the worker with your forwarded agent
"$DIR/cluster-init.sh"
WORKERS=$(worker_names) # own line: set -e ignores a failing $(...) in an argument list

echo "Replaying posts before $UPTO from $REF on $API_HOST..."
# The script below runs on the control plane, reading itself from stdin (bash -s), so nothing in
# it may read stdin: ssh -n, and </dev/null for the post's own scripts
# shellcheck disable=SC2086 # the worker names are meant to split into arguments
on "$API_HOST" bash -s -- "$UPTO" "$REF" "$REPO_URL" $WORKERS <<'ON_CP'
set -euo pipefail
upto=$1 ref=$2 url=$3
shift 3
workers=("$@")
remote() { ssh -n -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$@"; }

# A fresh clone in ~/replay, apart from any clone you work in manually
rm -rf ~/replay
git clone --quiet --depth 1 --branch "$ref" "$url" ~/replay
cd ~/replay/manifests 2>/dev/null || { echo "No manifests/ at $ref: nothing to replay"; exit 0; }

for dir in [0-9][0-9]-*/; do
  [ -d "$dir" ] || continue          # no post folders yet
  name=${dir%/}
  n=$((10#${name%%-*}))
  [ "$n" -lt "$upto" ] || break
  echo "=== Post $n: $name ==="

  # apply.sh and verify.sh are required (manifests/README.md): a misnamed one must not pass as a
  # green replay that checked nothing
  for script in apply.sh verify.sh; do
    [ -f "$name/$script" ] || { echo "manifests/$name has no $script (every post folder needs one)" >&2; exit 1; }
  done
  # Run the scripts exactly as manifests/README.md tells readers to (./apply.sh, not bash
  # ./apply.sh), so a script committed without its exec bit fails here first, with the fix
  for script in on-node.sh apply.sh verify.sh; do
    [ ! -f "$name/$script" ] || [ -x "$name/$script" ] || {
      echo "manifests/$name/$script isn't executable, so ./$script fails for readers too." >&2
      echo "Fix: git update-index --chmod=+x manifests/$name/$script, then commit and push" >&2
      exit 1
    }
  done

  if [ -f "$name/on-node.sh" ]; then
    echo "on-node.sh on $(hostname)"
    (cd "$name" && sudo ./on-node.sh </dev/null)
    for worker in "${workers[@]}"; do
      echo "on-node.sh on $worker"
      remote "$worker" "rm -rf ~/replay/$name && mkdir -p ~/replay"
      scp -q -r -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$name" "$worker:replay/"
      remote "$worker" "cd ~/replay/$name && sudo ./on-node.sh" # scp keeps the exec bit
    done
  fi

  (cd "$name" && ./apply.sh </dev/null)
  (cd "$name" && ./verify.sh </dev/null)
done
echo "Replay done."
ON_CP
