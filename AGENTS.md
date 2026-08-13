# Gryphon Forge — Agent Collaboration Guide

This document helps AI agents understand and collaborate on the **gryphon-forge** project.

## Project Summary

**gryphon-forge** is an Ansible-based orchestration project that deploys Red Hat OpenShift Container Platform (OCP) using **User-Provisioned Infrastructure (UPI)**. It consumes outputs from `gryphon-foundry` to build a production-grade, air-gapped cluster in AWS (the "Vault").

**Transition:** "Empty VPC" → "Functional Cluster"

## Architecture

| Stage | Responsibility |
|-------|----------------|
| **Configuration** | Node counts (Master, Worker, GPU), instance sizing |
| **Ignition** | Fetch pull secrets, generate OpenShift ignition files via `openshift-install` |
| **Provisioning** | Deploy EC2 nodes into Vault private subnets |
| **Networking** | Internal NLBs/ALBs, Route53 records for API and Ingress |
| **Bootstrap** | Approve CSRs, wait for cluster operators to stabilize |
| **Validation** | Post-install health checks |

## Key Paths & Files

| Path | Purpose |
|------|---------|
| `inventory/group_vars/all.yml` | Main configuration (foundry outputs, cluster metadata, node counts) |
| `inventory/hosts.yml` | Host inventory (local, bootstrap, masters, workers, gpu_workers) |
| `playbooks/deploy_cluster.yml` | Main deployment playbook |
| `playbooks/destroy_cluster.yml` | Teardown playbook |
| `roles/ignition/` | Ignition generation (wraps `openshift-install`) |
| `roles/aws_nodes/` | EC2, ELB, Route53 provisioning |
| `roles/csr_approver/` | CSR approval during bootstrap |
| `roles/validation/` | Post-install validation |
| `foundry_output.json` | Consumed from gryphon-foundry (VPC, subnets, SG, hosted zone) |

## Dependencies

- **Tools:** `ansible` in `$PATH`; `openshift-install`, `oc`, and (when `forge_oc_mirror_install_enabled`) `oc-mirror` are placed under `install_dir/bin/` on the controller (Linux mirror download) and `bastion_install_dir/bin/` on the bastion, unless overridden via `openshift_install_binary_path` / `openshift_client_binary_path` / `openshift_oc_mirror_binary_path` (controller oc-mirror only; pinned path is copied into `install_dir/bin/oc-mirror`)
- **Ansible collections:** `amazon.aws`, `community.aws`, `kubernetes.core`, `community.general`, `ansible.posix` (see `requirements.yml`)
- **Secrets:** Pull secret at `~/.openshift/pull-secret` (or `PULL_SECRET_PATH`), SSH public key at `~/.ssh/id_rsa.pub`

## Playbook Tags

Use tags to run specific stages:

```bash
ansible-playbook playbooks/deploy_cluster.yml --tags "ignition"      # Ignition only
ansible-playbook playbooks/deploy_cluster.yml --tags "ec2"           # EC2 provisioning
ansible-playbook playbooks/deploy_cluster.yml --tags "csr_approval"  # CSR approval
ansible-playbook playbooks/deploy_cluster.yml --tags "validation"    # Validation only
```

## Validation & Testing

**Before committing changes**, run these validation commands locally (they mirror the GitHub Actions workflow):

```bash
# 1. Install collections (if not already done)
ansible-galaxy collection install -r requirements.yml

# 2. Syntax check all playbooks
ansible-playbook playbooks/deploy_cluster.yml --syntax-check
ansible-playbook playbooks/destroy_cluster.yml --syntax-check

# 3. Run ansible-lint
ansible-lint
```

**Optional — validate foundry JSON before deploy** (loads JSON locally; also calls **Route53** `GetHostedZone` to confirm the internal zone is associated with `vault_vpc_id` — requires AWS credentials):

```bash
ansible-playbook playbooks/preflight.yml -i inventory/hosts.yml \
  -e foundry_preflight_path=../gryphon-foundry/foundry_output.json
```

In **gryphon-foundry**, after `terraform output -json > foundry_output.json`, run `./scripts/check-foundry-json-for-forge.sh foundry_output.json` (requires `jq`).

**After making changes**, agents must:

1. **Run validation** — Execute the commands above to ensure changes pass.
2. **Fix reported issues** — Address any `ansible-lint` or syntax errors before considering the task complete.
3. **Update tests when needed** — If you add roles, playbooks, or change structure:
   - Add new playbooks to the syntax-check loop in `.github/workflows/ansible-validation.yml`.
   - Adjust `.ansible-lint` exclusions or profile if new patterns require it.
   - Update this section if validation commands change.

