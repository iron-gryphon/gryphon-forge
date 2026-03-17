# AWS Nodes Role

Provisions EC2 instances, internal Load Balancers (NLB/ALB), and Route53 DNS records for the OpenShift UPI cluster in the Vault.

## Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `foundry_vpc_id` | VPC ID from gryphon-foundry | - |
| `foundry_private_subnets` | List of private subnet IDs | - |
| `foundry_bastion_security_group_id` | SG for bastion/VPN access | - |
| `foundry_internal_hosted_zone_id` | Route53 hosted zone for internal DNS | - |
| `install_dir` | Path to ignition files | - |
| `cluster_name` | OpenShift cluster name | - |
| `base_domain` | Base DNS domain | - |
| `master_count` | Number of control plane nodes | 3 |
| `worker_count` | Number of worker nodes | 3 |
| `gpu_worker_count` | Number of GPU worker nodes | 1 |

## Tasks

1. **Security Groups**: Create SGs for bootstrap, masters, workers
2. **EC2 Instances**: Launch bootstrap, master, worker, and optional GPU worker nodes
3. **Load Balancers**: Create internal NLBs for API (6443) and Machine Config Server (22623), ALB for ingress (443/80)
4. **Route53**: Register api, api-int, and *.apps records

## Idempotency

All tasks use `amazon.aws` modules with proper `state` and `name` parameters to ensure idempotent runs.
