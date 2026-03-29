# AWS Nodes Role

Provisions EC2 instances, internal Load Balancers (NLB/ALB), and Route53 DNS records for the OpenShift UPI cluster in the Vault.

## Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `foundry_vpc_id` | VPC ID from gryphon-foundry | - |
| `foundry_private_subnets` | List of private subnet IDs | - |
| `foundry_bastion_security_group_id` | SG for bastion/VPN access | - |
| `foundry_internal_hosted_zone_id` | Route53 hosted zone for internal DNS | - |
| `foundry_region` | AWS region | - |
| `install_dir` | Path to ignition files | - |
| `cluster_name` | OpenShift cluster name | - |
| `base_domain` | Base DNS domain | - |
| `ec2_key_name` | AWS EC2 key pair name | Auto-created as `{{ cluster_name }}-forge-key` when empty |
| `rhcos_ami_id` | RHCOS AMI for the region | Auto-fetched, copied from source, or set manually |
| `rhcos_ami_source_id` | Source AMI to copy (Option 1 for disconnected) | - |
| `rhcos_ami_source_region` | Source region for AMI copy | `foundry_region` when empty |
| `master_count` | Number of control plane nodes | 3 |
| `worker_count` | Number of worker nodes | 3 |
| `gpu_worker_count` | Number of GPU worker nodes | 1 |
| `aws_nodes_lb_target_discovery_retries` | EC2 describe retries when registering NLB targets (`--tags load_balancers`) | 40 |
| `aws_nodes_lb_target_discovery_delay` | Seconds between retries | 8 |

## Tasks

1. **EC2 Prerequisites**: Resolve RHCOS AMI (priority: `rhcos_ami_id` → copy from `rhcos_ami_source_id` → fetch from metadata); create EC2 key pair when not set
2. **Ignition S3**: Upload bootstrap/master/worker ignition to S3; create IAM role for EC2 to fetch. AWS user data is limited to 16KB; ignition configs often exceed this, so a stub referencing `s3://bucket/ignition.ign` is passed instead.
3. **Security Groups**: Create SGs for bootstrap, masters, workers
4. **EC2 Instances**: Launch bootstrap, master, worker, and optional GPU worker nodes
5. **Load Balancers**: Create internal NLBs for API (6443) and Machine Config Server (22623), ALB for ingress (443/80). NLBs enable **cross-zone load balancing** so traffic to any AZ’s NLB node can reach the bootstrap in a single subnet (required until control plane serves 6443 in every AZ). Bootstrap and masters are registered on the API target group using **instance IDs from the EC2 launch tasks** (avoids tag-filter lag on a fresh apply). If you run only `--tags load_balancers`, registration uses `ec2_instance_info` with retries until nodes appear.
6. **Route53**: Register api, api-int, and *.apps records (aliases to the API NLB and ingress LB) in `foundry_internal_hosted_zone_id`.
7. **LB validation snapshot** (when `aws_nodes_lb_validation_enabled`): Writes `forge-lb-validation/...` artifacts and optional bastion DNS/TCP checks — runs **after** Route53 so `api-int` resolves during diagnostics on a full `aws_nodes` run.

## Idempotency

All tasks use `amazon.aws` modules with proper `state` and `name` parameters to ensure idempotent runs.
