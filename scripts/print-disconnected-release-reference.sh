#!/usr/bin/env bash
# Print Red Hat–style mirror commands and reminders for openshift_install_release_image_override.
# Usage:
#   ./scripts/print-disconnected-release-reference.sh [OCP_RELEASE_TAG]
# Example:
#   ./scripts/print-disconnected-release-reference.sh 4.20.16-x86_64
# Env:
#   MIRROR_REGISTRY  default: mirror.fsi.internal
#   MIRROR_PATH      default: openshift/release (must match mirror_registry_release_path in inventory)

set -euo pipefail

OCP_RELEASE_TAG="${1:-<VERSION>-x86_64}"
MIRROR_REGISTRY="${MIRROR_REGISTRY:-mirror.fsi.internal}"
MIRROR_PATH="${MIRROR_PATH:-openshift/release}"

echo "=== Source payload (public Quay; use from a connected host for oc adm release mirror) ==="
echo "  quay.io/openshift-release-dev/ocp-release:${OCP_RELEASE_TAG}"
echo ""
echo "=== Example: mirror into ${MIRROR_REGISTRY}/${MIRROR_PATH} (adjust pull secret path) ==="
echo "  oc adm release mirror -a \"\${PULL_SECRET:-\$HOME/.docker/config.json}\" \\"
echo "    --from=quay.io/openshift-release-dev/ocp-release:${OCP_RELEASE_TAG} \\"
echo "    --to=${MIRROR_REGISTRY}/${MIRROR_PATH} \\"
echo "    --to-release-image=${MIRROR_REGISTRY}/${MIRROR_PATH}:${OCP_RELEASE_TAG}"
echo ""
echo "  Record --to-release-image (or digest) from the command output; use oc-mirror per Red Hat docs for full workflows."
echo ""
echo "=== After mirroring: set in inventory/group_vars/all.yml or -e ==="
echo "  openshift_install_release_image_override: \"${MIRROR_REGISTRY}/${MIRROR_PATH}@sha256:<digest>\""
echo "  # or tag form if your registry uses tags:"
echo "  # openshift_install_release_image_override: \"${MIRROR_REGISTRY}/${MIRROR_PATH}:${OCP_RELEASE_TAG}\""
echo ""
echo "=== Match openshift-install to the same release ==="
echo "  openshift-install version"
echo "  # default release image must correspond to the mirrored payload (same z-stream / digest)."
echo ""
echo "=== Confirm the digest exists on the mirror (run on bastion; use your override reference) ==="
echo "  # Replace RELEASE_IMAGE with openshift_install_release_image_override (no docker:// prefix), e.g. mirror.../openshift/release@sha256:..."
echo "  oc image info \"\${RELEASE_IMAGE#docker://}\" --registry-config=\${PULL_SECRET:-\$HOME/.docker/config.json}"
echo "  # With a custom registry CA PEM (same as mirror_registry_additional_trust_bundle):"
echo "  oc image info \"\${RELEASE_IMAGE#docker://}\" --registry-config=\${PULL_SECRET:-\$HOME/.docker/config.json} \\"
echo "    --certificate-authority=/path/to/mirror-ca.pem"
echo "  # Exit code 0 = manifest present; non-zero = manifest unknown / auth / TLS failure."
echo ""
echo "Forge maps install-config imageContentSources to:"
echo "  quay.io/openshift-release-dev/ocp-release -> ${MIRROR_REGISTRY}/${MIRROR_PATH}"
echo "  quay.io/openshift-release-dev/ocp-v4.0-art-dev -> ${MIRROR_REGISTRY}/${MIRROR_PATH}"
