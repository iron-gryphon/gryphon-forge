# Validation Role

Post-installation health checks for the OpenShift cluster. Verifies cluster operators, node readiness, and core component status.

## Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `kubeconfig_path` | Path to admin kubeconfig | `{{ install_dir }}/auth/kubeconfig` |
| `validation_operators_timeout` | Seconds to wait for operators | 600 |

## Checks Performed

1. **Cluster Operators**: All operators in Available/Progressing
2. **Nodes**: All master and worker nodes Ready
3. **API**: Cluster API reachable
4. **Ingress**: Default ingress controller Degraded=False
