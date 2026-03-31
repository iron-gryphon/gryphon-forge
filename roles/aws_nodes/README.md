# AWS Nodes Role

Provisions EC2 instances, internal Load Balancers (NLB/ALB), and Route53 DNS records for the OpenShift UPI cluster in the Vault.

## Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `foundry_vpc_id` | VPC ID from gryphon-foundry | - |
| `foundry_private_subnets` | List of private subnet IDs | - |
| `foundry_bastion_security_group_id` | SG for bastion/VPN access | - |
| `foundry_vault_api_security_group_id` | From gryphon-foundry `vault_api_security_group_id`; when set, attached to **bootstrap and master** ENIs with cluster SGs (API/MCS/etcd alignment) | - |
| `foundry_vault_security_group_id` | From gryphon-foundry `vault_security_group_id`; when set, attached to **bootstrap and master** ENIs (intra–Vault-VPC traffic) | - |
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
| `aws_nodes_rhcos_root_device_name` | Root block device `DeviceName` for `ec2_instance` volumes. **Must match the AMI’s `RootDeviceName`** from `aws ec2 describe-images` (or `amazon.aws.ec2_ami_info`). Empty (default): resolved automatically from the selected `rhcos_ami_id` / `aws_nodes_rhcos_ami_id_resolved`. | `""` (auto) |
| `aws_nodes_verify_root_ebs_size_after_launch` | After launch, call `ec2_instance_info` / `ec2_vol_info` and assert root EBS on the resolved device is ≥ `aws_nodes_*_root_volume_size_gb` per `role` tag | `false` |
| `aws_nodes_bootstrap_root_volume_size_gb` | Bootstrap node root EBS size (gp3) | `120` |
| `aws_nodes_master_root_volume_size_gb` | Control plane root EBS size (gp3) | `120` |
| `aws_nodes_worker_root_volume_size_gb` | Worker root EBS size (gp3) | `120` |
| `aws_nodes_gpu_worker_root_volume_size_gb` | GPU worker root EBS size (gp3) | `120` |

### Root disk size (bootstrap, masters, workers)

OCP 4.x needs enough **ephemeral / root** space for container images, etcd data (masters), and kubelet thresholds. The RHCOS AMI default root volume is often ~16 GiB, which leads to **DiskPressure**, evictions, and failed static pods (for example apiserver or controller-manager) during bootstrap. The role sets an explicit **gp3** root volume (default **120 GiB**) on bootstrap, masters, workers, and GPU workers, aligned with Red Hat and AWS UPI sizing practice.

**Root `DeviceName` is AMI-specific (do not assume `/dev/xvda`).** In the EC2 API, `RunInstances` block device mappings must use the same `DeviceName` as the image’s **`RootDeviceName`** (`describe-images`). If you map a different name (for example `/dev/xvda` while the AMI root is `/dev/sda1`), AWS attaches an **extra** EBS volume; the instance still boots from the original small root, and the kubelet’s `ephemeral-storage` capacity stays at the default (~16 GiB). Gryphon Forge resolves the device name from the chosen RHCOS AMI by default; override `aws_nodes_rhcos_root_device_name` in `group_vars` only when you must force a value that still **matches** `RootDeviceName` for that AMI. To validate sizing after `amazon.aws.ec2_instance` runs, set `aws_nodes_verify_root_ebs_size_after_launch: true`.

### EC2 tags and AWS cloud-controller-manager (ClusterID)

`aws-cloud-controller-manager` needs a cluster scope on each node’s EC2 instance. It looks for a tag of the form **`kubernetes.io/cluster/<CLUSTER_INFRA_ID>=owned`** (or legacy `KubernetesCluster`), where **`CLUSTER_INFRA_ID` is the OpenShift installer `infraID`** — the same value in `metadata.json` next to `clusterName` / `clusterID` (produced by `openshift-install create ignition-configs`). Gryphon Forge sets that tag on bootstrap, masters, workers, and GPU workers (the tag key is built at template time from the resolved `infraID`, not as a literal string). Override the ID only if you must point at a fixed value without `metadata.json` on the controller: `aws_nodes_openshift_infrastructure_id`.

