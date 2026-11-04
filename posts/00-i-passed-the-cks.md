---
title: "I Passed the CKS. Now I'm Hardening My Own Cluster."
published: true
description: "What the CKS exam is really like, how I studied, what the retakes taught me, and the hands-on series that comes next."
series: Hardening Kubernetes from Scratch
tags: kubernetes, security, certification, career
cover_image:
---

**TL;DR**

- I passed the CKS! It took a few tries, and every retake taught me something.
- It's simulation-based: real tasks in live clusters, no multiple choice. Open book doesn't buy you time, so pacing is everything.
- It leans hard on Linux and containers, not just Kubernetes. Hands-on time in a real cluster beats memorizing commands.
- Next up: I'm building my own lab cluster on AWS and working through every exam domain, one post a week.

![Certified Kubernetes Security Specialist (CKS) certificate issued to Sean Mancho by the Cloud Native Computing Foundation, October 2026](https://dev-to-uploads.s3.us-east-2.amazonaws.com/uploads/articles/nce4by6vlckxjgpxbcw8.png)

## Why I took it

Honestly? I find security genuinely interesting. More and more runs on Kubernetes these days (AI model serving, event streaming, edge deployments), and new container vulnerabilities show up all the time. I wanted to understand how those workloads get locked down at the infrastructure and network layers.

I also like using certifications as a study plan. They give me a clear target and keep me current on the tooling, the docs and the community around it. The CKS felt like the right way to go from knowing how Kubernetes runs to knowing how to secure it.

## What the exam is really like

The CKS is a two-hour, online, proctored exam, and it's simulation-based. There's no multiple choice to fall back on: every question is a real task you solve on the command line in a live cluster. You need the CKA first, and the cert is good for two years. Details are current as of October 2026; check the [Linux Foundation CKS page](https://training.linuxfoundation.org/certification/certified-kubernetes-security-specialist/) for the latest.

That format is why pacing matters so much: you get roughly six to eight minutes per task, so there's no time to wander. It's open book, so the Kubernetes docs (and the docs for the exam's tools) are fair game, but that doesn't buy you time. Finding something in the docs is easy. Finding it fast enough is the hard part. It's also tempting to sink twenty minutes into one stubborn problem and leave yourself scrambling through the rest of the exam. (More on that below.)

What surprised me most was how much of it isn't Kubernetes. It leans just as hard on Linux and container fundamentals. Here are the six domains it covers:

| Domain | Weight | What it covers |
|---|---|---|
| Cluster Setup | 15% | Network policies, CIS Benchmark review of etcd, kubelet and kube-apiserver, Ingress with TLS, protecting node metadata and endpoints, verifying platform binaries |
| Cluster Hardening | 15% | Restricting API access, RBAC, service account hygiene, keeping Kubernetes upgraded |
| System Hardening | 10% | Reducing the host OS attack surface, least-privilege IAM, limiting external network access, AppArmor and seccomp |
| Minimize Microservice Vulnerabilities | 20% | Pod Security Standards, Secrets management, isolation and sandboxing (gVisor, Kata Containers), Pod-to-Pod encryption (Cilium, Istio) |
| Supply Chain Security | 20% | Minimal base images, SBOMs, image signing and permitted registries, static analysis (Kubesec, KubeLinter) |
| Monitoring, Logging and Runtime Security | 20% | Behavioral analytics with Falco, container immutability at runtime, Kubernetes audit logs |

*Domains and weights are from the official curriculum; the tool examples are mine.*

## How I studied

If I had to pick one thing, it's hands-on time in a real cluster. Reading about a topic feels productive, but doing it over and over is what actually sticks. Minikube is fine for quick practice, but I built my own control plane and worker and secured them myself, which gave me a lot more to poke at. Nothing teaches hardening like hardening a cluster you built yourself.

Everything else supported that:

- **Video courses (KodeKloud, Udemy)** for the lectures. Great for the big picture and for giving your study plan some structure.
- **My own notes** to make it stick. After each lesson I summarized what I'd learned in my own words and sketched the architecture, so I understood how the pieces fit together. Any gap in the notes pointed straight at a gap in my understanding, and the notes became my go-to reference.
- **Practice exams (Killercoda, Killer.sh)** for timing. They're the closest thing to the real exam, both in difficulty and in time pressure.

## Lessons from the retakes

The CKS is genuinely hard, and a light understanding won't get you through it. It didn't get me through, either: it took me a few attempts to pass. I treated each one as feedback, not failure. Every attempt showed me where my studying was off and which skills had gaps, so I could sharpen exactly those before the next try.

**Pacing.** Remember that twenty-minute trap? Avoiding it was lesson one. By the end, I treated the clock as part of the exam: a time budget for every task, quick wins first, flag anything that stalls, and come back to it at the end.

**How layered it is.** One task can touch Kubernetes, the Linux host and the container runtime all at once. Kubernetes fundamentals are the base, but securing a cluster means working underneath it too. My gaps were in Linux and containers, so that's where I spent my time between retakes. It paid off: when a task stalls, those basics are what keep analysis paralysis away. If a service won't come up, I know to grep its logs with `journalctl`. If I need a container ID, `crictl ps` (or `docker ps`, depending on the node) gets me there. Knowing my next move takes a lot of the anxiety out of the clock.

**Knowing which tool to reach for.** This was the big one. It stopped being about memorizing commands and became about how to approach a problem: where to look first and which tool fits the job. That changed how I used the docs, too. Instead of searching around for answers, I knew exactly what to look for.

## What's next

Passing felt great, but I didn't want everything I learned to just sit in my notes. So to keep building on it, I'm hardening my own lab cluster, built from scratch on AWS. The notes and code are written for AWS, but the Kubernetes side carries over to any cloud provider (or your own hardware) with a few adjustments. From there, I'll work through hands-on examples for each exam domain, one post every Tuesday. First the build and a kube-bench baseline, then a domain at a time, and at the end a capstone where I try to break in and see if I get caught.

This series is also my way of keeping a record of the work, with every config, script and lesson learned in one place.

The schedule is in the repo, and the code lands there with each post: [github.com/sean-mancho/k8s-hardening-lab](https://github.com/sean-mancho/k8s-hardening-lab)

## Honorable mentions

- **[The Kubernetes docs](https://kubernetes.io/docs/home/).** My home base, both while studying and during the exam. The concept pages explain the *why* behind each feature really thoroughly, and the task pages are full of YAML manifests you can copy as a starting template. That made them my quickest reference when I needed a NetworkPolicy or a SecurityContext in a hurry.
- **[Kubernetes the Hard Way](https://github.com/kelseyhightower/kubernetes-the-hard-way) by Kelsey Hightower.** It really makes you think about how a cluster fits together. There's no kubeadm or bootstrapping tool doing the work for you, so you set up every piece yourself: the certificates, etcd, the control plane and the kubelets. Once you've wired it up by hand, it's much clearer what kubeadm automates and where things can go wrong.

Next up: building the lab.
