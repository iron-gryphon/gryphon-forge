#!/usr/bin/env bash
# List tags on a private OCI registry, pick the highest semver matching ocp minor (e.g. 4.20.*-x86_64).
# Used when ignition_mirror_discover_release_tag is true. Requires bash, jq, curl; optional skopeo (preferred).
# Usage:
#   discover-mirror-release-tag.sh --registry HOST[:PORT] --repo PATH --minor X.Y --arch ARCH --pull-secret FILE [--ca-file PEM]

set -euo pipefail

REGISTRY=""
REPO=""
MINOR=""
ARCH="x86_64"
PULL_SECRET=""
CA_FILE=""

usage() {
  echo "usage: $0 --registry HOST[:PORT] --repo NAME/REPO --minor X.Y --arch ARCH --pull-secret FILE [--ca-file PEM]" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --registry)
      REGISTRY="$2"
      shift 2
      ;;
    --repo)
      REPO="$2"
      shift 2
      ;;
    --minor)
      MINOR="$2"
      shift 2
      ;;
    --arch)
      ARCH="$2"
      shift 2
      ;;
    --pull-secret)
      PULL_SECRET="$2"
      shift 2
      ;;
    --ca-file)
      CA_FILE="$2"
      shift 2
      ;;
    -h | --help)
      usage
      ;;
    *)
      echo "unknown option: $1" >&2
      usage
      ;;
  esac
done

if [[ -z "${REGISTRY}" || -z "${REPO}" || -z "${MINOR}" || -z "${PULL_SECRET}" ]]; then
  usage
fi

if [[ ! -f "${PULL_SECRET}" ]]; then
  echo "pull secret not found: ${PULL_SECRET}" >&2
  exit 1
fi

command -v jq >/dev/null 2>&1 || {
  echo "jq is required for mirror tag discovery" >&2
  exit 1
}

MINOR_ESC="${MINOR//./\\.}"
PATTERN="^${MINOR_ESC}\\.[0-9]+-${ARCH}$"

discover_via_skopeo() {
  command -v skopeo >/dev/null 2>&1 || return 1
  local img="docker://${REGISTRY}/${REPO}"
  local -a args=(list-tags --authfile "${PULL_SECRET}" "${img}")
  if [[ -n "${CA_FILE}" && -f "${CA_FILE}" ]]; then
    SSL_CERT_FILE="${CA_FILE}" skopeo "${args[@]}"
  else
    skopeo "${args[@]}"
  fi
}

discover_via_curl() {
  local auth
  auth="$(jq -r --arg h "${REGISTRY}" \
    '.auths[$h].auth // .auths[$h + ":443"].auth // .auths[$h + ":5000"].auth // empty' \
    "${PULL_SECRET}")"
  local url="https://${REGISTRY}/v2/${REPO}/tags/list?n=10000"
  local -a curl_opts=(-fsS)
  if [[ -n "${CA_FILE}" && -f "${CA_FILE}" ]]; then
    curl_opts+=(--cacert "${CA_FILE}")
  fi
  if [[ -n "${auth}" ]]; then
    curl_opts+=(-H "Authorization: Basic ${auth}")
  fi
  curl "${curl_opts[@]}" "${url}"
}

JSON=""
if command -v skopeo >/dev/null 2>&1; then
  if out="$(discover_via_skopeo 2>/dev/null)"; then
    JSON="${out}"
  fi
fi
if [[ -z "${JSON}" ]]; then
  JSON="$(discover_via_curl)"
fi

TAGS=""
if echo "${JSON}" | jq -e '.Tags' >/dev/null 2>&1; then
  TAGS="$(echo "${JSON}" | jq -r '.Tags[]? // empty')"
elif echo "${JSON}" | jq -e '.tags' >/dev/null 2>&1; then
  TAGS="$(echo "${JSON}" | jq -r '.tags[]? // empty')"
else
  echo "unexpected registry response (expected Tags or tags)" >&2
  exit 1
fi

if [[ -z "${TAGS//[$'\t\r\n']/}" ]]; then
  echo "no tags returned for ${REGISTRY}/${REPO}" >&2
  exit 1
fi

BEST=""
BEST="$(echo "${TAGS}" | grep -E "${PATTERN}" || true)"
if [[ -z "${BEST}" ]]; then
  echo "no tags matching ${MINOR}.*-${ARCH} (pattern: ${PATTERN}) on ${REGISTRY}/${REPO}" >&2
  exit 1
fi

VER_LINE=""
VER_LINE="$(echo "${BEST}" | sed "s/-${ARCH}\$//" | sort -V | tail -1)"
echo "${VER_LINE}-${ARCH}"