When a node ENI has **multiple** security groups (for example Forge `<cluster>-master-sg` plus optional **`foundry_vault_api_security_group_id`** / **`foundry_vault_security_group_id`** from gryphon-foundry), AWS CCM also expects the **cluster node security group** Forge creates to carry **`kubernetes.io/cluster/<infraID>=owned`**. Forge applies that tag with `amazon.aws.ec2_tag` to the bootstrap, master, and worker SGs after resolving `infraID`; it does **not** add it to foundry-supplied SGs. If ingress or load balancer sync still misbehaves immediately after retagging, restarting **`openshift-cloud-controller-manager`** / **`aws-cloud-controller-manager`** may help (AWS provider caching around security group tags).

**Clusters already deployed with a wrong cluster tag or cloud config:** If EC2 instances were tagged with a literal or incorrect `kubernetes.io/cluster/...` key, or if `openshift-config/cloud-provider-config` / `kube-system/kube-cloud-cfg` (or equivalent) still reference the wrong `ClusterID`, AWS CCM will not match nodes to the cluster. Fix by retagging every OCP EC2 instance with **`kubernetes.io/cluster/<infraID>=owned`** where `<infraID>` matches `metadata.json`, aligning the in-cluster cloud provider config to that same `infraID`, or by destroying and reinstalling with a corrected playbook.

## Tasks

1. **EC2 Prerequisites**: Resolve RHCOS AMI (priority: `rhcos_ami_id` → copy from `rhcos_ami_source_id` → fetch from metadata); resolve **`RootDeviceName`** for block device mappings via `amazon.aws.ec2_ami_info` when `aws_nodes_rhcos_root_device_name` is empty; create EC2 key pair when not set
2. **Ignition S3**: Upload bootstrap/master/worker ignition to S3; create IAM roles and instance profiles. AWS user data is limited to 16KB; ignition configs often exceed this, so a stub referencing `s3://bucket/ignition.ign` is passed instead. **Bootstrap** uses `{{ cluster_name }}-ignition-reader` (S3 read only). **Masters** use `{{ cluster_name }}-ocp-master` (same S3 read plus OpenShift UPI master cloud-provider policy from `openshift/installer` `03_cluster_security.yaml` so `aws-cloud-controller-manager` can call EC2/ELB APIs). **Workers and GPU workers** use `{{ cluster_name }}-ocp-worker` (S3 read plus minimal `ec2:DescribeInstances` / `ec2:DescribeRegions`). Existing clusters created with the old single-profile layout need new instance profiles applied (replace IAM profile on instances or redeploy nodes) for CCM to clear `node.cloudprovider.kubernetes.io/uninitialized`.
3. **Security Groups**: Create SGs for bootstrap, masters, workers (see **Security group matrix** below)
4. **EC2 Instances**: Resolve `infraID` (see table above), tag Forge bootstrap/master/worker SGs with **`kubernetes.io/cluster/<infraID>=owned`** for AWS CCM when ENIs use multiple groups, then launch bootstrap, master, worker, and optional GPU worker nodes with the same tag on instances plus `Name` / `cluster` / `role`. Bootstrap and master ENIs use `<cluster>-bootstrap-sg` / `<cluster>-master-sg` **plus** optional `foundry_vault_api_security_group_id` and `foundry_vault_security_group_id` when foundry outputs supply them. Each launch supplies a **single** root `volumes` entry at `aws_nodes_rhcos_root_device_name_resolved` (AMI `RootDeviceName`) with the configured gp3 size. Optional: `aws_nodes_verify_root_ebs_size_after_launch` asserts DescribeVolumes size vs `aws_nodes_*_root_volume_size_gb` per `role` tag.
5. **Load Balancers**: Create one internal **API NLB** for **api-int** with listeners **6443** (Kubernetes API) and **22623** (Machine Config Server). Masters pull Ignition from `https://api-int:22623/config/master`, so **22623 must be on the same hostname** Route53 aliases to (`api` / `api-int` → `{{ cluster_name }}-api`). A separate `{{ cluster_name }}-mcs` NLB is removed on apply (legacy). Ingress uses ALB (443/80) or NLB. NLBs use **cross-zone load balancing** so traffic from any AZ can reach bootstrap in one subnet. Bootstrap and masters register on the API target group via **instance IDs from EC2 launch**; bootstrap alone registers on **{{ cluster_name }}-mcs-tg** for :22623. If you run only `--tags load_balancers`, registration uses `ec2_instance_info` with retries until nodes appear.
6. **Route53**: Register api, api-int, and *.apps records (aliases to the API NLB and ingress LB) in `foundry_internal_hosted_zone_id`.
7. **LB validation snapshot** (when `aws_nodes_lb_validation_enabled`): Writes `forge-lb-validation/...` artifacts under `install_dir`. Optional bastion DNS/TCP probes (`bastion-diagnostics.txt`) run only when `aws_nodes_lb_validation_from_bastion` is true (default false). On failure, the **csr_approver** role runs the same probes via `bastion_lb_diagnostics.yml` into the failure log directory or `csr-fail/<cluster>-<epoch>/` under the bastion install path.

