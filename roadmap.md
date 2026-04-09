# Gryphon Forge — Roadmap and lessons learned (Vault / UPI OpenShift)

This document summarizes the **evolution of gryphon-forge** as reflected in **git history**: the rough order in which capabilities landed, and **lessons learned** while driving an air-gapped OpenShift deployment in the Vault (User-Provisioned Infrastructure on AWS, fed by **gryphon-foundry** outputs).

It is not a substitute for operational runbooks; see `AGENTS.md` and role `README.md` files for day-to-day detail.

---

## Roadmap we followed (phases)

The commits cluster into a practical sequence from “empty repo” to “install-complete capable” in the Vault.

### 1. Foundation and quality gates

- **Initial structure** — Project skeleton, README, inventory/playbook layout, and baseline documentation.
- **CI and validation** — Ansible syntax checks, `ansible-lint`, and GitHub Actions so changes stay merge-safe (`fix/ansible-validation`, ongoing workflow tweaks).
- **Lesson:** Fix validation early; every later change touches networking, TLS, and AWS—small YAML or variable mistakes are expensive to debug on a live cluster.

### 2. Foundry integration and preflight

- **Preflight playbook** — Validate `foundry_output.json` (and path resolution) before touching AWS or ignition.
- **Variable normalization** — Consistent handling of cluster name, base domain, and foundry-derived IDs across plays.
- **Lesson:** Treat **foundry output + Route53/VPC association** as a hard gate; mismatched zone or VPC IDs fail late and look like “OpenShift is broken” when the root cause is infrastructure input.

### 3. Disconnected (air-gapped) install path

- **Mirror registry** — TLS, URL normalization (including Terraform-shaped outputs), image validation, and ignition integration for disconnected installs.
- **Install media** — `openshift-install` / `oc` acquisition, certificate handling, macOS controller support, optional S3-backed ignition for EC2.
- **Bootstrap image digest** — Fixes aligned with reproducible, mirror-backed bootstrap.
- **Lesson:** Air-gap multiplies failure modes: **mirror TLS**, **image availability**, and **bootstrap/Ignition delivery** must be correct before debugging “cluster won’t form.” Prefer mirrored tooling and cluster-local debug paths over pulling public images at runtime.

### 4. AWS nodes: EC2, IAM, volumes, and tagging

- **IAM for nodes** — Instance profiles/policies suitable for OCP on AWS.
- **EC2 reality** — Root device name resolution, EBS sizing, infrastructure ID tagging, and destroy/teardown symmetry for load balancers.
- **CCM alignment** — Security group **tagging** so the cloud controller can manage AWS resources as OpenShift expects (issues around CCM expectations).
- **Lesson:** **Tagging and IAM** are part of the product contract with OpenShift on AWS, not optional hygiene. **Volume/root device** assumptions vary by AMI; bake verification into Ansible.

### 5. Load balancers, target groups, and bootstrap networking

- **NLB lifecycle** — Create/validate listeners and target groups; improve registration/pruning; health check tuning.
- **Bootstrap support** — Security groups and preflight tailored to bootstrap joining API/MCS paths; bastion-side diagnostics.
- **CSR approver integration** — API target group **preflight and health** before leaning on `oc`/`openshift-install` waits; DNS resolution hardening from the controller.
- **Lesson:** UPI success is often “**LB + SG + DNS** first.” If the API NLB or bootstrap targets are wrong, CSR approval and `wait-for` stages will fail no matter how good the Ignition files are.

### 6. Ingress: NLB, DNS, and the default IngressController

