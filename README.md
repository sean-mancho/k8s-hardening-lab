# Hardening Kubernetes from Scratch

A hands-on study guide for the CKS (Certified Kubernetes Security Specialist), built on a real cluster.
If you're preparing for the exam, this series walks through each domain the way I wish I'd had it: one
topic per post, hands-on in a private two-node kubeadm lab on AWS, with the commands, YAML and checks
you can run yourself.

Every post covers two things:

- **For the exam:** what the CKS expects, how to do it quickly, and how to verify it worked.
- **In practice:** how the same control is rolled out, tested and maintained on a real cluster.

The lab is in `infra/` (Post 1), and each later post adds its manifests, so you can follow along, break
things and try again. Questions and suggestions are welcome as GitHub issues.

> **This repo builds your own private lab.** `lab.sh` deploys into *your* AWS account, using *your*
> SSH key and home IP, at about $7–8/month for ~40 lab hours (about $4/month stopped). Run `lab.sh stop`
> at the end of each session and `lab.sh delete` when you're done. Nothing here connects to the author's environment.

## Posts

New posts go out on Tuesdays (Post 0, the introduction, was a Thursday). Each post's code is tagged `epNN`, so you can check out the lab as it was at
that post. Titles of upcoming posts may change.

| # | Date | Post | CKS domain | Code |
|---|---|---|---|---|
| 0 | 2026-10-22 | [I Passed the CKS. Now I'm Hardening My Own Cluster.](https://dev.to/seanmancho/i-passed-the-cks-now-im-hardening-my-own-cluster-em7) | Overview | — |
| 1 | 2026-11-03 | Building a Private Kubernetes Lab on AWS | Cluster Setup | `infra/` |
| 2 | 2026-11-10 | Scoring a Fresh Cluster with kube-bench | Cluster Setup | |
| 3 | 2026-11-17 | Locking Down API Access | Cluster Hardening | |
| 4 | 2026-12-01 | Upgrading the Cluster | Cluster Hardening | |
| 5 | 2026-12-08 | Controlling Network Traffic | Cluster Setup | |
| 6 | 2026-12-15 | Hardening the Host | System Hardening | |
| 7 | 2027-01-05 | Hardening Workloads | Minimize Microservice Vulnerabilities | |
| 8 | 2027-01-12 | Encrypting Pod-to-Pod Traffic | Minimize Microservice Vulnerabilities | |
| 9 | 2027-01-19 | Supply Chain, Part 1: Building Safer Images | Supply Chain Security | |
| 10 | 2027-01-26 | Supply Chain, Part 2: Controlling What Runs | Supply Chain Security | |
| 11 | 2027-02-02 | Audit Logs: Who Did What? | Monitoring, Logging and Runtime Security | |
| 12 | 2027-02-09 | Runtime Security with Falco | Monitoring, Logging and Runtime Security | |
| 13 | 2027-02-16 | Capstone: Break In, Get Caught | All | |

Breaks: 2026-11-24 (the week of US Thanksgiving) and 2026-12-22 to 12-29 (holidays).

## How the series builds on the lab

The lab starts as a hardened baseline: private nodes, one entry point, security groups that open only
the ports kubeadm and Cilium need (plus a few convenience ports between the nodes), IMDSv2 (the token-protected EC2 instance metadata service) and encrypted disks. The Kubernetes side is a stock kubeadm install,
on purpose. Each post takes one piece, measures it, tightens it and measures again:

| Post | What it builds on |
|---|---|
| 2: Scoring a fresh cluster with kube-bench | This untouched kubeadm install is the baseline score, and the binaries installed here get verified |
| 3: Locking down API access | The API server is already reachable only inside the VPC, and `kubectl` runs on the control plane; next come authentication, RBAC and the API server's own flags |
| 4: Upgrading the cluster | Pinned, held packages and containerd 2.x make the 1.35 → 1.36 kubeadm upgrade a clean exercise |
| 5: Controlling network traffic | Cilium, the cross-AZ node traffic and the metadata service's (IMDS) hop limit of 1 set up NetworkPolicy and metadata protection; the per-port node rules are the AWS-level version of the same idea |
| 6: Hardening the host | Full Ubuntu 24.04 VMs (not containers, as in kind or minikube) for AppArmor, seccomp, SSH and a smaller attack surface; instances with no IAM role yet, for least-privilege IAM |
| 7–8: Workloads and pod-to-pod encryption | Pod Security Admission, encryption at rest through the API server's static pod manifest, Cilium WireGuard across AZs |
| 9–10: Supply chain | Images pulled through the edge, then scanned, signed and admitted |
| 11–12: Audit logs and Falco | The API server's static pod manifest for audit policy, and real kernels for Falco |
| 13: Capstone | Post 1's "accepted risks" (edge egress, convenience ports between the nodes, no flow logs, the SSH agent on the control plane, trust-on-first-use host keys) become the attacker's starting points |

## Using the lab

Prerequisites:

- An AWS account you can manage EC2 in, with AWS CLI v2 credentials configured (the lab uses `us-east-1`)
- OpenTofu, OpenSSH and `curl` (OpenSSH and `curl` come with macOS)

The details (versions, permissions, region, key options) are in [`infra/README.md`](infra/README.md).

Clone the repo, at a post's tag to get the lab as it was at that post, and run everything from the repo root:

```bash
git clone --branch ep01 https://github.com/sean-mancho/k8s-hardening-lab.git
cd k8s-hardening-lab
./infra/scripts/lab.sh        # lab console: a cks-lab> prompt
```

At the prompt: `start` (first build and every session: `tofu init` the first time, then apply, start the
instances, write `infra/ssh_config` and check first boot), `init` (bootstrap the cluster in one go),
`ssh control-plane` / `ssh worker` / `ssh edge` (a shell on that node; `exit` returns to the prompt), `status`,
`stop` (at the end of every session; a stopped lab keeps its cluster) and `delete` (when you're done or
taking a long break). `kubectl` runs on the control
plane (`ssh control-plane`). `help` explains each; `quit` (or Ctrl-D) offers to stop a lab that's still running. Each command also runs on its own, e.g. `./infra/scripts/lab.sh stop`.
`lab-start.sh` and `lab-stop.sh` still work and are what `start` and `stop` run.

`start` asks which public IP may SSH to the edge, with your detected IP as the default (press Enter, or
type another, e.g. behind a VPN). It brings up the machines, not the cluster. On a new lab, `start` ends by listing your two ways to
bootstrap Kubernetes:

- **Manual process**, recommended the first time: [`infra/README.md`](infra/README.md) sections 3–5, run on the nodes
  (`ssh control-plane`, then `ssh worker` for the join).
- **In one go:** `init`.

To catch up to a later post, `./infra/scripts/replay.sh NN [REF]` brings a *running* lab to the state
before post NN: it runs `init`, then applies every post's `manifests/` folder below NN. It doesn't use
your local checkout: the control plane clones the repo from GitHub at `main`, or at the branch or tag
you pass (`replay.sh 05 ep05` for the folders as Post 5 used them), so only pushed commits count. It
needs your lab key in a running ssh-agent (it adds the key if it's missing), and it doesn't create or
rebuild AWS resources; `start` does that. Post 4's upgrade is a runbook, not a folder, so replaying
past it leaves the cluster on the earlier version: see [`manifests/README.md`](manifests/README.md).

**SSH keys:** on first run, `start` creates a dedicated lab key at `~/.ssh/k8s-hardening-lab_ed25519`
(set a passphrase when asked; it's added to your agent on first use). Your everyday key is never
uploaded or used. The private key stays on your laptop: `ProxyJump` (OpenSSH's built-in jump-host
option) hops through the edge (and the control plane, for the worker) without copying the key. Your
agent is forwarded to the control plane only, so from a shell there `scp file k8s-worker:` works.
While you're connected, root on the control plane can use
every key loaded in your agent, not only the lab key, so load only the lab key for lab sessions. Lab host keys
go to `infra/known_hosts`, so your `~/.ssh/known_hosts` is never touched. To use a different key, set
`LAB_SSH_KEY=/absolute/path/to/key` before the first `start`, and keep it set for every later command,
`delete` included: changing the key replaces all three instances, which wipes the cluster.

**Done with the lab?** Delete it (read the destroy plan and type `yes`), then optionally delete the lab key:

```bash
./infra/scripts/lab.sh delete
rm ~/.ssh/k8s-hardening-lab_ed25519 ~/.ssh/k8s-hardening-lab_ed25519.pub
```

`delete` also removes `infra/ssh_config` and `infra/known_hosts`. If you set `LAB_SSH_KEY`, delete that key instead.

Step-by-step build and cluster bootstrap: [`infra/README.md`](infra/README.md). Post 1 explains the design.

## Layout

The repo fills in as the series goes:

```text
posts/       article sources (dev.to markdown)
infra/       OpenTofu code and lab scripts
manifests/   each post's YAML and policies (from Post 2)
runbooks/    one runbook per post's ops task
evidence/    sanitized kube-bench reports, scan output, audit samples
CHANGELOG.md what changed in the lab at each post, and the versions it was tested with
```

How each post's folder is laid out and applied: [`manifests/README.md`](manifests/README.md).

## License

Code is MIT-licensed (see [LICENSE](LICENSE)). Article text in `posts/` © Sean Mancho.
