#!/usr/bin/env bash
# Mirror RHOAI (+ cert-manager, optional NFD/GPU/OSSM3) into the Nest registry for Gryphon Forge.
#
# Run on the Nest bastion (internet + reachability to mirror.fsi.internal).
# After success, point Ansible at the generated cluster-resources:
#
#   ansible-playbook playbooks/install_rhoai.yml ... \
#     -e rhoai_apply_mirror_resources=true \
#     -e rhoai_mirror_resources_dir=$HOME/oc-mirror-workspace-rhoai/working-dir/cluster-resources
#
# Usage:
#   export MIRROR_REGISTRY_URL=mirror.fsi.internal
#   export PULL_SECRET=~/.openshift/pull-secret
#   export OCP_MINOR=4.22          # operator index tag minor
#   export RHOAI_CHANNEL=stable-3.4
#   export RHOAI_VERSION=3.4.2     # min/maxVersion pin; confirm supported configs
#   ./scripts/mirror-rhoai.sh
#
# Optional:
#   INCLUDE_GPU=true|false (default true)
#   INCLUDE_SERVICEMESH=true|false (default false — RHOAI 3.x RawDeployment)
#   INCLUDE_WORKBENCH_IMAGES=true|false (default true; large)
#   WORKSPACE=$HOME/oc-mirror-workspace-rhoai
#   DEST_PATH=openshift/rhoai
#   IMAGESET=$HOME/imagesets/imageset-config-rhoai.yaml
#   MIN_FREE_GB=200

set -euo pipefail

MIRROR_REGISTRY_URL="${MIRROR_REGISTRY_URL:?set MIRROR_REGISTRY_URL (e.g. mirror.fsi.internal)}"
PULL_SECRET="${PULL_SECRET:-${PULL_SECRET_PATH:-$HOME/.openshift/pull-secret}}"
OCP_MINOR="${OCP_MINOR:-4.22}"
RHOAI_CHANNEL="${RHOAI_CHANNEL:-stable-3.4}"
RHOAI_VERSION="${RHOAI_VERSION:-3.4.2}"
INCLUDE_GPU="${INCLUDE_GPU:-true}"
INCLUDE_SERVICEMESH="${INCLUDE_SERVICEMESH:-false}"
INCLUDE_WORKBENCH_IMAGES="${INCLUDE_WORKBENCH_IMAGES:-true}"
WORKSPACE="${WORKSPACE:-$HOME/oc-mirror-workspace-rhoai}"
DEST_PATH="${DEST_PATH:-openshift/rhoai}"
IMAGESET="${IMAGESET:-$HOME/imagesets/imageset-config-rhoai.yaml}"
MIN_FREE_GB="${MIN_FREE_GB:-200}"
OC_MIRROR_BIN="${OC_MIRROR_BIN:-$(command -v oc-mirror || true)}"

die() { echo "error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

need python3
[[ -f "$PULL_SECRET" ]] || die "pull secret not found: $PULL_SECRET"
[[ -n "$OC_MIRROR_BIN" && -x "$OC_MIRROR_BIN" ]] || die "oc-mirror not found; set OC_MIRROR_BIN or install on PATH"

# Free space under workspace parent (portable df)
_parent="$(dirname "$WORKSPACE")"
mkdir -p "$_parent"
_avail_kb="$(df -Pk "$_parent" | awk 'NR==2 {print $4}')"
_avail_gb="$((_avail_kb / 1024 / 1024))"
if (( _avail_gb < MIN_FREE_GB )); then
  die "only ${_avail_gb}GiB free under ${_parent}; need >= ${MIN_FREE_GB}GiB (full RHOAI+workbenches can exceed 500GiB)"
fi

mkdir -p "$(dirname "$IMAGESET")" "$WORKSPACE"

# nfd shares redhat-operator-index with rhods (must not duplicate catalog entries)
GPU_NFD_PKG=""
GPU_CERT_CATALOG=""
if [[ "$INCLUDE_GPU" == "true" ]]; then
  GPU_NFD_PKG="$(cat <<EOF
        - name: nfd
          defaultChannel: stable
          channels:
            - name: stable
EOF
)"
  GPU_CERT_CATALOG="$(cat <<EOF
    - catalog: registry.redhat.io/redhat/certified-operator-index:v${OCP_MINOR}
      packages:
        - name: gpu-operator-certified
          defaultChannel: stable
          channels:
            - name: stable
