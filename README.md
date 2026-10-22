# Hardening Kubernetes from Scratch

A hands-on study guide for the CKS (Certified Kubernetes Security Specialist), built on a real cluster.
If you're preparing for the exam, this series walks through each domain the way I wish I'd had it: one
topic per post, hands-on in a private two-node kubeadm lab on AWS, with the commands, YAML and checks
you can run yourself.

Every post covers two things:

- **For the exam:** what the CKS expects, how to do it quickly, and how to verify it worked.
- **In practice:** how the same control is rolled out, tested and maintained on a real cluster.

The code arrives with the posts: the lab build and setup instructions land with Post 1 on 2026-10-27,
then each post adds its manifests, so you can follow along, break things and try again. Questions and
suggestions are welcome as GitHub issues.

## Posts

One post every Tuesday. Each post's code is tagged `epNN`, so you can check out the lab as it was at
that post. Titles of upcoming posts may change.

| # | Date | Post | CKS domain | Code |
|---|---|---|---|---|
| 0 | 2026-10-22 | I Passed the CKS. Now I'm Hardening My Own Cluster. | Overview | — |
| 1 | 2026-10-27 | Building a Private Kubernetes Lab on AWS | Cluster Setup | `infra/` |
| 2 | 2026-11-03 | Bootstrapping the Cluster and a CIS Baseline | Cluster Setup | |
| 3 | 2026-11-10 | Locking Down API Access | Cluster Hardening | |
| 4 | 2026-11-17 | Upgrading the Cluster | Cluster Hardening | |
| 5 | 2026-12-01 | Controlling Network Traffic | Cluster Setup | |
| 6 | 2026-12-08 | Hardening the Host | System Hardening | |
| 7 | 2026-12-15 | Hardening Workloads | Minimize Microservice Vulnerabilities | |
| 8 | 2027-01-05 | Encrypting Pod-to-Pod Traffic | Minimize Microservice Vulnerabilities | |
| 9 | 2027-01-12 | Supply Chain, Part 1: Building Safer Images | Supply Chain Security | |
| 10 | 2027-01-19 | Supply Chain, Part 2: Controlling What Runs | Supply Chain Security | |
| 11 | 2027-01-26 | Audit Logs: Who Did What? | Monitoring, Logging and Runtime Security | |
| 12 | 2027-02-02 | Runtime Security with Falco | Monitoring, Logging and Runtime Security | |
| 13 | 2027-02-09 | Capstone: Break In, Get Caught | All | |

Breaks: 2026-11-24 (US Thanksgiving) and 2026-12-22 to 12-29 (holidays).

## Layout

The repo fills in as the series goes:

```text
posts/       article sources (dev.to markdown)
infra/       OpenTofu code and lab scripts (from Post 1)
manifests/   each post's YAML and policies (from Post 2)
runbooks/    one runbook per post's ops task
evidence/    sanitized kube-bench reports, scan output, audit samples
```

## License

Code is MIT-licensed (see [LICENSE](LICENSE)). Article text in `posts/` © Sean Mancho.
