# Architectural decisions (Gryphon Forge / Vault UPI)

This document records **important architectural and design decisions** reflected in **gryphon-forge** development (git history and merged fixes). For each decision: **context**, **options and tradeoffs**, **what we chose**, and **why that helps**.

It complements [`roadmap.md`](roadmap.md) (chronological lessons) and [`AGENTS.md`](AGENTS.md) (operational detail). Entries are not strict ADR numbering over time; they are grouped by concern.

---

## Table of contents

1. [Automation platform: Ansible-orchestrated UPI](#1-automation-platform-ansible-orchestrated-upi)
2. [Infrastructure contract: gryphon-foundry JSON + preflight](#2-infrastructure-contract-gryphon-foundry-json--preflight)
3. [Disconnected installs: mirror registry in the critical path](#3-disconnected-installs-mirror-registry-in-the-critical-path)
4. [Ignition delivery: optional S3-backed payloads](#4-ignition-delivery-optional-s3-backed-payloads)
5. [AWS load balancing: NLBs, target groups, and API vs apps split](#5-aws-load-balancing-nlbs-target-groups-and-api-vs-apps-split)
6. [Ingress on NLB: HostNetwork publishing and router replica alignment](#6-ingress-on-nlb-hostnetwork-publishing-and-router-replica-alignment)
7. [OAuth and DNS: API NLB “express lane” vs ingress (version-aware default)](#7-oauth-and-dns-api-nlb-express-lane-vs-ingress-version-aware-default)
8. [TLS: named certificates and trust bundle for OAuth-on-API scenarios](#8-tls-named-certificates-and-trust-bundle-for-oauth-on-api-scenarios)
9. [AWS CCM: security group tagging and IAM instance profiles](#9-aws-ccm-security-group-tagging-and-iam-instance-profiles)
10. [Bootstrap lifecycle: CSR automation, etcd checks, and bootstrap deregistration](#10-bootstrap-lifecycle-csr-automation-etcd-checks-and-bootstrap-deregistration)
11. [Resilience vs purity: OAuth Route “repair” and API target preflight](#11-resilience-vs-purity-oauth-route-repair-and-api-target-preflight)
12. [OVN-Kubernetes: explicit GENEVE (UDP 6081) security group rules](#12-ovn-kubernetes-explicit-geneve-udp-6081-security-group-rules)
13. [Cross-environment access: Nest (and peers) to Vault ingress](#13-cross-environment-access-nest-and-peers-to-vault-ingress)
14. [Quality: dedicated validation role and CI gates](#14-quality-dedicated-validation-role-and-ci-gates)

---

### 1. Automation platform: Ansible-orchestrated UPI

| | |
|--|--|
| **Context** | OpenShift UPI requires coordinated steps: ignition, EC2, LBs, DNS, bootstrap, and post-install checks. |
| **Options** | **(A)** Pure Terraform (foundry + cluster in one graph). **(B)** Ansible-only AWS provisioning. **(C)** **Split:** foundry provisions VPC/subnets; Ansible drives OCP-specific AWS objects, ignition, and procedural waits. |
| **Tradeoffs** | (A) Tight coupling and slower iteration on OCP quirks; (B) Reinvents stateful “day 0” flows Terraform is good at; (C) Clear boundary but two tools and a strict JSON contract. |
| **Decision** | **(C)** — Terraform/foundry for **network foundation**; Ansible for **OCP UPI** (roles: `ignition`, `aws_nodes`, `csr_approver`, `validation`). |
| **Benefits** | Foundry stays reusable; Forge can encode OpenShift- and issue-specific behavior (CSR, OAuth, ingress patches) without bloating Terraform. |

---

### 2. Infrastructure contract: gryphon-foundry JSON + preflight

| | |
|--|--|
| **Context** | Wrong VPC, subnet, or hosted zone IDs produce confusing failures deep in install. |
| **Options** | **(A)** Hand-edit `group_vars` only. **(B)** Require `-e @foundry_output.json` and optional **preflight** playbook (Route53/VPC checks). |
| **Tradeoffs** | (A) Error-prone; (B) Extra step and AWS credentials for full preflight. |
| **Decision** | **(B)** — Normalize variables in the first play; add **`playbooks/preflight.yml`** and path-resolution fixes (commit history: preflight addition and refactors). |
| **Benefits** | Fails **before** expensive provisioning; aligns every run with the same foundry output shape. |

---

### 3. Disconnected installs: mirror registry in the critical path

| | |
|--|--|
| **Context** | Vault is **air-gapped**; clusters cannot pull quay.io at runtime. |
| **Options** | **(A)** Document mirror setup only (manual). **(B)** First-class **mirror URL**, TLS, digest validation, and ignition/`install-config` integration in the **`ignition`** role. |
| **Tradeoffs** | (A) Repeatable failures in the field; (B) More Ansible complexity and mirror-specific edge cases (TLS, Terraform-shaped URLs). |
| **Decision** | **(B)** — Disconnected path hardened over many commits (mirror TLS, tag discovery, bootstrap image digest, validation). |
| **Benefits** | Installers get a **repeatable** disconnected path; fewer “works on my laptop” gaps. |

---

### 4. Ignition delivery: optional S3-backed payloads

| | |
|--|--|
| **Context** | EC2 user-data and regional patterns may require hosting ignition outside inline metadata. |
| **Options** | **(A)** User-data only. **(B)** Optional **S3**-backed ignition references where appropriate. |
| **Tradeoffs** | (A) Simpler but hits size/operational limits; (B) Another bucket/object lifecycle to secure and destroy. |
| **Decision** | **(B)** as an option (commits: S3-backed ignition support). |
| **Benefits** | Scales payload size and matches common AWS patterns; remains optional when not needed. |

---

### 5. AWS load balancing: NLBs, target groups, and API vs apps split

| | |
|--|--|
| **Context** | UPI needs highly available **kube-apiserver** (6443), **MCS/Ignition-related** paths, and **ingress** for apps/console hostnames. |
| **Options** | **(A)** Single LB for everything. **(B)** **Separate** API NLB (with distinct target groups/listeners) and **ingress** front (NLB or ACM **ALB** when cert ARN provided). |
| **Tradeoffs** | (A) Simpler topology, harder to map OpenShift’s split DNS and TLS stories; (B) More AWS objects, clearer mapping to Red Hat docs and troubleshooting. |
| **Decision** | **(B)** — Multiple listeners/target groups, health checks tuned over time; destroy playbook symmetry maintained. |
| **Benefits** | **API** and **apps** can be reasoned about independently; supports **internal** DNS and optional **ACM** ingress (see `ignition` defaults and `AGENTS.md`). |

---

### 6. Ingress on NLB: HostNetwork publishing and router replica alignment

| | |
|--|--|
| **Context** | Default cloud `LoadBalancer` ingress on AWS does not always match **internal NLB** + private DNS goals (issue #22 class). |
| **Options** | **(A)** Rely on default IngressController only. **(B)** Patch manifests: **HostNetwork**-style endpoint publishing so node ports match NLB targets; optionally **merge router `replicas`** with worker count so registered workers are not half-unhealthy. |
| **Tradeoffs** | (A) Fewer custom manifests; (B) Stronger coupling between Forge’s NLB registration model and cluster networking. |
| **Decision** | **(B)** — `ignition_ingress_endpoint_publishing_hostnetwork`, `ignition_ingress_hostnetwork_router_replicas_merge` (see `roles/ignition/defaults/main.yml`, README). |
| **Benefits** | **Ingress NLB health** aligns with **router pods** on workers; reduces mysterious **503** / unhealthy target churn. |

---

### 7. OAuth and DNS: API NLB “express lane” vs ingress (version-aware default)

| | |
|--|--|
| **Context** | The `oauth-openshift` Route and Service port layout interact badly with **wrong** DNS targets (issues #23, #24). OpenShift **4.21+** changed behavior when OAuth hostname hits **kube-apiserver** on 6443 (403 on unauthenticated OAuth paths — issue #30). |
| **Options** | **(A)** Always send `oauth-openshift.apps` to API NLB. **(B)** Always send it to **ingress** like other `*.apps` names. **(C)** **Default by `ocp_version`**, override via `forge_oauth_apps_via_api_nlb`. |
| **Tradeoffs** | (A) Works for older patterns with named API certs; breaks console login on 4.21+ for that DNS shape. (B) Fixes 4.21+ but diverges from historical express-lane design. (C) Slightly more complex mental model. |
| **Decision** | **(C)** — **Pre-4.21:** default API NLB path where Forge implements it; **4.21+:** default **ingress**-aligned DNS unless overridden. |
| **Benefits** | **Correct defaults per release** without abandoning operators on older trains; single knob to revert or experiment. |

---

### 8. TLS: named certificates and trust bundle for OAuth-on-API scenarios

| | |
|--|--|
| **Context** | When browsers hit **kube-apiserver** for `oauth-openshift.apps…`, the serving cert must **SAN** that hostname; nodes/components must **trust** the chain. |
| **Options** | **(A)** Manual cert injection outside automation. **(B)** Forge generates material, adds **APIServer** `namedCertificates`, creates the **Secret**, merges **`additionalTrustBundle`** with **`Always`** policy (`ignition_oauth_apps_api_named_certificate` tied to OAuth DNS mode). |
| **Tradeoffs** | (A) Operational burden and drift; (B) More moving parts in ignition; must stay in sync with DNS mode (disabled when OAuth uses ingress on 4.21+ default). |
| **Decision** | **(B)** when the API NLB OAuth path is active. |
| **Benefits** | **TLS errors and unexpected EOF** drop sharply for that path; trust is encoded in install-time config. |

---

### 9. AWS CCM: security group tagging and IAM instance profiles

| | |
|--|--|
| **Context** | OpenShift on AWS expects cloud integration to manage or reference SGs and instances consistently (issues #11 class). |
| **Options** | **(A)** Minimal tags; fixup by hand. **(B)** Ansible ensures **CCM-oriented tagging** on security groups and robust **IAM instance profiles** for nodes. |
| **Tradeoffs** | (B) Tag schema must track OpenShift/AWS CCM expectations. |
| **Decision** | **(B)** — SG tagging, IAM enhancements, EC2 tagging tied to infrastructure ID (commit threads: CCM, IAM, tagging). |
| **Benefits** | Fewer **degraded** cloud controllers and mysterious LB/SG drift after install. |

---

### 10. Bootstrap lifecycle: CSR automation, etcd checks, and bootstrap deregistration

| | |
|--|--|
| **Context** | Bootstrap nodes must join API/MCS paths, then leave them; CSRs must be approved; etcd must settle on control plane. |
| **Options** | **(A)** Fully manual `oc` steps. **(B)** **`csr_approver`** role: scripted CSR handling, **etcd** preflight against **running** instances, **deregister bootstrap** from API/MCS (and related) target groups after bootstrap-complete. |
| **Tradeoffs** | (B) Complex state machine; bugs can approve too early/late or deregister wrong targets. |
| **Decision** | **(B)** with toggles and iterative hardening (multiple commits). |
| **Benefits** | Repeatable **day-0**; reduces human error during the noisiest phase of install. |

---

### 11. Resilience vs purity: OAuth Route “repair” and API target preflight

| | |
|--|--|
| **Context** | Operators reconcile Routes; NLBs ignore unhealthy targets—clusters can **stall** with misleading symptoms. |
| **Options** | **(A)** Declarative-only: assume one apply is enough. **(B)** Add **preflight** (e.g. API TG must have healthy targets) and **bounded retry/repair** for known OAuth Route shapes, with diagnostics on failure. |
| **Tradeoffs** | (B) Can mask upstream bugs if misused; more Ansible logic to maintain. |
| **Decision** | **(B)** — API TG preflight/wait, OAuth Route repair with backoff/limits, optional hints when `install-complete` fails. |
| **Benefits** | **Faster time-to-green** in real networks; clearer **failure artifacts** when something is genuinely wrong. |

---

### 12. OVN-Kubernetes: explicit GENEVE (UDP 6081) security group rules

| | |
|--|--|
| **Context** | With **OVN-Kubernetes**, node-to-node overlay traffic uses **GENEVE**. Missing UDP **6081** between nodes causes traffic that looks like “ingress healthy but console 503”. |
| **Options** | **(A)** Rely on generic “allow all internal” rules. **(B)** Explicit **6081/UDP** between node SGs (masters/workers). |
| **Tradeoffs** | (A) Easy to get wrong in segmented SG designs; (B) Another port to document and audit. |
| **Decision** | **(B)** (commits: GENEVE SG enhancements; documented in `AGENTS.md`). |
| **Benefits** | Explains and prevents a **class** of post-install failures that ELB “healthy” does not surface. |

---

### 13. Cross-environment access: Nest (and peers) to Vault ingress

| | |
|--|--|
| **Context** | Operators or CI may reach the cluster from **outside** the Vault VPC (e.g. **Nest**), while NLBs and workers stay private. |
| **Options** | **(A)** Open wide ingress from `0.0.0.0/0`. **(B)** Allow **specific** CIDRs (e.g. Nest) to ingress NLB/listener paths while keeping least-privilege inside Vault. |
| **Tradeoffs** | (B) Requires maintaining CIDR variables when peering changes. |
| **Decision** | **(B)** — Targeted SG rules for Nest→ingress (issue #29 thread). |
| **Benefits** | **Operational access** without abandoning **least privilege** for the rest of the footprint. |

---

### 14. Quality: dedicated validation role and CI gates

| | |
|--|--|
| **Context** | Regressions in YAML, Jinja, or AWS task order are costly; install-config templating broke at least once (hosted zone Jinja fix). |
| **Options** | **(A)** Manual testing only. **(B)** **`ansible-lint` + syntax-check** in CI; **`validation`** role for post-install probes (e.g. OAuth connectivity with path awareness). |
| **Tradeoffs** | (B) CI maintenance; validation tasks need credentials/network to be meaningful. |
| **Decision** | **(B)** (workflows, validation role, OAuth probe logic tied to `forge_oauth_apps_via_api_nlb` / version). |
| **Benefits** | **Shorter feedback loops** on PRs; documented **acceptance-style** checks after deploy. |

---

## How to use this document

- **Implementing a change** that touches DNS, TLS, or LBs: read **§5–§8** and `AGENTS.md` together.
- **Adding a new VPC peer or jump network**: read **§12–§13** and extend SG variables deliberately.
- **Upgrading OCP major/minor**: re-validate **§7–§8** defaults and run **validation** probes.

---

## See also

- [`roadmap.md`](roadmap.md) — Phased history and lessons learned  
- [`AGENTS.md`](AGENTS.md) — Troubleshooting OAuth vs console, disconnected notes, validation commands  
- GitHub issues **#11, #15, #16, #20, #22, #23, #24, #29, #30** — Concrete motivators for several decisions above  
