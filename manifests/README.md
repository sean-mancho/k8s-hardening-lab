# Manifests

One folder per post, `manifests/NN-topic/`, with everything that post changes on the cluster: the
YAML, any files that go onto the nodes, and scripts that apply and check them. Each post's code is
tagged `epNN`, so `git checkout ep05` gives you the folders exactly as that post used them.

The folders work on **any kubeadm cluster**, not just this lab: the scripts inside are plain
`kubectl`, with no SSH, IPs or node names. The lab's own scripts only add the transport.

## Posts

| Post | Folder | What it changes |
|---|---|---|
| 2 | `02-cis-baseline/` | kube-bench Job and binary checks (arrives with Post 2) |
| 3 | `03-rbac/` | Roles, bindings, a CI ServiceAccount (arrives with Post 3) |
| 4 | — | An upgrade, not manifests: `runbooks/04-kubeadm-upgrade.md` (arrives with Post 4) |
| 5 | `05-netpol/` | Default-deny and egress NetworkPolicies, Ingress with TLS, metadata endpoint block |
| 6 | `06-host/` | AppArmor and seccomp profiles, pods that use them |
| 7 | `07-workloads/` | Pod Security Admission, encryption at rest, hardened `securityContext` |
| 8 | `08-encryption/` | Cilium WireGuard, gVisor `RuntimeClass` |
| 9–10 | `09-images/`, `10-admission/` | Image builds and scans; admission policies |
| 11 | `11-audit/` | Audit policy and API server settings |
| 12 | `12-falco/` | Falco values and rules |
| 13 | `13-capstone/` | The capstone's attack and detection steps |

Folders appear as their posts are published; the list may change with the series.

## Using them on this lab

SSH into the control plane and work there. It pulls the files from GitHub and passes
them on to the worker (your agent is forwarded to the control plane, so `scp` to the worker works):

```bash
./infra/scripts/lab.sh ssh control-plane                       # on your laptop; everything below runs on the control plane
git clone --branch ep05 https://github.com/sean-mancho/k8s-hardening-lab.git
cd k8s-hardening-lab/manifests
# Only if the folder has an on-node.sh: run it here, then on the worker (rm first, so a rerun has no stale files)
(cd 05-netpol && sudo ./on-node.sh)
ssh k8s-worker 'rm -rf 05-netpol' && scp -r 05-netpol k8s-worker: && ssh k8s-worker 'cd 05-netpol && sudo ./on-node.sh'
# Every folder:
cd 05-netpol && ./apply.sh && ./verify.sh
```

To bring a running lab to the state before a post in one go, from the repo root on your laptop:
`./infra/scripts/replay.sh 05 ep05`. It runs `lab.sh init`, then the steps above for every post folder
below 05. The control plane clones the repo from GitHub at the branch or tag you pass (`main` if you
pass none), not from your local checkout, so only pushed commits are replayed.

**Post 4 is the exception.** Its upgrade is a runbook, not a folder, so `replay.sh` can't do it:
replaying past 04 leaves the cluster on the version `init` installs. To match a later post exactly, run
`replay.sh 04`, follow `runbooks/04-kubeadm-upgrade.md` manually, then `replay.sh NN` (finished posts are
safe to rerun).

## Using them on your own cluster

You need `kubectl` with cluster-admin rights and root on the nodes. For each folder, in post order:

1. Read its `README.md`: what it changes, what it needs from earlier posts, and how to undo it.
2. If it has an `on-node.sh`, copy the folder to **every** node and run `sudo ./on-node.sh` there. It
   installs the `node/` files (they mirror their target paths, e.g. `node/etc/apparmor.d/...` →
   `/etc/apparmor.d/...`) and restarts whatever the post says.
3. From inside the folder: `./apply.sh`, then `./verify.sh`.

Some posts assume a kubeadm layout (static pod manifests in `/etc/kubernetes/manifests`) or Cilium as
the CNI; their README says so.

## What's in a folder

```text
manifests/NN-topic/
├── README.md        # what it does, the post it belongs to, prerequisites ("needs ep04"), how to undo
├── apply.sh         # required: applies everything below in order; safe to run twice
├── verify.sh        # required: the post's "Verify it" checks; exits non-zero on the first failure
├── 10-*.yaml        # Kubernetes objects, numbered in apply order (10, 20, 30… leaves gaps)
├── on-node.sh       # optional: run as root on every node, from the folder: installs node/, then loads or restarts what the post needs
├── node/            # optional: files on-node.sh installs, mirroring their target paths
└── before-after/    # optional: deliberately insecure examples the post fixes. Never applied
```

Rules every folder follows, so it stays portable and safe to rerun:

- **Plain `kubectl`.** `apply.sh` and `verify.sh` run from inside their folder wherever `kubectl`
  works. No SSH, no lab paths, no hard-coded node names or IPs: a script that needs a node looks it up
  (`kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o name`).
- **Idempotent.** `kubectl apply`, never `create`; running `apply.sh` twice changes nothing the second time.
- **Non-interactive and fail-fast.** Every script uses `set -euo pipefail`, never prompts or reads
  stdin (`replay.sh` runs them with stdin closed), and exits non-zero on any failure, so a replay stops
  at the first broken step.
- **Pinned.** Container images by fixed tag or digest; Helm charts with a fixed `--version` and a
  `values.yaml` in the folder, never a URL to a moving branch; binaries that `on-node.sh` downloads at a
  fixed version, checked against their published checksum (as `cluster-init.sh` does for the Cilium CLI).
- **Labelled.** Every object carries `app.kubernetes.io/part-of: k8s-hardening-lab` and
  `hardening-lab/post: "NN"` (Helm charts set them in `values.yaml`), so a post's objects can be listed.
  `kubectl get all` skips policies and RBAC, so list every type:
  `kubectl api-resources --verbs=list -o name | xargs -n1 kubectl get -A -l hardening-lab/post=05 -o name --ignore-not-found`.
- **`on-node.sh` runs on every node, from inside the folder.** It installs `node/` itself
  (`cp -r node/. /`), so a folder works the same manually, from `replay.sh` or on another cluster. A
  step for one node type checks for itself, e.g. only where `/etc/kubernetes/manifests/kube-apiserver.yaml`
  exists (the control plane).
- **Executable scripts.** Every `.sh` starts with `#!/usr/bin/env bash` and is committed executable
  (`git ls-files -s` shows `100755`; fix with `git update-index --chmod=+x`). `replay.sh` runs them as
  `./apply.sh` too, so it stops on one that isn't.
- **No secrets.** Keys and certificates are generated on the cluster, only if they don't exist yet (so
  a rerun keeps them), and never committed: by `apply.sh` for Kubernetes objects, by `on-node.sh` for
  files on a node (e.g. the encryption-at-rest key the API server reads from disk).
  Output that proves a result goes to `evidence/NN-*`, not here.

Code here is MIT-licensed (see [LICENSE](../LICENSE)): use it, adapt it, and read it before you apply
it to a cluster you care about.
