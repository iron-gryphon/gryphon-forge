# Ignition Role

Wraps `openshift-install` to generate OpenShift ignition configuration files for UPI deployment.

## Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `install_dir` | Directory for installer artifacts | `../installer/{{ cluster_name }}` |
| `pull_secret_path` | Path to Red Hat pull secret JSON | `~/.openshift/pull-secret` |
| `ssh_public_key_path` | Path to SSH public key | `~/.ssh/id_rsa.pub` |
| `cluster_name` | OpenShift cluster name | - |
| `base_domain` | Base DNS domain | - |
| `foundry_private_subnets` | List of subnet IDs for platform.aws | - |
| `foundry_region` | AWS region | `us-east-2` |
| `master_count` | Number of control plane nodes | 3 |
| `worker_count` | Worker nodes provisioned by `aws_nodes` (EC2 + `worker.ign`); **not** `install-config` compute replicas (those stay `0` for UPI) | 3 |

After `openshift-install create manifests`, this role removes `openshift/99_openshift-cluster-api_master-machines*.yaml`, `worker-machineset*.yaml`, and `99_openshift-machine-api_master-control-plane-machine-set.yaml` so the Machine API does not fight UPI (matches [OpenShift AWS UPI manifest steps](https://github.com/openshift/installer/blob/master/docs/user/aws/install_upi.md) manifest edits). `install-config` sets `networkType: OVNKubernetes` and default pod/service CIDRs explicitly.

When `foundry_internal_hosted_zone_id` is set, `install-config` includes `platform.aws.hostedZone` so the installer emits `dnses.config.openshift.io/cluster` with `spec.privateZone.id`. The post-create patch (when `ignition_patch_dns_aws_private_zone` is true) updates the same field only—never `spec.platform.aws.privateZone`, which is not part of the OpenShift 4.20+ API and can prevent bootstrap from applying DNS/cluster (MCO then errors on a missing DNS object). Scheduler `mastersSchedulable: false` is applied only when `worker_count + gpu_worker_count > 0` so compact clusters keep the installer default schedulable masters.

### IngressController post-create patch (Forge NLB vs ALB)

Forge can expose the default router with an **internal NLB** whose target groups health-check **TCP 80 and 443 on the worker instances**. The installer default `endpointPublishingStrategy` for AWS often uses a **LoadBalancerService**-style publishing path where the router does **not** listen on the node’s host **:443** the way those NLB checks expect, so targets stay unhealthy and cluster operators that reach `*.apps` on **:443** see **connection refused**.

After `openshift-install create manifests`, this role can patch `IngressController/default`:

| Variable | Effect |
|----------|--------|
| `ignition_ingress_endpoint_publishing_hostnetwork` | When **true** and **`foundry_ingress_certificate_arn` is empty** (NLB path, no ACM/ALB), set `spec.endpointPublishingStrategy` to **`type: HostNetwork`** with `hostNetwork.httpPort` / `hostNetwork.httpsPort` (defaults **80** / **443**) so the router binds on the same ports the Forge NLB targets. **Disabled automatically** when an ACM cert ARN is set so the ALB/HTTPS path is unchanged. |
| `ignition_ingress_hostnetwork_http_port` / `ignition_ingress_hostnetwork_https_port` | Override host ports when using HostNetwork (defaults match the CRD and Forge NLB target groups). |
| `ignition_ingress_hostnetwork_router_replicas_merge` | When **true** and the same **HostNetwork + NLB** conditions apply, set **`spec.replicas`** on `IngressController/default` so router pod count matches worker capacity (Forge NLB target groups register every worker; the installer default of **2** routers can leave half the targets unhealthy). |
| `ignition_ingress_hostnetwork_router_replicas` | Integer replica count for the default router when `ignition_ingress_hostnetwork_router_replicas_merge` is true. **Empty** (default): **`max(2, worker_count + gpu_worker_count)`** so you keep at least two for HA while scaling up. |
| `ignition_ingress_default_dns_management_unmanaged` | When **true**, merge `loadBalancer.dnsManagementPolicy: Unmanaged` into the existing strategy—used on the **ALB** path (or if HostNetwork is off) so OpenShift does not fight Forge-owned **\*.apps** Route53 records. |

`spec.endpointPublishingStrategy` is replaced or merged as above; when the NLB HostNetwork replica merge runs, **`spec.replicas`** is set on the same manifest. Other `spec` fields are preserved. Re-running the patch is idempotent for a given variable set.

## Prerequisites

- Network access to `forge_ocp_mirror_base_url` / `forge_ocp_mirror_channel` on the controller (Linux or macOS), **or** set `openshift_install_binary_path` and `openshift_client_binary_path` to absolute paths (same OCP z-stream as `ocp_version`)
- Valid pull secret from [Red Hat OpenShift Installer-Provisioned (AWS)](https://console.redhat.com/openshift/install/aws/installer-provisioned) — download and save to `~/.openshift/pull-secret` (or set `PULL_SECRET_PATH`)
- SSH public key for node access

## Disconnected mirror (optional)

| Variable | Description | Default |
|----------|-------------|---------|
| `mirror_registry_url` | Private registry host for release payload | `""` |
| `mirror_registry_use_image_digest_sources` | Use `imageDigestSources` + `ImageDigestMirrorSet` (vs legacy ICSP) | `true` |
| `openshift_install_release_image_override` | Full image ref (`registry/repo@sha256:…` or `:tag`) | `""` |
| `ignition_mirror_discover_release_tag` | If `true`, discover highest tag for `ocp_version` minor (e.g. `4.20.*-x86_64`) on the mirror; **do not** set `openshift_install_release_image_override` | `true` |
| `ignition_mirror_discover_release_arch` | Arch suffix in tag (e.g. `x86_64`) | `x86_64` |
| `ignition_mirror_discover_delegate_to_bastion` | Run discovery from bastion when present (recommended; mirror often only reachable from VPC) | `true` |

Discovery runs `scripts/discover-mirror-release-tag.sh` (needs `jq`; uses `skopeo` if installed, else `curl` to the registry v2 API). It does **not** query Red Hat “stable channel” metadata—only semver sort of tags present on your mirror.

## Outputs

Generates in `install_dir`:
- `install-config.yaml` (backed up as `install-config.yaml.bak`)
- `bootstrap.ign`
- `master.ign`
- `worker.ign`
