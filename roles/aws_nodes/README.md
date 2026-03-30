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
| `aws_nodes_openshift_infrastructure_id` | Installer **infraID** for `kubernetes.io/cluster/<infraID>=owned` on every OCP EC2 instance. Empty (default): read `infraID` from `{{ install_dir }}/metadata.json` after ignition | `""` |

### EC2 tags and AWS cloud-controller-manager (ClusterID)

`aws-cloud-controller-manager` needs a cluster scope on each node’s EC2 instance. It looks for a tag of the form **`kubernetes.io/cluster/<CLUSTER_INFRA_ID>=owned`** (or legacy `KubernetesCluster`), where **`CLUSTER_INFRA_ID` is the OpenShift installer `infraID`** — the same value in `metadata.json` next to `clusterName` / `clusterID` (produced by `openshift-install create ignition-configs`). Gryphon Forge sets that tag on bootstrap, masters, workers, and GPU workers. Override the ID only if you must point at a fixed value without `metadata.json` on the controller: `aws_nodes_openshift_infrastructure_id`.

## Tasks

1. **EC2 Prerequisites**: Resolve RHCOS AMI (priority: `rhcos_ami_id` → copy from `rhcos_ami_source_id` → fetch from metadata); create EC2 key pair when not set
2. **Ignition S3**: Upload bootstrap/master/worker ignition to S3; create IAM roles and instance profiles. AWS user data is limited to 16KB; ignition configs often exceed this, so a stub referencing `s3://bucket/ignition.ign` is passed instead. **Bootstrap** uses `{{ cluster_name }}-ignition-reader` (S3 read only). **Masters** use `{{ cluster_name }}-ocp-master` (same S3 read plus OpenShift UPI master cloud-provider policy from `openshift/installer` `03_cluster_security.yaml` so `aws-cloud-controller-manager` can call EC2/ELB APIs). **Workers and GPU workers** use `{{ cluster_name }}-ocp-worker` (S3 read plus minimal `ec2:DescribeInstances` / `ec2:DescribeRegions`). Existing clusters created with the old single-profile layout need new instance profiles applied (replace IAM profile on instances or redeploy nodes) for CCM to clear `node.cloudprovider.kubernetes.io/uninitialized`.
3. **Security Groups**: Create SGs for bootstrap, masters, workers
4. **EC2 Instances**: Resolve `infraID` (see table above), then launch bootstrap, master, worker, and optional GPU worker nodes with **`kubernetes.io/cluster/<infraID>=owned`** plus `Name` / `cluster` / `role`
5. **Load Balancers**: Create one internal **API NLB** for **api-int** with listeners **6443** (Kubernetes API) and **22623** (Machine Config Server). Masters pull Ignition from `https://api-int:22623/config/master`, so **22623 must be on the same hostname** Route53 aliases to (`api` / `api-int` → `{{ cluster_name }}-api`). A separate `{{ cluster_name }}-mcs` NLB is removed on apply (legacy). Ingress uses ALB (443/80) or NLB. NLBs use **cross-zone load balancing** so traffic from any AZ can reach bootstrap in one subnet. Bootstrap and masters register on the API target group via **instance IDs from EC2 launch**; bootstrap alone registers on **{{ cluster_name }}-mcs-tg** for :22623. If you run only `--tags load_balancers`, registration uses `ec2_instance_info` with retries until nodes appear.
6. **Route53**: Register api, api-int, and *.apps records (aliases to the API NLB and ingress LB) in `foundry_internal_hosted_zone_id`.
7. **LB validation snapshot** (when `aws_nodes_lb_validation_enabled`): Writes `forge-lb-validation/...` artifacts under `install_dir`. Optional bastion DNS/TCP probes (`bastion-diagnostics.txt`) run only when `aws_nodes_lb_validation_from_bastion` is true (default false). On failure, the **csr_approver** role runs the same probes via `bastion_lb_diagnostics.yml` into the failure log directory or `csr-fail/<cluster>-<epoch>/` under the bastion install path.

## Idempotency

All tasks use `amazon.aws` modules with proper `state` and `name` parameters to ensure idempotent runs.
