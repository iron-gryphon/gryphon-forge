# CSR Approver Role

Watches for pending Certificate Signing Requests (CSRs) from Kubelet during OpenShift bootstrap and automatically approves them.

## Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `kubeconfig_path` | Path to admin kubeconfig | `{{ install_dir }}/auth/kubeconfig` |
| `csr_approval_timeout` | Max seconds to wait for cluster ready | 3600 |
| `csr_check_interval` | Seconds between CSR checks | 30 |
| `csr_approver_dns_resolution_retries` | Attempts for `getent hosts` on api-int (Route53/VPC DNS propagation) | 12 |
| `csr_approver_dns_resolution_delay` | Seconds between DNS check attempts after a failure | 30 |
| `csr_approver_connectivity_timeout` | Seconds to wait for API TCP 6443 before MCS check | 300 |
| `csr_approver_mcs_connectivity_timeout` | Seconds to wait for Machine Config Server TCP 22623 on api-int (master Ignition) | 300 |
| `csr_approver_skip_api_tg_preflight` | Skip controller-side check that `*-api-tg` has registered targets | false |
| `csr_approver_gather_on_failure` | When bootstrap fails, gather logs and fetch to controller | true |
| `csr_approver_gather_failure_dest` | Override path for gathered logs; default `install_dir/bootstrap-failure-logs/<cluster>-<epoch>` on the controller | (none) |
| `csr_approver_bastion_lb_diagnostics_on_failure` | On CSR/bootstrap/API/install-complete failure, write `bastion-diagnostics.txt` (aws_nodes `bastion_lb_diagnostics.yml`) | true |
| `csr_approver_bootstrap_etcd_master_tcp_probe` | On bootstrap failure with gather enabled, also write `master-to-bootstrap-etcd-tcp.txt` (SSH from bastion or localhost to first master as `core`, `/dev/tcp` to bootstrap :2379/:2380; needs OCP SSH key) | false |
| `csr_approver_bootstrap_etcd_tcp_preflight` | Before `wait-for bootstrap-complete`, SSH to first master as `core` and open TCP to bootstrap private IP **2379** and **2380** (retries; set `false` to skip) | true |
| `csr_approver_etcd_tcp_preflight_retries` | Attempts for the master→bootstrap etcd TCP preflight | 36 |
| `csr_approver_etcd_tcp_preflight_delay` | Seconds between preflight attempts | 10 |
| `csr_approver_repair_oauth_openshift_route` | During `install-complete`, patch `oauth-openshift` Route if `targetPort` is wrongly `6443` (must match `oauth-openshift` **Service** port `443`, usually name `https`; [issue #23](https://github.com/iron-gryphon/gryphon-forge/issues/23)). Uses Service discovery when `csr_approver_repair_oauth_openshift_route_target_port` is empty. By default uses exponential backoff between patches, throttles repeated stdout warnings, and stops after caps (see below). Each revert cycle appends a timestamped line (including Route `metadata.resourceVersion`) to `{{ install_dir }}/.gryphon-oauth-route-revert.log`. If caps are hit, the script fails with instructions to capture Route YAML and authentication-operator logs for Red Hat / upstream (see [issue #24](https://github.com/iron-gryphon/gryphon-forge/issues/24) for TLS/router EOF after the Route is correct). | true |
| `csr_approver_repair_oauth_openshift_route_max_attempts` | Maximum `oc patch` attempts per `approve-and-wait.sh` run | `40` |
| `csr_approver_repair_oauth_openshift_route_max_reverts` | Fail after this many re-patches following a revert (6443 after a prior patch in the same run) | `12` |
| `csr_approver_repair_oauth_openshift_route_warn_interval_seconds` | Minimum seconds between repeated WARNING lines when the route keeps reverting | `300` |
| `csr_approver_repair_oauth_openshift_route_backoff_initial_seconds` | Initial delay before the next patch is allowed when `csr_approver_repair_oauth_openshift_route_interval_seconds` is **0** (doubles each patch, capped) | `30` |
| `csr_approver_repair_oauth_openshift_route_backoff_max_seconds` | Maximum backoff between patches (interval mode **0** only) | `600` |
| `csr_approver_repair_oauth_openshift_route_interval_seconds` | When **greater than zero**, re-patch scheduling uses this fixed interval (seconds) instead of exponential backoff while `wait-for install-complete` runs. **0** keeps the default backoff behavior. | `0` |
| `csr_approver_repair_oauth_openshift_route_pre_wait_patch` | When **true**, run one oauth route repair (if the Route exists and `targetPort` is `6443`) immediately **before** starting `openshift-install wait-for install-complete`, then continue with the usual loop. | `false` |
| `csr_approver_repair_oauth_openshift_route_target_port` | Force Route `spec.port.targetPort` (e.g. `https` or `443`). Empty: read Service port `443` name via `oc`, else `https` | `""` |

### OAuth Route repair: if the operator keeps winning

If `targetPort` returns to `6443` repeatedly after patches, capture `oc get route oauth-openshift -n openshift-authentication -o yaml` and authentication-operator logs for Red Hat support. As a **last resort** (disrupts authentication during the window), some operators temporarily scale down `deployments/authentication-operator` in `openshift-authentication` during install so a manual Route fix can stick—this is risky and not automated by Forge. Prefer a **z-stream** or support guidance that addresses the reconciliation bug ([issue #23](https://github.com/iron-gryphon/gryphon-forge/issues/23)). If `targetPort` is already `https`/`443` but you still see TLS/router errors toward OAuth, treat that as an ingress or OVN path ([issue #24](https://github.com/iron-gryphon/gryphon-forge/issues/24)).

## Connectivity validation

Before waiting for bootstrap completion, the role validates:

1. **DNS resolution** — `api-int.<cluster>.<base_domain>` must resolve (retries with `csr_approver_dns_resolution_delay` to allow Route53 / VPC DNS propagation).
2. **API NLB targets (controller)** — Unless `csr_approver_skip_api_tg_preflight` is true, queries AWS for `<cluster>-api-tg` and fails fast if there are no registered targets (avoids a long bastion `wait_for` when the NLB has nothing to forward to).
3. **TCP connectivity** — Ports **6443** and **22623** on `api-int` must be reachable (MCS on 22623 serves master Ignition; same NLB as API in gryphon-forge).
4. **Master → bootstrap etcd** — Unless `csr_approver_bootstrap_etcd_tcp_preflight` is false, verifies the first control-plane node can open **2379** and **2380** to the bootstrap private IP (validates SG/NACL path end-to-end after MCS is up).

If either check fails, the role fails with a clear message instead of blocking on `openshift-install wait-for bootstrap-complete`. When `csr_approver_bastion_lb_diagnostics_on_failure` is true, those failures also record bastion-side `getent`/TCP probes under `{{ csr_approver_install_dir }}/csr-fail/<cluster>-<epoch>/`.

When bootstrap fails and `csr_approver_gather_on_failure` is true, the role:

1. Runs `openshift-install gather bootstrap` and fetches `.openshift_install.log` plus the log bundle from bastion to the controller at `install_dir/bootstrap-failure-logs/<cluster>-<epoch>/`
2. Inspects the API target group (`<cluster>-api-tg`) and bootstrap instance in AWS, writing `aws-inspection-report.txt` with target health status and instance state for troubleshooting
3. Optionally (`csr_approver_bootstrap_etcd_master_tcp_probe: true`) records `master-to-bootstrap-etcd-tcp.txt` with bootstrap instance details and TCP probes from a control-plane node toward bootstrap etcd

## Prerequisites

- `oc` CLI in `$PATH`
- Bootstrap node running; API server reachable
- Security groups allow API (6443) from bastion/Nest VPC when using bastion
- Admin kubeconfig generated by `openshift-install wait-for bootstrap-complete`

## Usage

Run with tag `csr_approval` to execute only this role:

```bash
ansible-playbook -i inventory/sandbox playbooks/deploy_cluster.yml --tags "csr_approval"
```
