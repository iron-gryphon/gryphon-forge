## Description

<!-- Describe the changes in this PR. What problem does it solve? What does it add or modify? -->

## Type of Change

- [ ] Bug fix (non-breaking change that fixes an issue)
- [ ] New feature (role, playbook, or capability)
- [ ] Configuration change (inventory, group_vars, defaults)
- [ ] Documentation update
- [ ] Refactor or cleanup
- [ ] Other (please describe):

## Affected Areas

<!-- Check all that apply -->

- [ ] Playbooks (`playbooks/`)
- [ ] Roles (`roles/`)
- [ ] Inventory / group_vars
- [ ] Workflows (`.github/workflows/`)
- [ ] Documentation (README, AGENTS.md, role READMEs)

## Validation

<!-- Confirm you've run validation locally before opening this PR -->

- [ ] `ansible-playbook playbooks/*.yml --syntax-check` passes
- [ ] `ansible-lint` passes
- [ ] New playbooks added to `.github/workflows/ansible-validation.yml` (if applicable)

## Checklist

- [ ] Changes are idempotent (safe to run multiple times)
- [ ] No direct node OS modifications (use MachineConfigs for OCP nodes)
- [ ] New roles include `tasks/main.yml`, `defaults/main.yml`, and `README.md`
