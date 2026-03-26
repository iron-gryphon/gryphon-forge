#!/usr/bin/env bash
# Generate a small CA and server TLS certificate with Subject Alternative Names (SANs).
# RHCOS / Go 1.15+ reject certificates that only set Common Name; SAN must list hostnames
# clients use (e.g. https://mirror.fsi.internal/v2/).
#
# Usage:
#   ./scripts/generate-mirror-registry-tls.sh mirror.fsi.internal
#   ./scripts/generate-mirror-registry-tls.sh mirror.fsi.internal registry.fsi.internal
#
# Outputs under OUTDIR (default: ./mirror-tls-<first-hostname>):
#   ca-cert.pem, ca-key.pem     — keep ca-key.pem secret; distribute ca-cert.pem to trust stores
#   server-cert.pem, server-key.pem — install on the registry / TLS terminator
#
# Forge: set mirror_registry_additional_trust_bundle to the contents of ca-cert.pem
# (PEM), then re-run ignition. Replace the mirror's TLS material and reload the service.

set -euo pipefail

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -lt 1 ]]; then
  echo "Usage: $0 <primary-fqdn> [additional-dns-name ...]" >&2
  exit 1
fi

dns_names=("$@")
primary="${dns_names[0]}"
safe="${primary//[^a-zA-Z0-9.-]/_}"
outdir="${OUTDIR:-./mirror-tls-${safe}}"

mkdir -p "$outdir"
cd "$outdir"

openssl genrsa -out ca-key.pem 4096
openssl req -new -x509 -days 3650 -key ca-key.pem -out ca-cert.pem \
  -subj "/O=gryphon-mirror-registry/CN=${primary}-offline-ca"

openssl genrsa -out server-key.pem 4096

san_conf=$(mktemp)
cleanup() { rm -f "$san_conf" server.csr ca-cert.srl 2>/dev/null || true; }
trap cleanup EXIT

{
  echo "[req]"
  echo "distinguished_name = req_distinguished_name"
  echo "req_extensions = v3_req"
  echo "prompt = no"
  echo ""
  echo "[req_distinguished_name]"
  echo "CN = ${primary}"
  echo ""
  echo "[v3_req]"
  echo "subjectAltName = @alt_names"
  echo "extendedKeyUsage = serverAuth"
  echo ""
  echo "[alt_names]"
  i=1
  for name in "${dns_names[@]}"; do
    echo "DNS.$i = $name"
    i=$((i + 1))
  done
} >"$san_conf"

openssl req -new -key server-key.pem -out server.csr -config "$san_conf"
openssl x509 -req -in server.csr -CA ca-cert.pem -CAkey ca-key.pem -CAcreateserial \
  -out server-cert.pem -days 825 -extensions v3_req -extfile "$san_conf"

chmod 600 ca-key.pem server-key.pem
chmod 644 ca-cert.pem server-cert.pem

cat >NEXT-STEPS.txt <<EOF
Generated TLS material for: ${dns_names[*]}

1. On the mirror host (or TLS proxy in front of the registry), configure:
     Certificate: $(pwd)/server-cert.pem
     Private key:  $(pwd)/server-key.pem
   Include any intermediate chain if you use one; here the server cert is signed directly by ca-cert.pem.

2. In gryphon-forge, trust the offline CA for openshift-install / cluster nodes:
     mirror_registry_additional_trust_bundle: |
$(sed 's/^/       /' ca-cert.pem)

   Or paste the contents of ca-cert.pem into foundry / extra vars as a multiline PEM.

3. Regenerate ignition and redeploy (or replace certs on mirror + bounce registry, then retry bootstrap):
     ansible-playbook playbooks/deploy_cluster.yml ... --tags ignition
EOF

echo "Wrote TLS bundle to $outdir"
echo "Read $outdir/NEXT-STEPS.txt for mirror install-config and Forge variables."