## Conventions for Agents

1. **Idempotency:** All roles must be idempotent. Tasks should be safe to run multiple times.
2. **Immutable nodes:** OCP nodes are immutable. Use MachineConfigs for OS changes, not direct Ansible on nodes.
3. **State awareness:** Keep Ansible inventory in sync with physical AWS resources.
4. **Linting:** Use `ansible-lint` for playbooks and roles.
5. **Modularity:** Add new roles under `roles/` with a `README.md` and `defaults/main.yml`.
6. **Validation:** Run validation commands (syntax check, ansible-lint) before committing; update the workflow and this guide when adding playbooks or changing validation logic.

## Foundry Integration

This project expects `foundry_output.json` (or Terraform remote state) with:

- `vault_vpc_id`, `private_subnet_ids`, `bastion_security_group_id`, `internal_hosted_zone_id`, `region`
- Optional: `ocp_base_domain`, `ocp_cluster_name`, `vault_vpc_cidr`, `vault_vpc_amazon_provided_dns`, `ocp_api_int_fqdn`, `create_ocp_private_zone`, `ocp_route53_zone_source` (see `deploy_cluster.yml` first play for normalization; Route53 outputs align with gryphon-foundry `outputs.tf`)

**Preferred:** Pass via `-e @foundry_output.json` to avoid modifying `inventory/group_vars/all.yml`:

```bash
ansible-playbook playbooks/deploy_cluster.yml -e @foundry_output.json
```

Variables are overridden in the first play of `deploy_cluster.yml` from: 1) `include_vars` (if file at `foundry_output_path` exists), 2) `-e @foundry_output.json`, 3) `all.yml` defaults.

## Troubleshooting: OAuth, console, and `install-complete`

OAuth and the console are **different paths**. Do not assume an OAuth/API-NLB-only fix addresses **console** HTTPS or **`console-openshift-console.apps`** probes.

### (a) `oauth-openshift.apps` — ingress (4.21+ default) vs API NLB express lane (older OCP)