- **Ingress NLB** — Register workers, internal DNS for `*.apps`, readiness gating before declaring ingress targets healthy.
- **Manifest patching** — IngressController customization for NLB and private-zone-friendly DNS management (issue #22 thread).
- **Lesson:** **API** and **apps** are different traffic planes. Ingress must be validated independently—healthy target groups with a broken router/console path still block `install-complete`.

### 7. Machine config / cluster stability (DNS and workers)

- **Private zone and install-config** — Route53 private zone support, scheduler-related ignition/manifest work, and careful Jinja/YAML handling (regressions caught and repaired).
- **Worker bring-up** — Security groups for workers, SSH paths for operations, LB registration fixes (issue #15).
- **MCO/DNS class of issues** — DNS and worker scheduling-related fixes (issue #16 trajectory).
- **Lesson:** **install-config and generated YAML** are fragile under templating—lint and syntax-check are necessary but not sufficient; diff the rendered artifacts when behavior changes. **Workers** must be able to join and pass health checks for ingress and workloads.

### 8. CSR approval, etcd preflight, and bootstrap teardown

- **CSR script** — More efficient, clearer errors, better handling under failure.
- **Etcd preflight** — Tightened checks against **running** instances; refactors as behavior clarified.
- **Bootstrap deregistration** — Prune bootstrap from API/MCS (and related) target groups after bootstrap completes; align with OAuth/MCS expectations.
- **Failure diagnostics** — Gather bootstrap failure logs; AWS inspection helpers; improved log paths.
- **OAuth Route repair** — Backoff, limits, intervals, optional pre-wait patch, validation hooks—iterative hardening until authentication operator stabilized in real runs.
- **Lesson:** Bootstrap is a **state machine**: CSRs, etcd membership, and **LB registration** must be orchestrated in order. When `install-complete` stalls, **split the problem**: API vs OAuth vs console vs ingress backends.

### 9. OVN-Kubernetes, security groups, and cross-environment access

- **GENEVE (UDP 6081)** — Explicit SG rules between nodes for OVN-Kubernetes; without this, “healthy” ELB targets can still yield **503**-style console/route failures (documented in `AGENTS.md`).
- **Nest → Vault / ingress** — Additional rules so traffic from the Nest environment can reach ingress/NLB fronts safely (issue #29).
- **Lesson:** **Data plane ports** (GENEVE) are invisible in many checklists until console/routes fail. **Peered or adjacent VPCs** need explicit SG design—not only “same VPC” rules.

### 10. OAuth, console, and OpenShift 4.21+ behavior

- **OAuth via API NLB (“express lane”)** — Named certificates, `additionalTrustBundle`, Route53 split for `oauth-openshift.apps` vs `*.apps`—evolved through issues #23/#24 and related commits.
- **4.21+ default shift** — For newer OCP, default away from OAuth-over-API-NLB when that path returns **403** for unauthenticated OAuth endpoints; align DNS with ingress and adjust ignition/API cert toggles (issue #30, PR #32).
- **Console troubleshooting** — Clearer separation in docs and automation between OAuth fixes and **console** route health (still primarily ingress/router/backend).
- **Lesson:** **Never conflate OAuth and console.** Version-sensitive behavior in **authentication operator** and **Routes** means the “right” fix for 4.12 may be wrong for 4.21—encode version-aware defaults and validate both **OAuth** and **console** endpoints after changes.

### 11. Hardening and ongoing maintenance

- **Dependabot / Actions** — Routine bumps (e.g., `actions/cache`, checkout, setup-python) to keep CI current.
- **Documentation** — `AGENTS.md` and `.cursorrules` capture long-lived troubleshooting knowledge that first appeared as firefight commits.

---

## Cross-cutting lessons learned

| Theme | Takeaway |
|--------|-----------|
| **Inputs** | Lock **foundry JSON**, region, zones, and hosted zone IDs before cluster debugging. |
| **Air gap** | Mirror, TLS, and ignition delivery are prerequisites; validate early with dedicated playbooks/tasks. |
| **AWS + OCP** | IAM, SGs, tags, and LBs are part of the cluster contract—test **destroy** as well as **create**. |
| **Network overlays** | OVN GENEVE between nodes is required for sane service routing; verify SGs when routes “hang.” |
| **Split planes** | Diagnose **API**, **OAuth**, **ingress/apps**, and **console** separately. |
| **Version drift** | OAuth/API vs ingress defaults changed materially at **4.21+**—encode version-aware behavior. |
| **Automation humility** | CSR/OAuth “repair” loops are a safety net, not a substitute for correct DNS/LB/TLS design. |
| **CI** | Syntax + lint + periodic workflow updates reduce regression risk across roles. |

---

## Suggested future roadmap (maintenance)

These are natural extensions of the same history—not commitments:

- Keep **version-aware** defaults tested against one “current” and one “N-1” OCP for the Vault standard.
- Expand **validation** probes (OAuth, console, ingress) with explicit failure hints in automation output.
- Periodically re-audit **security groups** when adding VPC peers (Nest or other) or new node pools (GPU, etc.).

---

## Reference: notable merge themes in history

For traceability, major integration points in git include (among others): preflight and foundry wiring; disconnected/mirror support; IAM and CCM tagging; ingress NLB and IngressController patching; CSR and API target health; OAuth/API express lane and 4.21+ DNS defaults; GENEVE and Nest-facing ingress rules; ongoing CI/validation hardening.

When investigating a regression, **`git log --oneline --grep`**, issue numbers in branch names (e.g., `#22`, `#30`), and the troubleshooting section in `AGENTS.md` are the fastest bridges from symptom to intended behavior.
