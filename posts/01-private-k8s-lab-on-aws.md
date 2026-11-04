---
title: "Building a Private Kubernetes Lab on AWS"
published: false
description: "A private two-node kubeadm cluster on AWS with OpenTofu: no public nodes, one edge instance as bastion and NAT, private by default from the first boot."
series: Hardening Kubernetes from Scratch
tags: kubernetes, security, aws, opentofu
cover_image: https://dev-to-uploads.s3.us-east-2.amazonaws.com/uploads/articles/o473bc7m0948nitwylyw.png
---

For the hands-on side of the Certified Kubernetes Security Specialist (CKS) exam, I wanted a lab where I could experiment, break things and start over, and learn the infrastructure layer underneath the cluster too. Hosted practice environments are great for timed exam drills, but not for hardening one cluster over weeks. Local tools like kind or minikube mostly hide the static pod manifests, audit logging and AppArmor profiles the exam asks you to change. Practicing on a real kubeadm cluster is the closest match. kubeadm is the official tool for bootstrapping Kubernetes on your own machines.

The lab also had to stay secure and low-cost. You get full control of the cluster for troubleshooting and hardening, and you can stop the instances when you're not using them to keep costs down.

The lab is a **two-node kubeadm cluster on AWS** with four properties:

- **Private nodes.** The control plane and worker sit in private subnets.
- **One way in.** You reach the cluster over SSH through a single edge instance, the only point of contact with it. The edge is both the *bastion* and the *NAT* that gives the private nodes outbound-only internet access.
- **Secure defaults.** Security groups allow only SSH from your IP and only the ports the cluster needs between nodes, plus a few convenience ports. IMDSv2, the token-protected EC2 instance metadata service, is required, and disks are encrypted.
- **Pay only for compute you use.** A small shell console starts and stops the instances, so you're billed for compute only while you're working. Stopped, the disks still cost about $4 a month.