The **cluster-authentication-operator** often reconciles the `oauth-openshift` **Route** with `spec.port.targetPort` **`6443`** (pod port) while the **Service** publishes **`443` → 6443**. If that hostname resolves to the **ingress router** with that passthrough shape, the router must forward to **oauth-openshift** pod backends correctly. Historically, pointing **`oauth-openshift.apps`** at the **default `*.apps`** ingress broke because traffic hit the router on **6443** without a valid backend — stalled **`install-complete`** on **authentication**, OAuth failures, TLS **unexpected EOF** ([issues #23](https://github.com/iron-gryphon/gryphon-forge/issues/23) and [#24](https://github.com/iron-gryphon/gryphon-forge/issues/24)).

**OpenShift 4.21+** ([issue #30](https://github.com/iron-gryphon/gryphon-forge/issues/30)): if **`oauth-openshift.apps`** resolves to the **API NLB** (kube-apiserver on **6443**), unauthenticated **`GET /oauth/authorize`** can return **403** (`system:anonymous`), and **console login** fails. Forge therefore defaults **`forge_oauth_apps_via_api_nlb`** to **`false`** for **`ocp_version`** **4.21 and later**: **Route53** aliases **`oauth-openshift.apps.<cluster>.<domain>`** to the **same target as `*.apps`** (ingress NLB or ACM ALB). Browsers then see **ingress/router TLS** for that hostname (trust that chain like other app routes). **`ignition_oauth_apps_api_named_certificate`** defaults the same way (no APIServer named cert for OAuth when DNS uses ingress).

**Older OCP (Forge default `forge_oauth_apps_via_api_nlb: true`):** keep the **API NLB express lane** (infrastructure; do not patch the OAuth Route):

1. **API NLB** (`<cluster>-api`) exposes TCP **443** forwarding to **`<cluster>-oauth-tg`**, which registers **control-plane** instances on **6443** (same kube-apiserver path as the API).
2. **Route53** — explicit alias **`oauth-openshift.apps.<cluster>.<domain>`** → **API NLB** (more specific than `*.apps`).
3. **Control-plane security groups** allow **6443** from the Vault VPC CIDR (NLB health checks and forwarded traffic).
4. After **`wait-for bootstrap-complete`**, **csr_approver** deregisters **bootstrap** from **`<cluster>-api-tg`** and **`<cluster>-mcs-tg`** (toggle: `csr_approver_deregister_bootstrap_from_api_mcs_after_complete`). The **oauth-tg** remains on masters.
5. **TLS** — traffic to **`oauth-openshift.apps…`** is **kube-apiserver** on **6443**, so the server must present a **SAN** for that hostname. The **ignition** role adds **`APIServer`** `spec.servingCerts.namedCertificates` plus a **`kubernetes.io/tls`** Secret in **`openshift-config`**, and merges the CA into **`install-config` `additionalTrustBundle`** (**`additionalTrustBundlePolicy: Always`**). Material: **`{{ install_dir }}/.forge/oauth-apps-api-tls/`**. Toggle: **`ignition_oauth_apps_api_named_certificate`**.

**Checks (a)**

```bash
dig +short oauth-openshift.apps.<cluster>.<domain>
# API path: listener 443 on <cluster>-api → oauth-tg. Ingress path: same targets as *.apps ingress.
aws elbv2 describe-listeners --load-balancer-arn <api-nlb-arn> --query 'Listeners[?Port==`443`]'   # empty when express lane disabled
oc get route oauth-openshift -n openshift-authentication -o jsonpath='{.spec.port.targetPort}{"\n"}'
openssl s_client -connect oauth-openshift.apps.<cluster>.<domain>:443 -servername oauth-openshift.apps.<cluster>.<domain> </dev/null 2>/dev/null | openssl x509 -noout -subject -ext subjectAltName
oc get clusteroperator authentication
```

**Validation** probes `https://oauth-openshift.apps.<cluster>.<domain>/` and records the result in `validation-report.txt` (`validation_check_oauth_apps_connectivity`).

**Workstations:** for the **API NLB** path, trust Forge’s OAuth/API cert chain (or your replacement). For the **ingress** path, trust the **ingress** chain. Cluster **`additionalTrustBundle`** applies to **nodes and cluster components**, not necessarily the browser.

### (b) `console-openshift-console.apps` and other routes → `*.apps` → ingress NLB/ALB

The **console** operator (and most application Routes) use hostnames under **`*.apps.<cluster>.<domain>`**, which Forge points at the **ingress** load balancer (NLB or ACM ALB), **not** the API NLB. **`openshift-install wait-for install-complete`** can fail with **console** **Degraded** / **RouteHealth** when the HTTPS probe to **`https://console-openshift-console.apps…/`** returns **503** even though **ingress** target groups show healthy workers — that points to **ingress/router → console Service/backend** (or in-cluster TLS/reencrypt), **VPC/peering reachability** from a bastion outside the Vault, or other cluster issues. The **(a)** paths and **`ignition_oauth_apps_api_named_certificate`** (when used) do **not** reroute or fix the console URL by themselves.

**Useful checks (b)** — from a host that can reach Vault ingress (often a node or bastion in the right network): `oc get co console ingress`, `oc describe route console -n openshift-console`, ingress target group health in AWS for **`…-ingress-443-tg`**. For router backend detail: **`oc exec -n openshift-ingress deploy/router-default -- grep -i openshift-console /var/lib/haproxy/conf/haproxy.config`**; HAProxy stats may be on pod port **1936** if exposed.

- If ingress target groups are healthy but the console route still returns **503**, and TLS or TCP from **`router-default`** toward the **console pod IP** (for example **`:8443`**) **never completes**, confirm EC2 security groups allow **UDP 6081** between nodes in the Vault VPC (**OVN-Kubernetes GENEVE**). Forge adds this on master and worker SGs; existing clusters need the **`ec2` / `security_groups`** stage re-run or a manual AWS rule until Ansible is replayed.

### Disconnected clusters: `oc run` and debug images

On **air-gapped** clusters, **`oc run`** / ephemeral pods that pull **public** images (for example **`curlimages/curl`**) often **hang or fail** (`ImagePullBackOff`, **Condition ready** timeout) because the registry is unreachable. Prefer a **mirrored** image from your release/mirror, **`oc debug node/…`** / **`oc debug pod/…`**, **`oc exec`** into **`openshift-ingress`** **`router-default`**, or tools shipped in an image already on the cluster (for example the release payload tools image from your mirror).

### Optional Ansible hint after `install-complete` failure

Set **`csr_approver_emit_console_ingress_hints_on_install_failure: true`** to print short **(b)**-oriented **`oc`** / AWS / router commands (no secrets) when **`wait-for install-complete`** fails in the **csr_approver** role.

## Common Tasks

- **Add a new role:** Create `roles/<name>/` with `tasks/main.yml`, `defaults/main.yml`, `README.md`.
- **Change node counts:** Edit `inventory/group_vars/all.yml` (`master_count`, `worker_count`, `gpu_worker_count`).
- **Add a playbook tag:** Add `tags:` to the relevant role in `deploy_cluster.yml`.