## Idempotency

All tasks use `amazon.aws` modules with proper `state` and `name` parameters to ensure idempotent runs.

**Root volume size:** `amazon.aws.ec2_instance` supplies `BlockDeviceMappings` only when **launching** new instances. It does **not** resize an existing instance’s root EBS volume when you increase `aws_nodes_*_root_volume_size_gb`. Clusters already running with small disks need either **EBS modify-volume** (then extend the filesystem on the node per RHCOS/AWS guidance) or **replace** the instances (destroy/recreate or rolling replacement) so new launches pick up the larger size.

## Security group matrix (bootstrap etcd and control plane)

Forge applies security groups **before** EC2 launch (`security_groups.yml` then `ec2_instances.yml`), so rules exist before nodes boot. The **bootstrap** node runs temporary etcd; **control-plane** nodes must open TCP **2379** (client) and **2380** (peer) to the bootstrap **private IP** until etcd membership migrates after `openshift-install wait-for bootstrap-complete`. Forge does **not** terminate the bootstrap instance before that wait succeeds (teardown is `destroy_cluster.yml` only).

| Traffic | Source | Target SG | Ports | Notes |
|---------|--------|-----------|-------|--------|
| NLB health / in-VPC API | Vault VPC primary IPv4 CIDR (from EC2 `DescribeVpcs`, else `foundry_vault_vpc_cidr`) | `<cluster>-bootstrap-sg` | 6443, 22623 | Same CIDR as master API ingress; NLB has no SG |
| SSH / API / MCS from Nest | `foundry_nest_vpc_cidr` (optional) | bootstrap | 22, 6443, 22623 | Bastion over peering |
| SSH / API / MCS from bastion | `foundry_bastion_security_group_id` (optional) | bootstrap | 22, 6443, 22623 | |
| RFC1918 SSH (legacy) | 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 | bootstrap | 22 | |
| **etcd bootstrap join** | Vault VPC CIDR | bootstrap | **2379–2380** | Masters in private subnets reach bootstrap etcd |
| **etcd bootstrap join** | `<cluster>-master-sg` | bootstrap | **2379–2380** | Explicit reference to control-plane SG (merged with `purge_rules: false`) |
| API / MCS / kubelet / etcd (in-cluster) | Vault VPC CIDR | `<cluster>-master-sg` | 6443, 22623, 10250, **2379–2380** | Ingress **to** masters (peer etcd); egress uses the module default allow-all unless you override elsewhere |
| SSH to masters | Vault CIDR, Nest, bastion SG, RFC1918 | master | 22 | |

**Bootstrap IP and ignition:** Master ignition references the bootstrap machine’s **private IP** for initial etcd endpoints. If the bootstrap instance is **replaced** and gets a new ENI address, regenerate ignition and reprovision masters (or align AWS so the bootstrap IP matches what the cluster expects). Running only `--tags ec2` after replacing bootstrap without re-running **ignition** can strand the cluster with a stale bootstrap address.

**Egress:** `amazon.aws.ec2_security_group` leaves **egress open** (allow all) when `rules_egress` is omitted, which covers control-plane **egress** to the bootstrap IP on 2379/2380. Tightening master egress is possible but must preserve that path (and image pulls, etc.).
