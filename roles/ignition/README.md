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
| `foundry_region` | AWS region | `us-east-1` |
| `master_count` | Number of control plane nodes | 3 |
| `worker_count` | Number of worker nodes | 3 |

## Prerequisites

- `openshift-install` binary in `$PATH` (version matching `ocp_version`)
- Valid pull secret from [Red Hat OpenShift Installer-Provisioned (AWS)](https://console.redhat.com/openshift/install/aws/installer-provisioned) — download and save to `~/.openshift/pull-secret` (or set `PULL_SECRET_PATH`)
- SSH public key for node access

## Outputs

Generates in `install_dir`:
- `install-config.yaml` (backed up as `install-config.yaml.bak`)
- `bootstrap.ign`
- `master.ign`
- `worker.ign`
