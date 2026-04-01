# 🔨 gryphon-forge

**The automated assembly line for Red Hat OpenShift in the Vault.**

`gryphon-forge` is an Ansible-based orchestration project designed to deploy an OpenShift Container Platform (OCP) cluster using the **User-Provisioned Infrastructure (UPI)** method. It consumes the outputs from `gryphon-foundry` to build a production-grade, air-gapped cluster.

## 🎯 Project Objectives
The Forge is responsible for the transition from "Empty VPC" to "Functional Cluster":

1.  **Configuration:** Define node counts (Master, Worker, GPU) and instance sizing.
2.  **Ignition Generation:** Securely fetch pull secrets and generate OpenShift ignition files.
3.  **Provisioning:** Deploy EC2 nodes into the **Vault** private subnets.
4.  **Networking:** Create the internal NLBs/ALBs and Route53 records for the API and Ingress.
5.  **Bootstrap:** Automate the approval of Certificate Signing Requests (CSRs) and wait for cluster operators to stabilize.

## 🔌 Consuming Foundry Outputs
This project expects a `foundry_output.json` or access to the Terraform remote state of `gryphon-foundry`. Pass it via `-e @foundry_output.json` at runtime (do not commit it). It specifically requires:
* `vault_vpc_id`: To place the nodes.
* `vault_vpc_cidr`: CIDR of the Vault VPC (e.g. `10.1.0.0/16`); used for OpenShift `networking.machineNetwork`. Defaults to `10.1.0.0/16` if not provided.
* `private_subnet_ids` or `vault_private_subnet_ids` / `ocp_upi_subnet_ids`: For the multi-AZ distribution of nodes.
* `bastion_security_group_id`: To allow administrative access via the VPN.
* `internal_hosted_zone_id`: To register OCP DNS records (api, api-int, *.apps).
* `vault_vpc_amazon_provided_dns`: From foundry (`cidrhost(vault_vpc_cidr, 2)`); Forge prefers this for optional `dig` / bastion checks against the Vault resolver (same value workers use via AmazonProvidedDNS).
* `ocp_api_int_fqdn`: Expected `api-int.<ocp_cluster_name>.<ocp_base_domain>`; Forge asserts it matches install-config DNS when present.
* `create_ocp_private_zone` / `ocp_route53_zone_source`: Describe how the zone was created (foundry private zone vs existing Route53); informational in Forge, documented for operators.
* `ocp_base_domain`: (Optional) When set by foundry, overrides `base_domain` so DNS records align with the hosted zone. Required when using internal domains (e.g. fsi.internal) with gryphon-foundry's private hosted zone.
* `ocp_cluster_name`: (Optional) When set by foundry, overrides `cluster_name` (resource tags, load balancers, `install_dir` path) so Forge matches the name Terraform publishes.
* `ingress_certificate_arn`: (Optional) When present, gryphon-forge uses an ALB with HTTPS for ingress instead of an NLB. Create via gryphon-foundry with `create_ingress_certificate = true`.
* `bastion_public_ip` or `bastion_public_dns`: When present, CSR approval and validation run on the bastion (reach cluster API in the private VPC). No bastion details are hardcoded in inventory.

## 📂 Repository Structure
```text
.
├── inventory/
│   ├── hosts.yml       # Host inventory
│   └── group_vars/     # Cluster configuration
├── roles/
│   ├── ignition/       # Wraps openshift-install to create configs
│   ├── aws_nodes/      # Provisions EC2, ELB, and Route53
│   ├── csr_approver/   # Watches and approves Kubelet CSRs
│   └── validation/     # Post-install health checks
├── playbooks/
│   ├── deploy_cluster.yml
│   └── destroy_cluster.yml
├── ansible.cfg
└── README.md
```

## 🚀 Usage

### 1. Prepare your environment
The Forge requires the following tools:

* **Controller (your machine):** The ignition role downloads `openshift-install` and `oc` into `install_dir/bin/` from the same `forge_ocp_mirror_base_url` / `forge_ocp_mirror_channel` as the bastion (Linux or macOS archives), so install state matches `gather bootstrap` / `wait-for` on the bastion. Override with `openshift_install_binary_path` / `openshift_client_binary_path` if the controller cannot reach the mirror. When using a bastion, CSR approval and validation still use Linux binaries under `bastion_install_dir/bin/` (see *Bastion OCP tools* below).
* `ansible` (with `amazon.aws`, `community.aws`, and `kubernetes.core` collections)

**Virtual environment (recommended)** — Create and activate a virtual environment so Ansible uses the correct Python interpreter with all dependencies:

```bash
python3 -m venv .venv
source .venv/bin/activate   # On Windows: .venv\Scripts\activate
```

**Python dependencies** — The `amazon.aws` collection requires `boto3` and `botocore` for AWS API calls. Install dev dependencies:

