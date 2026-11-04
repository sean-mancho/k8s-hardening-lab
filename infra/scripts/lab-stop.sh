#!/usr/bin/env bash
set -euo pipefail
# Stop the lab: what lab.sh stop runs, at the end of every session.
# Usage: lab-stop.sh (no arguments)
# Stops the instances and waits until they've stopped. Stopping isn't deleting: the EBS volumes
# still bill (about $4/month), and lab.sh delete removes everything

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
require tofu aws

# Nothing to stop on a fresh clone or after tofu destroy, unless AWS disagrees (a lost state
# file). Any other tofu error stops the script. The assignment has its own line because set -e
# ignores a failing $(...) inside an if test
TRACKED=$(tracked)
if [ -z "$TRACKED" ]; then
  check_no_untracked_lab
  echo "No lab found (nothing deployed)."
  exit 0
fi

# A first build that failed partway tracks instances but has no outputs to read them from. They
# bill all the same, so find them by tag instead of stopping at tofu's error
if tf output -raw instance_ids >/dev/null 2>&1; then
  load_lab
else
  echo "Can't read the lab's outputs (interrupted build?): stopping instances tagged Project=cks-lab in $LAB_REGION" >&2
  export AWS_REGION=$LAB_REGION
  FOUND=$(aws ec2 describe-instances \
    --filters Name=tag:Project,Values=cks-lab Name=instance-state-name,Values=pending,running \
    --query "Reservations[].Instances[].InstanceId" --output text)
  read -r -a IDS <<< "$FOUND"
  [ "${#IDS[@]}" -gt 0 ] || { echo "No running instances."; exit 0; }
fi
close_ssh_masters
aws ec2 stop-instances --instance-ids "${IDS[@]}" >/dev/null
aws ec2 wait instance-stopped --instance-ids "${IDS[@]}"
echo "Lab stopped. You now pay for EBS storage only."
