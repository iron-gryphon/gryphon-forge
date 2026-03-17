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
This project expects a `foundry_output.json` or access to the Terraform remote state of `gryphon-foundry`. It specifically requires:
* `vault_vpc_id`: To place the nodes.
* `private_subnet_ids`: For the multi-AZ distribution of nodes.
* `bastion_security_group_id`: To allow administrative access via the VPN.
* `internal_hosted_zone_id`: To register OCP DNS records.

## 📂 Repository Structure
```text
.
├── inventory/          # Environment definitions (sandbox, prod)
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
The Forge requires the specific versions of the OpenShift installer and CLI that match your target OCP version. Ensure these are in your `$PATH`.
* `openshift-install`
* `oc`
* `ansible` (with `amazon.aws` and `kubernetes.core` collections)

### 2. Configure Environment Variables
Update your inventory or `group_vars` with the metadata provided by the `gryphon-foundry` outputs:
```yaml
# inventory/group_vars/all.yml
foundry_vpc_id: "vpc-0abc123..."
foundry_private_subnets: ["subnet-111", "subnet-222", "subnet-333"]
cluster_name: "iron-vault-01"
base_domain: "fsi.internal"
worker_count: 3
gpu_worker_count: 1
```

### 3. Run the Forge
Execute the main deployment playbook. This process will orchestrate ignition generation, infrastructure provisioning in AWS, and the automated monitoring of the bootstrap process.

```bash
# Execute the full deployment lifecycle
ansible-playbook -i inventory/sandbox playbooks/deploy_cluster.yml
```

To run specific stages of the forge (e.g., just approving CSRs or just provisioning EC2), you can use tags:

```bash
ansible-playbook -i inventory/sandbox playbooks/deploy_cluster.yml --tags "csr_approval"
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