```bash
pip install -r requirements-dev.txt
```

Install the required Ansible collections:

```bash
ansible-galaxy collection install -r requirements.yml
```

### 2. Configure variables

**AWS credentials** — The playbook and `openshift-install` call AWS APIs (EC2, Route53, etc.). Configure credentials before running:

* **Option A: Environment variables**
  ```bash
  export AWS_ACCESS_KEY_ID=your_access_key
  export AWS_SECRET_ACCESS_KEY=your_secret_key
  export AWS_REGION=us-east-2   # or your region
  ```

* **Option B: AWS profile** — Use `~/.aws/credentials` and `~/.aws/config`, then:
  ```bash
  export AWS_PROFILE=your_profile_name
  ```

* **Required permissions** — The IAM user/role must allow at least: `ec2:DescribeSubnets`, `ec2:DescribeVpcs`, EC2 instance lifecycle, ELB, Route53, and IAM (for instance profiles). Avoid using restricted identities (e.g. registry-only users); use an admin or deployment role with sufficient scope.

**Recommended: Use `foundry_output.json` without modifying `all.yml`**

Pass foundry outputs via `-e` so you never risk pushing environment-specific values to Git:

```bash
ansible-playbook playbooks/deploy_cluster.yml -e @../gryphon-foundry/foundry_output.json
```

**Copy vs reference**

| Approach | Command | When to use |
|----------|---------|-------------|
| **Reference** | `-e @../gryphon-foundry/foundry_output.json` | Same repo layout; run from `gryphon-forge/`. Path is relative to CWD. |
| **Copy** | Copy to `gryphon-forge/foundry_output.json`, then run without `-e` | Different repos, CI/CD, or when paths vary. Auto-loaded from default path. |

**Copying** is more efficient when:
- Running from CI/CD where the foundry path is unpredictable
- Foundry and forge live in different repos or directories
- You want a single command: `ansible-playbook playbooks/deploy_cluster.yml`

```bash
# After terraform apply in gryphon-foundry:
cp ../gryphon-foundry/foundry_output.json .
ansible-playbook playbooks/deploy_cluster.yml
```

**Referencing** works when:
- You run from `gryphon-forge/` consistently
- Path `../gryphon-foundry/foundry_output.json` exists relative to CWD

You can also override the path:

```bash
ansible-playbook playbooks/deploy_cluster.yml -e foundry_output_path=/path/to/foundry_output.json
```

**Optional: Override cluster config in `inventory/group_vars/all.yml`**

Only edit `all.yml` for values not in foundry output (cluster name, node counts, instance types, paths). Foundry outputs (`vault_vpc_id`, `private_subnet_ids`, etc.) should come from `foundry_output.json` or `-e`.

**Pull secret** — Required for OpenShift to pull container images from Red Hat registries. Retrieve it from:

