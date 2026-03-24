# Gryphon Forge — Agent Collaboration Guide

This document helps AI agents understand and collaborate on the **gryphon-forge** project.

## Project Summary

**gryphon-forge** is an Ansible-based orchestration project that deploys Red Hat OpenShift Container Platform (OCP) using **User-Provisioned Infrastructure (UPI)**. It consumes outputs from `gryphon-foundry` to build a production-grade, air-gapped cluster in AWS (the "Vault").

**Transition:** "Empty VPC" → "Functional Cluster"

## Architecture

| Stage | Responsibility |
|-------|----------------|
| **Configuration** | Node counts (Master, Worker, GPU), instance sizing |
| **Ignition** | Fetch pull secrets, generate OpenShift ignition files via `openshift-install` |
| **Provisioning** | Deploy EC2 nodes into Vault private subnets |
| **Networking** | Internal NLBs/ALBs, Route53 records for API and Ingress |
| **Bootstrap** | Approve CSRs, wait for cluster operators to stabilize |
| **Validation** | Post-install health checks |

## Key Paths & Files

| Path | Purpose |
|------|---------|
| `inventory/group_vars/all.yml` | Main configuration (foundry outputs, cluster metadata, node counts) |
| `inventory/hosts.yml` | Host inventory (local, bootstrap, masters, workers, gpu_workers) |
| `playbooks/deploy_cluster.yml` | Main deployment playbook |
| `playbooks/destroy_cluster.yml` | Teardown playbook |
| `roles/ignition/` | Ignition generation (wraps `openshift-install`) |
| `roles/aws_nodes/` | EC2, ELB, Route53 provisioning |
| `roles/csr_approver/` | CSR approval during bootstrap |
| `roles/validation/` | Post-install validation |
| `foundry_output.json` | Consumed from gryphon-foundry (VPC, subnets, SG, hosted zone) |

## Dependencies

- **Tools:** `openshift-install`, `oc`, `ansible` (in `$PATH`)
- **Ansible collections:** `amazon.aws`, `community.aws`, `kubernetes.core`, `community.general` (see `requirements.yml`)
- **Secrets:** Pull secret at `~/.openshift/pull-secret` (or `PULL_SECRET_PATH`), SSH public key at `~/.ssh/id_rsa.pub`

## Playbook Tags

Use tags to run specific stages:

```bash
ansible-playbook playbooks/deploy_cluster.yml --tags "ignition"      # Ignition only
ansible-playbook playbooks/deploy_cluster.yml --tags "ec2"           # EC2 provisioning
ansible-playbook playbooks/deploy_cluster.yml --tags "csr_approval"  # CSR approval
ansible-playbook playbooks/deploy_cluster.yml --tags "validation"    # Validation only
```

## Validation & Testing

**Before committing changes**, run these validation commands locally (they mirror the GitHub Actions workflow):

```bash
# 1. Install collections (if not already done)
ansible-galaxy collection install -r requirements.yml

# 2. Syntax check all playbooks
ansible-playbook playbooks/deploy_cluster.yml --syntax-check
ansible-playbook playbooks/destroy_cluster.yml --syntax-check

# 3. Run ansible-lint
ansible-lint
```

**Optional — validate foundry JSON before deploy** (no AWS calls):

```bash
ansible-playbook playbooks/preflight.yml -i inventory/hosts.yml \
  -e foundry_preflight_path=../gryphon-foundry/foundry_output.json
```

In **gryphon-foundry**, after `terraform output -json > foundry_output.json`, run `./scripts/check-foundry-json-for-forge.sh foundry_output.json` (requires `jq`).

**After making changes**, agents must:

1. **Run validation** — Execute the commands above to ensure changes pass.
2. **Fix reported issues** — Address any `ansible-lint` or syntax errors before considering the task complete.
3. **Update tests when needed** — If you add roles, playbooks, or change structure:
   - Add new playbooks to the syntax-check loop in `.github/workflows/ansible-validation.yml`.
   - Adjust `.ansible-lint` exclusions or profile if new patterns require it.
   - Update this section if validation commands change.

## Conventions for Agents

1. **Idempotency:** All roles must be idempotent. Tasks should be safe to run multiple times.
2. **Immutable nodes:** OCP nodes are immutable. Use MachineConfigs for OS changes, not direct Ansible on nodes.
3. **State awareness:** Keep Ansible inventory in sync with physical AWS resources.
4. **Linting:** Use `ansible-lint` for playbooks and roles.
5. **Modularity:** Add new roles under `roles/` with a `README.md` and `defaults/main.yml`.
6. **Validation:** Run validation commands (syntax check, ansible-lint) before committing; update the workflow and this guide when adding playbooks or changing validation logic.

## Foundry Integration

This project expects `foundry_output.json` (or Terraform remote state) with:

- `vault_vpc_id`, `private_subnet_ids`, `bastion_security_group_id`, `internal_hosted_zone_id`, `region`

**Preferred:** Pass via `-e @foundry_output.json` to avoid modifying `inventory/group_vars/all.yml`:

```bash
ansible-playbook playbooks/deploy_cluster.yml -e @foundry_output.json
```

Variables are overridden in the first play of `deploy_cluster.yml` from: 1) `include_vars` (if file at `foundry_output_path` exists), 2) `-e @foundry_output.json`, 3) `all.yml` defaults.

## Common Tasks

- **Add a new role:** Create `roles/<name>/` with `tasks/main.yml`, `defaults/main.yml`, `README.md`.
- **Change node counts:** Edit `inventory/group_vars/all.yml` (`master_count`, `worker_count`, `gpu_worker_count`).
- **Add a playbook tag:** Add `tags:` to the relevant role in `deploy_cluster.yml`.
