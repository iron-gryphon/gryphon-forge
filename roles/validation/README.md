# Validation Role

Post-installation health checks for the OpenShift cluster: API access via `oc`, degraded cluster operators (jsonpath), node Ready state, and desired cluster version.

## Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `validation_install_dir` | Directory containing `auth/kubeconfig` (bastion or controller) | `{{ install_dir }}` |
| `validation_oc_cmd` | `oc` binary path | `oc` |
| `validation_controller_install_dir` | Controller-side install dir (used as `fetch` destination when the play targets bastion) | `{{ install_dir }}` |
| `validation_report_filename` | Written under `validation_install_dir`, then fetched to the controller when on bastion | `validation-report.txt` |
| `validation_sync_auth_to_controller` | Fetch `auth/kubeconfig` and `auth/kubeadmin-password` to the controller after checks | `true` |
| `validation_check_oauth_openshift_route` | Query `oauth-openshift` Route `targetPort`; warn if `6443` (should be Service port `https` / `443`) | `true` |
| `validation_operators_timeout` | Reserved for future wait logic | `600` |

## Artifacts

- **`validation-report.txt`**: Saved next to the kubeconfig used for the run, then **fetched** to `validation_controller_install_dir` when `inventory_hostname == 'bastion'` so your local `installer/<cluster>/` copy stays in sync with bastion results.
- **Auth sync**: When running on the bastion, kubeconfig and kubeadmin password are copied back to the controller install directory (optional via `validation_sync_auth_to_controller`).

## Checks Performed

1. **Kubeconfig** must exist.
2. **`oc whoami`** — must succeed (rc 0) or the play fails after the report is written.
3. **Cluster operators** — jsonpath list of operators whose `Available` condition is not `True`; fails if `api` or `authentication` appears in that list.
4. **Nodes** — jsonpath list of nodes not `Ready` (reported, non-fatal).
5. **`clusterversion`** — desired version string (best effort; failures surfaced in the report).
6. **`oauth-openshift` Route** — `spec.port.targetPort` must reference the Service port (not pod `6443`); see [issue #23](https://github.com/iron-gryphon/gryphon-forge/issues/23). Non-fatal warning and report line when wrong.
