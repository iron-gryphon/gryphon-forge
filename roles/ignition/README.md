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
| `worker_count` | Number of worker nodes | 3 |

## Prerequisites

- Network access to `forge_ocp_mirror_base_url` / `forge_ocp_mirror_channel` on the controller (Linux or macOS), **or** set `openshift_install_binary_path` and `openshift_client_binary_path` to absolute paths (same OCP z-stream as `ocp_version`)
- Valid pull secret from [Red Hat OpenShift Installer-Provisioned (AWS)](https://console.redhat.com/openshift/install/aws/installer-provisioned) — download and save to `~/.openshift/pull-secret` (or set `PULL_SECRET_PATH`)
- SSH public key for node access

## Disconnected mirror (optional)

| Variable | Description | Default |
|----------|-------------|---------|
| `mirror_registry_url` | Private registry host for release payload | `""` |
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