This post covers the *design*: what the lab looks like and why. The code, the step-by-step build and the reference details live in the repo, tagged for this post: [`k8s-hardening-lab` at `ep01`](https://github.com/sean-mancho/k8s-hardening-lab/tree/ep01). One script builds the lab. Then you bootstrap the cluster yourself, as practice, or let the same script do it with one command.

---

## The architecture

![Network diagram: the laptop reaches k8s-edge, the only public instance, over SSH. The control plane and worker sit in private subnets and reach the internet only through the edge.](https://dev-to-uploads.s3.us-east-2.amazonaws.com/uploads/articles/yehfh9yn19on2nk8atv2.png)

The edge is the only instance with a public IP, alone in a public subnet. The control plane at `10.0.2.10` and the worker at `10.0.3.11` sit in private subnets with no route from the internet, each subnet in its own *availability zone* (AZ). Nothing outside can reach the cluster except SSH from your IP to the edge, and the security groups on each instance decide what may pass between them.

| From | To | Port | Protocol | Purpose |
|---|---|---|---|---|
| Your IP (/32) | k8s-edge | 22 | TCP | SSH |
| Private subnets | k8s-edge | All | All | NAT |
| k8s-edge | k8s-control-plane | 22 | TCP | SSH |
| k8s-control-plane | k8s-worker | 22 | TCP | SSH hop |
| k8s-control-plane | k8s-worker | 10250 | TCP | kubelet |
| k8s-worker | k8s-control-plane | 6443 | TCP | API server |
| Each node | The other node | 8472 | UDP | VXLAN |
| Each node | The other node | 4240 | TCP | Cilium health |
| Each node | The other node | n/a | ICMP | Cilium health |
| Each node | The other node | 4244 | TCP | Hubble |
| Each node | The other node | 30000-32767 | TCP | NodePorts |
| All three instances | 0.0.0.0/0 | All | All | Outbound |

*Node-to-node peers are security groups, not IP ranges; only the edge's NAT rule uses the private subnets' ranges. The VPC's default security group has no rules.*

![SSH path: the laptop connects to k8s-edge on port 22, ProxyJumps to k8s-control-plane at 10.0.2.10, and from there to k8s-worker at 10.0.3.11.](https://dev-to-uploads.s3.us-east-2.amazonaws.com/uploads/articles/urj1f02vcyh5x162az9o.png)

Traffic flows in two directions, and both pass through the edge:

- **In: SSH only.** You run `kubectl` on the control plane over SSH. SSH uses `ProxyJump`, so your private key never leaves your laptop. The control plane can still ask your laptop's SSH agent to sign with it while you're connected; that's the agent forwarding covered at the end of this post. Nothing forwards the API server's port to your laptop, and only the worker's security group may reach port 6443, so no machine besides the cluster's own nodes can reach the API server.
- **Out: through the edge.** The private route table sends `0.0.0.0/0` to the edge, which accepts any traffic from the nodes and sends it out under its own address, like a home router. Connections in the other direction are blocked: apart from SSH to the control plane, the edge can't open connections to the nodes, and the worker refuses connections from the edge altogether.

---

## Design decisions

### One edge instance: the only way in and the only way out

The edge is a bastion that doubles as a NAT instance for the nodes in the private subnets. The nodes need internet access, and a managed NAT gateway alone costs about $33 a month before data charges. That's more than this whole lab costs at around 40 hours of use a month, and it brings scalability the lab would never use. The edge does the NAT work only while it's running, and it stops when the lab stops.

### Three AZs, one instance each

Each instance sits in its own availability zone, so node-to-node traffic crosses subnets and routing boundaries, which makes NetworkPolicy and CNI troubleshooting realistic. The spread doesn't buy redundancy, though. Losing the edge's AZ takes your SSH access and the cluster's internet with it, and losing the control plane's AZ takes the API server down; real high availability needs duplicates. Cross-AZ traffic costs about $0.01/GB in each direction, which is negligible at lab scale.

### Secure defaults from the first boot

- **IMDSv2 required, hop limit 1, on every instance.** The metadata service answers the node itself, but a reply to an ordinary pod needs one more network hop than the limit allows, so pods can't reach it by default. The instances have no IAM role yet, so there are no cloud credentials to steal today. The hop limit keeps that true for ordinary pods once Post 6 adds least-privilege IAM. Pods with `hostNetwork: true` share the node's network and still get through; Post 5 comes back to this.

  A pod has its own network namespace, so it's like a small separate machine inside the node:

  ```text
  Node:  node → IMDS → node                  reply arrives
  Pod:   pod → node → IMDS → node ✗ pod      reply dropped at the node
  ```

  With hop limit 1, the token reply can cross one hop, which only gets it as far as the node. Passing it on to the pod would take a second hop, so it's dropped. IMDSv2 is also required, so without a token the pod can't read metadata at all.

  ```hcl
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
  ```

- **Encrypted disks.** Every root volume is encrypted gp3 (`encrypted = true`), with AWS's default EBS key, so etcd's data on the control plane is encrypted at rest at the disk level. That's not the same as encrypting Secrets inside etcd, which the API server does with its own key; Post 7 turns that on.

### Version and tooling: Kubernetes 1.35, OpenTofu, Cilium

- **Kubernetes 1.35** is the CKS exam's version as of November 2026, according to the [Linux Foundation's exam FAQ](https://docs.linuxfoundation.org/tc-docs/certification/faq-cka-ckad-cks). The [certification page](https://training.linuxfoundation.org/certification/certified-kubernetes-security-specialist/) already shows v1.37, so check before you book.
- **OpenTofu** is the open-source fork of Terraform. The lab's infrastructure as code is written in OpenTofu, and the scripts call `tofu` to apply it.
- **Cilium** is the CNI (Container Network Interface) plugin that gives pods their IPs and carries traffic between them. Later posts use it for NetworkPolicy enforcement and pod-to-pod encryption.

---

## Using the lab

With the design in place, the lab is driven from one console. It deploys into *your* AWS account, with *your* SSH key and IP; nothing here connects to my environment. Expect about $7–8 a month if you stop it between sessions. You need AWS CLI v2 with credentials, OpenTofu, OpenSSH and `curl`; the full [prerequisites](https://github.com/sean-mancho/k8s-hardening-lab/blob/ep01/infra/README.md) are in the repo. Clone the repo at this post's tag and run the console from the repo root:

```bash
git clone --branch ep01 https://github.com/sean-mancho/k8s-hardening-lab.git
cd k8s-hardening-lab
./infra/scripts/lab.sh                     # opens the lab console: a cks-lab> prompt
```

Inside the console:

```text
cks-lab> start                             # build or start the lab, check first boot
cks-lab> init                              # optional: bootstrap the cluster for you (or use the manual process)
cks-lab> ssh worker                        # shell on any node; the jumps happen automatically
cks-lab> stop                              # stop the instances (or quit, which offers to)
```

- **`lab.sh`** is your base terminal: start the lab, `ssh` into a node, and `exit` back to the prompt. `start` asks which IP may SSH in, defaulting to your current one, and runs `tofu apply`. It never passes `-auto-approve`, so you can **read the plan** before you type `yes`. It then starts the instances and regenerates `infra/ssh_config`, because the edge gets a new public IP on every start. Finally it waits for each instance's first boot and prints `ready` for each.
- **`kubectl` runs on the control plane** (`ssh control-plane`).
- **`delete` destroys the lab** when you're done or taking a long break.

**After `start`, you choose how the cluster gets built.** `start` brings up the machines, not Kubernetes. On a new lab, there's no cluster yet, and `start` ends by listing your two ways to build it:

- **Manual process**, recommended the first time, because you see every step: run `kubeadm init` from a config file, install Cilium, then `kubeadm join` the worker. [Sections 3–5 of the build guide](https://github.com/sean-mancho/k8s-hardening-lab/blob/ep01/infra/README.md#3-initialize-the-control-plane) walk through each command.
- **In one go**: type `init` at the `cks-lab>` prompt. It runs the same steps over SSH and skips any that are already done, so it's safe to rerun. Use it for rebuilds, or when you want to get straight to the hardening.

Either way you end up with the same cluster. A stopped lab keeps its cluster, so later sessions need only `start`.

The [cost breakdown](https://github.com/sean-mancho/k8s-hardening-lab/blob/ep01/infra/README.md#costs) and teardown are covered in `infra/README.md`. Run `stop` at the end of every session.

---

## Accepted risks and alternatives

A study cluster should be reliable rather than clever, so the lab accepts a few risks on purpose, and the capstone uses them as the attacker's starting points:

- **Open egress.** The edge's outbound rule is "all traffic" and its NAT accepts every protocol from the nodes. Post 5 tightens that at the edge and pairs it with the in-cluster version of the same control, an egress NetworkPolicy.
- **Convenience ports between nodes.** The NodePort range 30000–32767, ICMP and Cilium's Hubble port are open between the nodes so services and debugging work without fuss.
- **No VPC flow logs.** There's no network-level record of who talked to whom.
- **Host keys trusted on first use.** The repo shows [how to verify them](https://github.com/sean-mancho/k8s-hardening-lab/blob/ep01/infra/README.md#verifying-the-host-keys) against each instance's console output.
- **A forwarded SSH agent: the risk to watch.** Your agent is forwarded to the control plane so `ssh k8s-worker` and `scp` work from there. While you're connected, root on that host can use **every key loaded in it**, not only the lab key, so a GitHub key or any other key in the same agent is exposed too. Load only the lab key while you work. `ssh-add -c` makes each use ask for your confirmation, but it needs an `ssh-askpass` program, which macOS doesn't include. Post 6 looks at `AllowAgentForwarding` and the alternatives.

**An alternative worth knowing:** inbound SSH itself could go entirely, replaced by EC2 Instance Connect Endpoint or SSM Session Manager. But SSM needs an IAM instance profile the lab doesn't have yet, and the nodes would still need the edge for egress, so a combined bastion/NAT keeps the lab to one box.

---

## Next up

Once it's built, you have a private Kubernetes lab of your own to troubleshoot, break and rebuild as often as you like. Explore it, and get to know every component and its security implications before the series starts changing them.

The next post, out Tuesday, November 10, scores this fresh cluster against the CIS Kubernetes Benchmark with kube-bench and verifies the platform binaries installed here. The [repo README](https://github.com/sean-mancho/k8s-hardening-lab/tree/ep01#how-the-series-builds-on-the-lab) maps every post to the part of the lab it builds on.

Follow the series to get it in your feed. Questions or improvements? Drop them in the comments, or open an issue on the repo.