1. Go to [Red Hat OpenShift Installer-Provisioned Infrastructure (AWS)](https://console.redhat.com/openshift/install/aws/installer-provisioned)
2. Log in with your Red Hat account
3. Click **Download pull secret** to get a JSON file
4. Save it to `~/.openshift/pull-secret`:
   ```bash
   mkdir -p ~/.openshift
   # Paste the downloaded JSON content into the file
   # Or, if you downloaded a file: mv ~/Downloads/pull-secret ~/.openshift/pull-secret
   ```
5. Alternatively, set `PULL_SECRET_PATH` to point to your pull secret file:
   ```bash
   export PULL_SECRET_PATH=/path/to/your/pull-secret
   ```

**SSH key** — Ensure your SSH public key is at `~/.ssh/id_rsa.pub` (or set `SSH_PUBLIC_KEY_PATH`).

**EC2 key pair and RHCOS AMI** — The playbook auto-generates these when not set:

- **RHCOS AMI**: Fetched from OpenShift release metadata (`openshift-install coreos print-stream-json`) for your region.
- **EC2 key pair**: Created as `{{ cluster_name }}-forge-key` in AWS; the private key is saved to `~/.ssh/{{ cluster_name }}-forge-key.pem`.

**Disconnected / locked-down AWS** — If your account cannot use Red Hat's AMI directly (`AuthFailure`):

- **Option 1 (recommended):** Use gryphon-foundry's RHCOS AMI import. Run `terraform apply` in foundry with `create_rhcos_ami = true` (default). Foundry imports RHCOS from mirror.openshift.com (~15 min). Then run the playbook with `foundry_output.json` — `rhcos_ami_id` is auto-used when foundry provides it.
- **Option 2:** Copy from a source AMI you have access to. Set `rhcos_ami_source_id` and optionally `rhcos_ami_source_region`:

```bash
# Option 2: Copy RHCOS AMI from source into your account, then provision
ansible-playbook playbooks/deploy_cluster.yml -e @foundry_output.json \
  -e rhcos_ami_source_id=ami-xxxxxxxxx \
  -e rhcos_ami_source_region=us-east-2
```

To set them manually instead, add to `inventory/group_vars/all.yml` or pass via `-e`:

```bash
# Get RHCOS AMI for your region (e.g. us-east-2)
openshift-install coreos print-stream-json | jq -r '.architectures.x86_64.images.aws.regions["us-east-2"].image'

# Create EC2 key pair via AWS CLI (optional; playbook can create it)
aws ec2 create-key-pair --key-name my-cluster-key --region us-east-2 --query 'KeyMaterial' --output text > ~/.ssh/my-cluster-key.pem
chmod 600 ~/.ssh/my-cluster-key.pem

# Pass to playbook
ansible-playbook playbooks/deploy_cluster.yml -e @foundry_output.json -e ec2_key_name=my-cluster-key -e rhcos_ami_id=ami-xxxxxxxxx
```

**Bastion SSH key** — When foundry provides `bastion_public_ip`/`bastion_public_dns`, the playbook syncs the install directory to the bastion and runs CSR approval and validation there. The bastion uses the key from gryphon-foundry's `bastion_key_name` (e.g. `bastion-key.pem`), which is separate from the OCP node key. Set the private key path via one of:

- **Environment variable:** `export BASTION_SSH_KEY_PATH=~/.ssh/bastion-key.pem`
- **Extra vars:** `-e bastion_ssh_private_key_path=../gryphon-foundry/bastion-key.pem` (path relative to CWD when run from `gryphon-forge/`)
- **Default:** `~/.ssh/<ec2_key_name>.pem` (only when bastion key matches OCP key)

**Bastion OCP tools** — When using a bastion, the playbook does *not* copy `openshift-install` or `oc` from your controller (avoiding Mac/Linux binary mismatch). Instead, the bastion downloads Linux-compatible binaries directly from `mirror.openshift.com`, matching the `ocp_version` in config (e.g. `latest-4.20`). The bastion must have internet access to the mirror for the first run. Override `forge_ocp_mirror_base_url` for air-gapped or internal mirrors.

**Disconnected / Air-Gapped Install** — The Vault has no internet. OCP nodes must pull images from a mirror registry reachable via VPC peering (e.g. in Nest).

1. **Provision mirror registry** (gryphon-foundry):
   ```hcl
   create_mirror_registry = true
   ```
   This deploys an EC2 in Nest with a container registry at `mirror.<base_domain>` (e.g. `mirror.fsi.internal`).

2. **Run oc-mirror from bastion** to populate the mirror registry:
   ```bash
   # SSH to bastion, install oc-mirror, create imageset-config.yaml
   # Then: oc mirror run --config imageset-config.yaml
   ```
   See [Red Hat disconnected install docs](https://docs.openshift.com/container-platform/4.15/installing/disconnected_install/installing-mirroring-disconnected.html).

3. **Add mirror registry to pull secret** — The Red Hat pull secret does not include your private mirror. Merge mirror `auths` into the same JSON you use for installs (see **Iron Gryphon** air-gapped setup in the team profile README: merge on the **bastion** with `oc registry login` or `podman login` to a temp `--authfile`, then `jq` **only** the `auths` maps—`{auths: ($a.auths * $b.auths)}`—not a top-level merge that drops Red Hat entries). Copy the merged file to your Ansible controller and set `PULL_SECRET_PATH`, or set **`mirror_registry_dockerconfig_extra_path`** in Forge to a mirror-only dockerconfig for tag discovery only.

4. **Deploy with mirror** — Pass `mirror_registry_url` (from foundry output or `-e`):
   ```bash
   ansible-playbook playbooks/deploy_cluster.yml -e @foundry_output.json \
     -e bastion_ssh_private_key_path=../gryphon-foundry/bastion-key.pem
   ```
   When `mirror_registry_url` is set, the install-config gets `imageDigestSources` (default) and an `ImageDigestMirrorSet` manifest, aligned with `oc adm release mirror --print-mirror-instructions=idms`. Use `mirror_registry_use_image_digest_sources: false` for legacy `imageContentSources` + `ImageContentSourcePolicy`.

5. **Registry TLS (required for private CAs / self-signed)** — RHCOS and other Go-based clients validate the registry with modern rules: the certificate **must include Subject Alternative Names (SAN)** listing every DNS name used to reach the mirror (for example `DNS:mirror.fsi.internal`). A certificate with only `CN=mirror.fsi.internal` and no SAN will fail with errors like *certificate relies on legacy Common Name field*.

   - **gryphon-foundry mirror EC2** (`create_mirror_registry = true`): Terraform generates a CA and server certificate with SANs, installs them on the instance, and emits `mirror_registry_additional_trust_bundle` in `terraform output -json`. gryphon-forge reads it from `foundry_output.json` into `install-config` `additionalTrustBundle`—no manual PEM copy from the host.

   - **Replace bad certificates on the mirror** (custom registry or pre-change foundry): install a server cert + key whose SANs match how nodes resolve the registry hostname (generate with OpenSSL or your PKI). Set Forge’s `mirror_registry_additional_trust_bundle` to the PEM of the issuing CA (or chain), merge into `foundry_output.json` if you load foundry that way, regenerate ignition, and redeploy.

   - **Corporate PKI**: ensure the issued server cert’s SAN extension includes the mirror FQDN; supply the signing CA chain in `mirror_registry_additional_trust_bundle` as PEM.

### 3. Run the Forge

**Full deployment** — ignition generation, EC2 provisioning, load balancers, Route53, CSR approval, and validation:

```bash
ansible-playbook playbooks/deploy_cluster.yml -e @../gryphon-foundry/foundry_output.json
```

When using the bastion (foundry provides `bastion_public_ip`), include the bastion private key:

```bash
ansible-playbook playbooks/deploy_cluster.yml -e @../gryphon-foundry/foundry_output.json \
  -e bastion_ssh_private_key_path=../gryphon-foundry/bastion-key.pem
```

Or, if `foundry_output.json` exists at the default path, simply:

```bash
ansible-playbook playbooks/deploy_cluster.yml
```

**Run specific stages** using tags:

```bash
# Ignition only
ansible-playbook playbooks/deploy_cluster.yml --tags "ignition"

# EC2 provisioning only
ansible-playbook playbooks/deploy_cluster.yml --tags "ec2"

# AMI copy only (disconnected: copy RHCOS from source into your account)
ansible-playbook playbooks/deploy_cluster.yml --tags "ami_copy"

# CSR approval and bootstrap wait
ansible-playbook playbooks/deploy_cluster.yml --tags "csr_approval"

# Validation only
ansible-playbook playbooks/deploy_cluster.yml --tags "validation"
```

**Destroy the cluster**:

```bash
ansible-playbook playbooks/destroy_cluster.yml
```

## 🛠️ Post-Installation & Integration
After the Forge completes the bootstrap sequence, the cluster will be reachable via the internal Load Balancer. The following steps are typically performed to finalize the environment:

1. **Registry Mirroring**: Use the oc-mirror outputs to populate the internal registry within the Vault.
2. **Storage Verification**: Ensure the AWS EBS CSI driver is correctly mapping Persistent Volumes (PVs) for RHOAI and Feast components.
3. **Authentication**: Configure the IdentityProviders (OIDC/LDAP) to allow squad members to log in with their corporate credentials.

## 🛡️ Operational Guardrails
* **Idempotency:** All roles in the Forge are designed to be idempotent. Running the playbook against an existing cluster will verify the state and only apply necessary changes (e.g., updating security group rules or scaling worker sets) without disrupting the control plane.
* **Immutable Infrastructure:** We treat the OCP nodes as immutable. Significant changes to the underlying OS configuration (RHCOS) should be handled via MachineConfigs rather than direct Ansible tasks on the nodes.
* **State Awareness:** While the Foundry manages the VPC state via Terraform, the Forge manages the "Cluster Presence." Ensure that instance counts and metadata in your Ansible inventory are kept in sync with the physical resources in AWS to prevent configuration drift.

---

## 📢 Slack Notifications (Optional)

The `.github/workflows/slack-notify.yml` workflow notifies Slack when:

- **Branch updates (merges/pushes)** – Commits pushed or merged to `main`, `master`, or `dev`
- **Dependabot PRs** – A new dependency update PR is opened

Uses Slack Workflow Builder (webhook trigger). Requires `SLACK_WEBHOOK_URL` repository secret. See gryphon-foundry's [SETUP.md](../gryphon-foundry/SETUP.md#slack-notifications-optional) for setup instructions. Payload uses `event_type: main_update` (branch updates) and `event_type: dependabot_pr` (Dependabot PRs).

---

## 🤝 Contributing
The **Iron Gryphon** ecosystem thrives on community intelligence. If you are contributing to the Forge:
* **Maintain Idempotency:** Ensure that every task can be run multiple times without causing errors or unexpected state changes.
* **Linting:** Use `ansible-lint` to ensure all playbooks and roles meet the squad's quality standards.
* **Modularity:** Add specialized roles (e.g., custom GPU optimizations or local storage configurations) to the `roles/` directory with a dedicated `README.md` explaining the variables.

---

## 📄 License
This project is licensed under the **Apache License 2.0**. You are free to use, modify, and distribute this code for commercial and private use, provided that the original license and copyright notice are included. See the [LICENSE](LICENSE) file for the full text.

---
**The Iron Gryphon Squad** *Hardened Infrastructure for Financial Intelligence.*
