# RHOAI on a Gryphon Forge disconnected cluster

Guide for installing **Red Hat OpenShift AI (RHOAI)** into an air-gapped OpenShift
cluster provisioned by **gryphon-forge** (Vault) with a Nest mirror registry from
**gryphon-foundry**.

This document adapts two upstream projects to the Iron Gryphon topology:

| Project | Role |
|:--|:--|
| [rh-aiservices-bu/disconnected-rhoai](https://github.com/rh-aiservices-bu/disconnected-rhoai) | How to **mirror** RHOAI (+ cert-manager, Service Mesh, NFD/GPU) and install operators/DSC in an air gap |
| [redhat-ai-services/ai-accelerator](https://github.com/redhat-ai-services/ai-accelerator) | GitOps **day-2** stack (OpenShift GitOps / ArgoCD apps for RHOAI and related operators) |

Upstream disconnected-rhoai is verified end-to-end for **OpenShift 4.20.30 + RHOAI 3.4.2**.
Gryphon lab clusters may run a newer OCP minor than that example. Before pinning
RHOAI versions, confirm support in
[RHOAI supported configurations](https://access.redhat.com/articles/rhoai-supported-configs)
and pick a RHOAI channel/version that lists your cluster’s OCP minor.

---

## Topology (Gryphon)

```
You / laptop
    │
    ▼
Nest bastion (internet + SSH)          Vault VPC (no internet)
  oc-mirror, pull secret                 OCP API / workers
  mirror.fsi.internal (registry)  ◄──►   nodes pull only from mirror
```

| Host | Typical use in this guide |
|:--|:--|
| **Bastion** (Nest) | Run `oc-mirror`, push to `mirror.fsi.internal`, `oc` against the cluster |
| **Controller** | Optional; keep kubeconfig from forge install |
| **Cluster** | Consumes mirrored catalogs/images only |

Forge defaults that matter:

- `mirror_registry_url`: e.g. `mirror.fsi.internal`
- Platform mirror layout (oc-mirror v2):  
  `openshift/release/openshift/release-images` (payload) and  
  `openshift/release/openshift/release` (art-dev / components)
- Trust: `mirror_registry_additional_trust_bundle` from foundry → cluster `additionalTrustBundle`
- Enable bastion `oc-mirror` with `forge_oc_mirror_install_enabled: true` (default is **false** on this branch)

---

## What you must mirror for RHOAI

OpenShift platform content should already be on the mirror from the forge install.
RHOAI needs a **second** mirror batch (large — hundreds of GB if you include all
workbench/runtime images).

| Content | Why |
|:--|:--|
| **rhods-operator** (RHOAI) | Operator + relatedImages |
| **openshift-cert-manager-operator** | Hard prerequisite for RHOAI 3.x (`DSCInitialization` will not go Ready without it) |
| **servicemeshoperator3** (OSSM / Sail) | Required for RHOAI 3.4 Data Science Gateway |
| **nfd** + **gpu-operator-certified** | Optional unless you have GPU workers; still commonly mirrored |
| **Workbench / notebook images** | **Not** fully discoverable via operator `relatedImages` — must be listed as `additionalImages` or workbenches fail with `ImagePullBackOff` |

Upstream documents ~**517 GB** for a full RHOAI + workbench set (CUDA/ROCm/Gaudi
variants). Plan Nest staging disk accordingly, or trim `additionalImages` to the
CPU-only workbenches you need.

Authoritative helper for workbench digests (version-matched):

- <https://github.com/red-hat-data-services/rhoai-disconnected-install-helper>  
  e.g. `rhoai-3.4.2.md` → “Additional images” section

Worked YAML from disconnected-rhoai:

- [imageset-config-rhoai.yaml](https://github.com/rh-aiservices-bu/disconnected-rhoai/blob/main/examples/rhoai-3.4.2-ocp-4.20.30/imageset-config-rhoai.yaml)
- [idms / itms / CatalogSources](https://github.com/rh-aiservices-bu/disconnected-rhoai/tree/main/examples/rhoai-3.4.2-ocp-4.20.30)

---

## Prerequisites checklist

1. **Cluster healthy** — forge `validation` passed; `oc get nodes` / `oc get co` look good.
2. **Default StorageClass** — RHOAI needs a provisioner (EBS CSI on AWS UPI is typical).
3. **Bastion can**:
   - Reach the internet (for `registry.redhat.io` / `quay.io/modh`)
   - Reach `https://mirror.fsi.internal` with the registry CA trusted
   - Reach the OCP API (`api.<cluster>.fsi.internal:6443`) with kubeconfig
4. **Pull secret** on bastion with Red Hat + mirror `auths` (same merge process as forge disconnected install).
5. **Disk** — hundreds of GB free under your oc-mirror workspace / cache on Nest.
6. **Versions** — set explicitly, for example:

```bash
export OCP_VERSION=4.22.8          # cluster version (already installed)
export RHOAI_VERSION=3.4.2         # confirm supported on OCP 4.22 first
export MIRROR=mirror.fsi.internal
export CLUSTER_NAME=gryphon-ocp
export BASE_DOMAIN=fsi.internal
export KUBECONFIG=/var/tmp/gryphon-forge-install/${CLUSTER_NAME}/auth/kubeconfig
export PATH="/var/tmp/gryphon-forge-install/${CLUSTER_NAME}/bin:$PATH"
```

---

## Path A — Mirror + install (disconnected-rhoai style)

Preferred for Gryphon: mirror from Nest bastion **directly into** the existing
foundry registry (no separate Quay install), then apply cluster resources with `oc`.

### A1. Install / refresh `oc-mirror` on the bastion

From the forge repo (controller):

```bash
ansible-playbook playbooks/deploy_cluster.yml -i inventory/hosts.yml \
  --tags csr_approval \
  -e @../gryphon-foundry/foundry_output.json \
  -e foundry_output_path=../gryphon-foundry/foundry_output.json \
  -e bastion_ssh_private_key_path=../gryphon-foundry/bastion-key.pem \
  -e forge_oc_mirror_install_enabled=true
```

Or copy a Linux `oc-mirror` matching your OCP channel onto the bastion manually.

### A2. Create an RHOAI `ImageSetConfiguration`

On the bastion, start from the upstream example and adjust:

- Catalog digests / package versions for your chosen `RHOAI_VERSION`
- `defaultChannel` on `rhods-operator` **must** match the channel you filter
  (upstream note: filtering `stable-3.4` without setting `defaultChannel: stable-3.4`
  makes oc-mirror refuse the catalog)
- Destination path under your mirror (keep RHOAI content separate from the
  platform `openshift/release/...` tree), e.g. `openshift/rhoai`

Minimal operator set (illustrative — pin digests from a current example or
`oc-mirror` dry-run):

```yaml
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  operators:
    - catalog: registry.redhat.io/redhat/redhat-operator-index:v4.22
      packages:
        - name: rhods-operator
          defaultChannel: stable-3.4
          channels:
            - name: stable-3.4
              minVersion: "3.4.2"
              maxVersion: "3.4.2"
        - name: openshift-cert-manager-operator
          defaultChannel: stable-v1
          channels:
            - name: stable-v1
        - name: servicemeshoperator3
          defaultChannel: stable
          channels:
            - name: stable
        - name: nfd
          defaultChannel: stable
          channels:
            - name: stable
    - catalog: registry.redhat.io/redhat/certified-operator-index:v4.22
      packages:
        - name: gpu-operator-certified
          defaultChannel: stable
          channels:
            - name: stable
  additionalImages: []   # fill from rhoai-disconnected-install-helper (see A3)
```

Use catalog **digests** when possible (tag → digest). Upstream warns that some
tag-only references cause oc-mirror to fall back to the network incorrectly.

### A3. Add workbench `additionalImages`

Fetch the version-matched list (example for 3.4.2):

```bash
curl -sfL \
  https://raw.githubusercontent.com/red-hat-data-services/rhoai-disconnected-install-helper/main/rhoai-${RHOAI_VERSION}.md \
  | awk '/^# Additional images/{a=1; next} /^# (Unsupported|ImageSetConfiguration)/{a=0} a' \
  | grep -oE '(quay\.io|registry\.redhat\.io)[^ ]+@sha256:[a-f0-9]+' \
  | sort -u
```

Convert each line to ImageSet `additionalImages` entries (`- name: <ref>`).
Optionally keep only CPU Jupyter/minimal images to shrink the mirror.

### A4. Mirror to the Nest registry (oc-mirror v2)

On the bastion (internet + registry CA trusted):

```bash
mkdir -p ~/oc-mirror-workspace-rhoai ~/imagesets
# write imageset-config-rhoai.yaml as above

oc-mirror --v2 \
  -c ~/imagesets/imageset-config-rhoai.yaml \
  --workspace file://$(pwd)/oc-mirror-workspace-rhoai \
  "docker://${MIRROR}/openshift/rhoai" \
  --authfile ~/.openshift/pull-secret
```

Expect a long runtime. When finished, oc-mirror emits cluster resources under
something like:

`~/oc-mirror-workspace-rhoai/working-dir/cluster-resources/`

Typical artifacts:

| File | Purpose |
|:--|:--|
| `idms-oc-mirror.yaml` | `ImageDigestMirrorSet` |
| `itms-oc-mirror.yaml` | `ImageTagMirrorSet` (if tags were mirrored) |
| `cs-*.yaml` | Mirrored `CatalogSource`s |

### A5. Apply mirror config to the cluster

```bash
oc apply -f ~/oc-mirror-workspace-rhoai/working-dir/cluster-resources/

# Confirm catalogs and packages
oc get catalogsource -n openshift-marketplace
oc get packagemanifest -n openshift-marketplace | grep -E 'rhods|cert-manager|servicemesh|nfd|gpu-operator'
```

If forge already applied platform IDMS for `openshift/release/...`, keep both:
RHOAI IDMS entries should redirect `registry.redhat.io` / `quay.io/modh` (etc.)
to `${MIRROR}/...` without breaking the existing release mirrors.

### A6. Install operators (order matters)

Suggested order (mirrors [disconnected-rhoai phase 40](https://github.com/rh-aiservices-bu/disconnected-rhoai/blob/main/scripts/rhoai/40-install-operators.sh)):

1. **cert-manager** (`openshift-cert-manager-operator`)
2. **Service Mesh 3** (`servicemeshoperator3`) if using RHOAI 3.4 gateway features
3. **NFD**, then **NVIDIA GPU Operator** (only if GPU workers exist / desired)
4. **RHOAI** (`rhods-operator`) in `redhat-ods-operator` (AllNamespaces OperatorGroup)

Resolve CatalogSource names from PackageManifests rather than hard-coding:

```bash
oc get packagemanifest rhods-operator -n openshift-marketplace \
  -o jsonpath='{.status.catalogSource}{"\n"}'
```

Wait until CSVs are `Succeeded` before continuing:

```bash
oc get csv -A | grep -E 'cert-manager|servicemesh|rhods|nfd|gpu-operator'
```

### A7. Configure RHOAI (`DSCInitialization` then `DataScienceCluster`)

Apply **DSCI first** and wait until Ready; then apply **DSC**. Applying both at
once can race (upstream phase 50 note).

Use manifests from:

- [disconnected-rhoai examples](https://github.com/rh-aiservices-bu/disconnected-rhoai/tree/main/examples/rhoai-3.4.2-ocp-4.20.30)
  (`dscinitialization.yaml`, `datasciencecluster.yaml`)

Adapt:

- Management / applications namespaces as required by your RHOAI minor
- Trusted CA / mirror CA if the DSCI template expects a PEM (Nest registry CA)
- Component set to match the **apiVersion** of the installed CRD (3.x removed /
  renamed several 2.x fields)

```bash
oc apply -f dscinitialization.yaml
oc wait dscinitialization default-dsci --for=condition=Ready --timeout=20m

oc apply -f datasciencecluster.yaml
oc get datasciencecluster -A
oc get csv -n redhat-ods-operator
```

### A8. Verify

```bash
oc get dscinitialization,datasciencecluster -A
oc get pods -n redhat-ods-applications
oc get route -n redhat-ods-applications   # dashboard
# Create a test Data Science Project + CPU workbench — confirms workbench images pulled
```

Dashboard URL is typically under `*.apps.${CLUSTER_NAME}.${BASE_DOMAIN}`.

---

## Path B — ai-accelerator GitOps (after images exist)

Once catalogs and images are mirrored (Path A), you can manage day-2 config with
[ai-accelerator](https://github.com/redhat-ai-services/ai-accelerator) instead of
(or in addition to) one-shot YAML.

### B1. Fork and pick an overlay

Clone / fork the repo. Bootstrap overlays include (non-exhaustive):

- `bootstrap/overlays/rhoai-stable-3.4-aws-gpu`
- `bootstrap/overlays/rhoai-stable-3.3-aws-gpu`
- `bootstrap/overlays/rhoai-eus-2.25`

See [installation.md](https://github.com/redhat-ai-services/ai-accelerator/blob/main/documentation/installation.md).

### B2. Disconnected constraints

- ArgoCD / OpenShift GitOps must also be **mirrored** (operator + operand images)
  before `./bootstrap.sh`, or GitOps itself will `ImagePullBackOff`.
- Point GitOps to **your fork** (air-gapped clusters often sync from an internal
  Git server, not github.com).
- Operator Subscriptions created by Argo must use the **mirrored CatalogSources**
  from Path A (not `redhat-operators` from the public marketplace).
- MinIO and other sample apps pull public images — mirror those or disable the
  overlays you do not need.

### B3. Bootstrap (connected-style flow; adapt for air gap)

```bash
oc login ...   # cluster-admin
./bootstrap.sh
# select overlay matching your RHOAI channel, e.g. rhoai-stable-3.4-aws-gpu
```

Then:

```bash
oc adm groups add-users gitops-admins $(oc whoami)
oc get routes openshift-gitops-server -n openshift-gitops
```

Expect 10–15+ minutes for Applications to settle; Subscriptions may show
`Progressing` long after the Operator appears Installed (OLM reconciliation).

---

## GPU notes (Forge)

- Forge can provision `gpu_worker_count` / `gpu_worker_instance_type` in
  `inventory/group_vars/all.yml` (default: **3× `g6.4xlarge`** for RHOAI).
- Mirror NFD + NVIDIA GPU Operator **before** attaching GPU nodes that expect
  drivers (`INCLUDE_GPU=true` with `scripts/mirror-rhoai.sh`, then
  `rhoai_install_gpu_stack=true` on `playbooks/install_rhoai.yml`).
- Without GPU nodes, skip GPU Operator Subscriptions and prefer CPU workbench
  images only.

---

## Storage sizing (planning)

| Item | Ballpark |
|:--|:--|
| Platform OCP mirror (already done) | ~20 GB |
| RHOAI operators only | much smaller than full set |
| RHOAI + full workbench/runtimes | **~500+ GB** (upstream measurement) |
| Nest free space recommendation | ≥ 1–1.5 TB if mirroring the full set |

Reclaim oc-mirror cache/workspace between platform and RHOAI batches when disk is
tight (upstream `16-cleanup-staging` pattern).

---

## Troubleshooting

| Symptom | Likely cause |
|:--|:--|
| `ImagePullBackOff` on workbench | Missing `additionalImages` / workbench digests not mirrored |
| DSCI never Ready | cert-manager not installed or not healthy |
| DSC components stuck | Operator CSV not Succeeded; wrong CRD/apiVersion fields for RHOAI minor |
| Catalog empty / package missing | CatalogSource not applied or wrong index digest for OCP minor |
| TLS errors to mirror | Nest registry CA not in cluster trust / node trust |
| Argo apps ImagePullBackOff | GitOps operands not mirrored; still pointing at quay.io |
| `invalid default channel` from oc-mirror | Set `defaultChannel` on filtered `rhods-operator` package |

Useful checks:

```bash
oc get idms,itms
oc get catalogsource,packagemanifest -n openshift-marketplace
oc describe dscinitialization default-dsci
oc describe datasciencecluster
oc get events -n redhat-ods-applications --sort-by=.lastTimestamp | tail -40
```

---

## Suggested runbook (Ansible)

Forge automation for steps below lives in:

| Artifact | Purpose |
|:--|:--|
| `scripts/mirror-rhoai.sh` | Bastion-side oc-mirror v2 batch (operators + optional workbenches) |
| `playbooks/install_rhoai.yml` + `roles/rhoai/` | Prep, StorageClass/EBS CSI, operators, DSCI/DSC, verify |

1. Confirm RHOAI version supported on your cluster’s OCP minor (supported-configs article).
2. On bastion: enable `oc-mirror`, trust the Nest mirror, merged pull secret.
3. Mirror RHOAI content:

```bash
export MIRROR_REGISTRY_URL=mirror.fsi.internal
export OCP_MINOR=4.22          # match your cluster minor
export RHOAI_CHANNEL=stable-3.4
export RHOAI_VERSION=3.4.2
./scripts/mirror-rhoai.sh
```

4. Install RHOAI (storage prep + operators + DSCI/DSC):

```bash
ansible-playbook playbooks/install_rhoai.yml -i inventory/hosts.yml \
  -e @../gryphon-foundry/foundry_output.json \
  -e foundry_output_path=../gryphon-foundry/foundry_output.json \
  -e bastion_ssh_private_key_path=../gryphon-foundry/bastion-key.pem \
  -e rhoai_apply_mirror_resources=true \
  -e rhoai_mirror_resources_dir=$HOME/oc-mirror-workspace-rhoai/working-dir/cluster-resources \
  -e rhoai_channel=stable-3.4
```

5. Optional: deploy **ai-accelerator** GitOps overlay once GitOps images are mirrored
   (see Path B). Manual Path A steps remain documented above for debugging.

---

## References

- [disconnected-rhoai](https://github.com/rh-aiservices-bu/disconnected-rhoai) — mirror phases, imagesets, DSC examples
- [disconnected-rhoai CHEATSHEET](https://github.com/rh-aiservices-bu/disconnected-rhoai/blob/main/CHEATSHEET.md) — working on an existing disconnected cluster
- [ai-accelerator](https://github.com/redhat-ai-services/ai-accelerator) — GitOps bootstrap
- [ai-accelerator installation](https://github.com/redhat-ai-services/ai-accelerator/blob/main/documentation/installation.md)
- [rhoai-disconnected-install-helper](https://github.com/red-hat-data-services/rhoai-disconnected-install-helper) — additional image lists per RHOAI version
- [RHOAI supported configurations](https://access.redhat.com/articles/rhoai-supported-configs)
- Gryphon Forge disconnected notes — root `README.md` (oc-mirror, IDMS, pull secret merge)