EOF
)"
fi

MESH_BLOCK=""
if [[ "$INCLUDE_SERVICEMESH" == "true" ]]; then
  MESH_BLOCK="$(cat <<EOF
        - name: servicemeshoperator3
          defaultChannel: stable
          channels:
            - name: stable
EOF
)"
fi

ADDITIONAL_IMAGES_BLOCK="  additionalImages: []"
if [[ "$INCLUDE_WORKBENCH_IMAGES" == "true" ]]; then
  echo "==> Fetching workbench additionalImages from rhoai-disconnected-install-helper (${RHOAI_VERSION})"
  _helper_url="https://raw.githubusercontent.com/red-hat-data-services/rhoai-disconnected-install-helper/main/rhoai-${RHOAI_VERSION}.md"
  _imgs="$(curl -sfL "$_helper_url" \
    | awk '/^# Additional images/{a=1; next} /^# (Unsupported|ImageSetConfiguration)/{a=0} a' \
    | grep -oE '(quay\.io|registry\.redhat\.io)[^ ]+@sha256:[a-f0-9]+' \
    | sort -u || true)"
  if [[ -z "$_imgs" ]]; then
    echo "warn: no additionalImages parsed from ${_helper_url}; continuing with empty list" >&2
    ADDITIONAL_IMAGES_BLOCK="  additionalImages: []"
  else
    ADDITIONAL_IMAGES_BLOCK="  additionalImages:"
    while IFS= read -r ref; do
      [[ -n "$ref" ]] || continue
      ADDITIONAL_IMAGES_BLOCK+=$'\n'"    - name: ${ref}"
    done <<< "$_imgs"
  fi
fi

cat > "$IMAGESET" <<EOF
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  operators:
    - catalog: registry.redhat.io/redhat/redhat-operator-index:v${OCP_MINOR}
      packages:
        - name: rhods-operator
          defaultChannel: ${RHOAI_CHANNEL}
          channels:
            - name: ${RHOAI_CHANNEL}
              minVersion: "${RHOAI_VERSION}"
              maxVersion: "${RHOAI_VERSION}"
        - name: openshift-cert-manager-operator
          defaultChannel: stable-v1
          channels:
            - name: stable-v1
${MESH_BLOCK}
${GPU_NFD_PKG}
${GPU_CERT_CATALOG}
${ADDITIONAL_IMAGES_BLOCK}
EOF

echo "==> ImageSetConfiguration written to $IMAGESET"
echo "==> Mirroring to docker://${MIRROR_REGISTRY_URL}/${DEST_PATH}"
echo "    workspace: $WORKSPACE"

"$OC_MIRROR_BIN" --v2 \
  -c "$IMAGESET" \
  --workspace "file://${WORKSPACE}" \
  "docker://${MIRROR_REGISTRY_URL}/${DEST_PATH}" \
  --authfile "$PULL_SECRET"

_resources="${WORKSPACE}/working-dir/cluster-resources"
[[ -d "$_resources" ]] || die "expected cluster-resources at ${_resources}"

echo
echo "Mirror complete."
echo "Apply mirrored CRs then install RHOAI:"
echo
echo "  ansible-playbook playbooks/install_rhoai.yml -i inventory/hosts.yml \\"
echo "    -e @../gryphon-foundry/foundry_output.json \\"
echo "    -e rhoai_apply_mirror_resources=true \\"
echo "    -e rhoai_mirror_resources_dir=${_resources}"
echo
