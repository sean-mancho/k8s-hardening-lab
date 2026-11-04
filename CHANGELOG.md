# Changelog

All notable changes to the lab, one section per post tag (`epNN`). The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [ep01] - 2026-11-03

### Added

- Private two-node kubeadm lab on AWS (OpenTofu): VPC across three AZs, an edge instance as bastion
  and NAT, control plane and worker on private IPs only
- `lab.sh` console (`cks-lab>` prompt or one command per run): `start`, `init`, `stop`, `delete`,
  `status` (states, uptime, `Ready` nodes, or `not built yet`; a stopped lab points to `start`),
  `ssh <control-plane|worker|edge>` (unknown names get the node list) and `help`. `kubectl` runs on the control
  plane; nothing forwards the API server to the laptop. The up arrow recalls commands; `quit` (or
  Ctrl-D) offers to stop a running lab
- `lab-start.sh` / `lab-stop.sh` (run by `start` / `stop`): build or start the lab, write
  `infra/ssh_config`, wait for each instance's first boot; stop the instances. On a new lab, `start`
  ends by listing the two ways to build the cluster: the manual process (`infra/README.md` sections 3–5) or `init`
- Shared SSH connections are closed on `stop` and `delete`, so a quick `stop` then `start` doesn't hang
  on a dead connection. After a rebuild, `start` also clears the old worker host keys from the control
  plane, so `ssh`/`scp` from there to a replaced worker keep working
- Safety checks: the scripts refuse to run when AWS has `Project=cks-lab` instances the local state
  doesn't track; a `boot_scripts_applied` check warns when `nat.sh` / `node.sh` changed after a build
- Dedicated lab SSH key, created on first run
- `start` asks which public IP may SSH to the edge (the detected one is the default); the edge's
  SG rule is that IP as a `/32`, refreshed every session
- Node first boot (`node.sh`): swap off, kernel prerequisites, containerd 2.x with the systemd cgroup
  driver, kubeadm/kubelet/kubectl/crictl pinned to one patch release (`k8s_minor.k8s_patch`, output
  `k8s_version`) and held, along with containerd
- `cluster-init.sh`: the bootstrap from `infra/README.md` sections 3–5 in one go. kubeadm init from a
  config file (v1beta4: `controlPlaneEndpoint`, `podSubnet`), admin kubeconfig,
  cgroup-driver check, `super-admin.conf` moved to root-only storage, Cilium, and the worker join with
  a 15-minute token passed on stdin. Re-runs skip finished steps; a half-finished join is reset and retried, and a rebuilt worker's
  stale Node object is deleted before the new instance joins.
  An existing `admin.conf` counts as initialized only once the API server answers (`/readyz`); otherwise
  it stops with reset instructions instead of failing later at Cilium
- The control plane as the lab's admin host: your SSH agent is forwarded to it (and only it), so
  `ssh`/`scp` to the worker work from there. Posts' files come from GitHub (`git clone` on the
  control plane), and `node.sh` installs `git`
- `manifests/README.md`: how each post's folder works, on this lab or any kubeadm cluster (plain
  `kubectl` scripts, `on-node.sh` for node files, labels, pinning). `replay.sh [NN] [REF]` takes a running
  lab to the state before post NN (`init`, then each post folder), from what's pushed to GitHub. It runs
  each folder's scripts as readers do (`./apply.sh`), and stops on a folder missing `apply.sh` or
  `verify.sh`, or with a script committed without its exec bit
- Node security groups open only the ports kubeadm and Cilium need to each other (plus NodePorts
  between the nodes); the VPC's default security group has no rules. Every rule, the edge's
  included, is a separate resource, so later posts change rules in place

### Tested with

- OpenTofu 1.13.5, AWS provider 6.69.1, Kubernetes 1.35.9, containerd 2.2.1, Cilium 1.20.4 (Cilium CLI v0.20.1)

## [ep00] - 2026-10-22

### Added

- README with the series schedule, and Post 0

[Unreleased]: https://github.com/sean-mancho/k8s-hardening-lab/compare/ep01...HEAD
[ep01]: https://github.com/sean-mancho/k8s-hardening-lab/compare/ep00...ep01
[ep00]: https://github.com/sean-mancho/k8s-hardening-lab/releases/tag/ep00
