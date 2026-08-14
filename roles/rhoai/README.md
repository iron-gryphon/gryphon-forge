# RHOAI Role

Day-2 install of **Red Hat OpenShift AI** on a Gryphon Forge cluster: cluster prep,
default StorageClass / EBS CSI checks, optional mirrored CatalogSource/IDMS apply,
operator subscriptions, `DSCInitialization`, `DataScienceCluster`, and verification.

## Playbook

```bash
# 1) (Disconnected) Mirror operators + workbench images on the Nest bastion
./scripts/mirror-rhoai.sh

# 2) Install RHOAI (runs on bastion when foundry provides one)
ansible-playbook playbooks/install_rhoai.yml -i inventory/hosts.yml \
  -e @../gryphon-foundry/foundry_output.json \
  -e foundry_output_path=../gryphon-foundry/foundry_output.json \
  -e bastion_ssh_private_key_path=../gryphon-foundry/bastion-key.pem \
  -e rhoai_apply_mirror_resources=true \
  -e rhoai_mirror_resources_dir=/home/ec2-user/oc-mirror-workspace-rhoai/working-dir/cluster-resources
```

## Tags

| Tag | Stage |
|-----|--------|
| `prep` | kubeconfig, API, nodes, workers, cluster operators |
| `storage` | EBS CSI + default StorageClass + optional PVC smoke test |
| `mirror_resources` | Apply oc-mirror IDMS/ITMS/CatalogSource YAMLs |
| `operators` | cert-manager → optional mesh/GPU → rhods-operator |
| `dsc` | DSCI then DSC |
| `verify` | Dashboard route + report |
| `rhoai` | All of the above |

## Key variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `rhoai_channel` | `stable-3.4` | rhods-operator channel |
| `rhoai_starting_csv` | `""` | Optional CSV pin |
| `rhoai_install_cert_manager` | `true` | Required for RHOAI 3.x |
| `rhoai_install_servicemesh` | `false` | OSSM3 (gateway / 2.x-style) |
| `rhoai_install_gpu_stack` | `gpu_worker_count > 0` | NFD + NVIDIA GPU Operator |
| `rhoai_ensure_default_storage_class` | `true` | Create/annotate default SC |
| `rhoai_storage_class_name` | `gp3-csi` | Created when no default exists |
| `rhoai_storage_smoke_test` | `true` | Bind a 1Gi PVC then delete |
| `rhoai_apply_mirror_resources` | `false` | Apply `rhoai_mirror_resources_dir` |
| `rhoai_mirror_ca_pem` | foundry trust bundle | DSCI `customCABundle` |

See `defaults/main.yml` for DSC component toggles and timeouts.

## Order of operations

1. **prep** — cluster must be healthy with enough workers.
2. **storage** — require `ebs.csi.aws.com` ClusterCSIDriver; ensure a default StorageClass (`gp3-csi` if needed); optional PVC smoke test.
3. **mirror_resources** (optional) — apply oc-mirror outputs so PackageManifests exist.
4. **operators** — cert-manager, optional Service Mesh / NFD / GPU, then `rhods-operator`.
5. **dsc** — DSCI (wait Ready) then DSC (wait Ready).
6. **verify** — dashboard route; write `rhoai-install-report.txt`.

## References

- [docs/RHOAI-disconnected-install.md](../../docs/RHOAI-disconnected-install.md)
- [rh-aiservices-bu/disconnected-rhoai](https://github.com/rh-aiservices-bu/disconnected-rhoai)
- [redhat-ai-services/ai-accelerator](https://github.com/redhat-ai-services/ai-accelerator)
