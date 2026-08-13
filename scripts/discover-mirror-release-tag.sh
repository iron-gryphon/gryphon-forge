#!/usr/bin/env bash
# List tags on a private OCI registry, pick the highest semver matching ocp minor (e.g. 4.21.*-x86_64).
# Used when ignition_mirror_discover_release_tag is true. Requires bash, jq, curl; optional skopeo (preferred).
#
# Match this script to your mirror destination (path must be identical to oc-mirror / oc adm release mirror --to):
#   export MIRROR_REGISTRY_URL='mirror.fsi.internal'
#   oc mirror --authfile "$HOME/.openshift/pull-secret" -c ~/imageset-config.yml \
#     --workspace "file://$HOME/oc-mirror-workspace" \
#     "docker://${MIRROR_REGISTRY_URL}/openshift/release" --v2
# Mapping: docker://<HOST>/<REPO_PATH>  ->  --registry <HOST>  --repo <REPO_PATH>
#          e.g. docker://mirror.fsi.internal/openshift/release  ->  openshift/release (mirror_registry_release_path in Ansible)
#
# Usage:
#   discover-mirror-release-tag.sh --registry HOST[:PORT] --repo PATH --minor X.Y --arch ARCH --pull-secret FILE [--scheme http|https] [--ca-file PEM]
#
# Note: The ocp-release payload uses tags like 4.21.z-x86_64 (not 4.21.z-x86_64-<component>). A repo may list only
# component tags under .../openshift/release/openshift/release; this script skips those and prefers
# openshift/release/openshift/release-images (oc-mirror v2), then openshift/release/openshift-release-dev/ocp-release
# or openshift-release-dev/ocp-release when REPO is openshift/release.

set -euo pipefail

REGISTRY=""
REPO=""
MINOR=""
ARCH="x86_64"
PULL_SECRET=""
CA_FILE=""
SCHEME="https"

usage() {
  echo "usage: $0 --registry HOST[:PORT] --repo NAME/REPO --minor X.Y --arch ARCH --pull-secret FILE [--scheme http|https] [--ca-file PEM]" >&2
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
    --scheme)
      SCHEME="$2"
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

EFFECTIVE_REPO="${REPO}"

if [[ ! -f "${PULL_SECRET}" ]]; then
  echo "pull secret not found: ${PULL_SECRET}" >&2
  exit 1
fi

if [[ "${SCHEME}" != "http" && "${SCHEME}" != "https" ]]; then
  echo "--scheme must be http or https (got: ${SCHEME})" >&2
  exit 2
fi

command -v jq >/dev/null 2>&1 || {
  echo "jq is required for mirror tag discovery" >&2
  exit 1
}

MINOR_ESC="${MINOR//./\\.}"
# Prefer arch-specific tags (e.g. 4.21.16-x86_64); fall back to -multi or bare patch (4.21.16).
PATTERN_ARCH="^${MINOR_ESC}\\.[0-9]+-${ARCH}$"
PATTERN_MULTI="^${MINOR_ESC}\\.[0-9]+-multi$"
PATTERN_PLAIN="^${MINOR_ESC}\\.[0-9]+$"

# True if the tag list includes an ocp-release payload tag (e.g. 4.21.2-x86_64), not only component tags
# like 4.21.2-x86_64-openshift-apiserver (oc-mirror can put those under openshift/release/openshift/release).
json_has_release_payload_tag() {
  local json="$1"
  local tags
  tags="$(echo "${json}" | jq -r '.Tags[]? // empty' 2>/dev/null)"
  if [[ -z "${tags//[$'\t\r\n']/}" ]]; then
    tags="$(echo "${json}" | jq -r '.tags[]? // empty' 2>/dev/null)"
  fi
  echo "${tags}" | grep -qE "${PATTERN_ARCH}" && return 0
  echo "${tags}" | grep -qE "${PATTERN_MULTI}" && return 0
  echo "${tags}" | grep -qE "${PATTERN_PLAIN}" && return 0
  return 1
}

# Repo is usable if it has a strict release tag or only oc-mirror component tags (4.21.z-x86_64-name) so we can infer 4.21.z-x86_64.
json_has_usable_release_tag() {
  local json="$1"
  json_has_release_payload_tag "${json}" && return 0
  local tags
  tags="$(echo "${json}" | jq -r '.Tags[]? // empty' 2>/dev/null)"
  if [[ -z "${tags//[$'\t\r\n']/}" ]]; then
    tags="$(echo "${json}" | jq -r '.tags[]? // empty' 2>/dev/null)"
  fi
  echo "${tags}" | grep -qE "^${MINOR_ESC}\\.[0-9]+-${ARCH}-" && return 0
  return 1
}

# Docker config.json auths keys vary: host, host:443, host:5000, etc.
resolve_registry_auth() {
  local ps="$1" reg="$2"
  local base="${reg%%:*}"
  local k a
  for k in "$reg" "${base}:443" "${base}:5000" "${base}"; do
    a="$(jq -r --arg k "$k" '.auths[$k].auth // empty' "$ps" 2>/dev/null || true)"
    if [[ -n "$a" ]]; then
      printf '%s' "$a"
      return 0
    fi
  done
  jq -r --arg b "$base" '
    [.auths | to_entries[]
      | select(.key == $b or (.key | startswith($b + ":")) or (.key | startswith($b + "/")))
      | .value.auth]
    | map(select(length > 0)) | first // empty
  ' "$ps" 2>/dev/null
}

curl_registry_get() {
  local url="$1"
  local -a curl_opts=(-fsS)
  if [[ -n "${CA_FILE}" && -f "${CA_FILE}" ]]; then
    curl_opts+=(--cacert "${CA_FILE}")
  fi
  local auth
  auth="$(resolve_registry_auth "${PULL_SECRET}" "${REGISTRY}")"
  if [[ -n "${auth}" ]]; then
    curl_opts+=(-H "Authorization: Basic ${auth}")
  fi
  curl "${curl_opts[@]}" "${url}"
}

# Fetch tag pages for a repository. Uses ?last= for Docker Registry v2; if a continuation request fails (e.g. 404 —
# Quay and others may not support ?last=), returns tags collected from successful pages only.
# Prints merged JSON { "Tags": [ ... ] } on stdout; exit 1 only if the first request fails.
curl_tags_list_paginated() {
  local repo="$1"
  shift
  local page_n=1000
  local last=""
  local merged='[]'
  local p=0
  while [[ $p -lt 200 ]]; do
    local u="${SCHEME}://${REGISTRY}/v2/${repo}/tags/list?n=${page_n}"
    if [[ -n "$last" ]]; then
      u+="&last=$(printf '%s' "$last" | jq -sRr @uri)"
    fi
    local out
    if ! out="$(curl "$@" "$u" 2>&1)"; then
      if [[ "$p" -eq 0 ]]; then
        echo "${out}" >&2
        return 1
      fi
      break
    fi
    local chunk cnt
    chunk="$(echo "${out}" | jq -c '(.tags // .Tags) // []' 2>/dev/null)" || {
      echo "invalid tags/list JSON for ${repo}" >&2
      echo "${out}" >&2
      return 1
    }
    cnt="$(echo "${chunk}" | jq 'length')"
    merged="$(jq -n --argjson a "$merged" --argjson b "$chunk" '$a + $b')"
    if [[ "$cnt" -lt "$page_n" ]] || [[ "$cnt" -eq 0 ]]; then
      break
    fi
    last="$(echo "${out}" | jq -r '(.tags // .Tags)[-1] // empty')"
    [[ -z "$last" || "$last" == "null" ]] && break
    p=$((p + 1))
  done
  jq -n --argjson tags "$merged" '{Tags: $tags}'
}

suggest_repos_on_404() {
  local catalog_url="${SCHEME}://${REGISTRY}/v2/_catalog?n=1000"
  local out
  if ! out="$(curl_registry_get "${catalog_url}" 2>&1)"; then
    echo "GET /v2/_catalog failed (many registries disable catalog or need different auth). Check the repository path in oc-mirror cluster-resources (IDMS/ITMS) or try:" >&2
    echo "  skopeo list-tags docker://${REGISTRY}/openshift-release-dev/ocp-release" >&2
    echo "  skopeo list-tags docker://${REGISTRY}/${REPO}/openshift-release-dev/ocp-release" >&2
    echo "${out}" >&2
    return
  fi
  echo "Registry returned 404 for tags/list; repositories on this registry (subset — pick the path that lists 4.x.z-${ARCH} tags, then set mirror_registry_release_path to it):" >&2
  echo "${out}" | jq -r '.repositories[]? // empty' 2>/dev/null | grep -E 'openshift|ocp|release' | head -50 >&2 || true
}

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
  local auth out url last_err try
  local -a try_paths=("${REPO}")
  if [[ "${REPO}" == "openshift/release" ]]; then
    # oc-mirror v2 uses openshift/release/openshift/release-images; v1 / oc adm uses openshift-release-dev/ocp-release.
    # openshift/release/openshift/release holds only per-component tags (4.21.z-arch-name).
    try_paths+=(
      "openshift/release/openshift/release-images"
      "openshift/release/openshift-release-dev/ocp-release"
      "openshift-release-dev/ocp-release"
      "openshift/release/openshift/release"
    )
  fi

  auth="$(resolve_registry_auth "${PULL_SECRET}" "${REGISTRY}")"
  local -a curl_opts=(-fsS)
  if [[ -n "${CA_FILE}" && -f "${CA_FILE}" ]]; then
    curl_opts+=(--cacert "${CA_FILE}")
  fi
  if [[ -n "${auth}" ]]; then
    curl_opts+=(-H "Authorization: Basic ${auth}")
  fi

  last_err=""
  for try in "${try_paths[@]}"; do
    if out="$(curl_tags_list_paginated "${try}" "${curl_opts[@]}")"; then
      if json_has_usable_release_tag "${out}"; then
        EFFECTIVE_REPO="${try}"
        JSON="${out}"
        if [[ "${try}" != "${REPO}" ]]; then
          echo "note: using mirror repo path ${try} (set mirror_registry_release_path: \"${try}\" to align install-config / mirror CRs and skip this probe)." >&2
        fi
        return 0
      fi
      echo "note: ${try} has no usable ${MINOR} release or component tags; skipping." >&2
      last_err="no release payload tag in ${try}"
      continue
    fi
    last_err="GET tags/list failed for ${try}"
  done

  echo "mirror tag discovery failed: no repository had a usable ${MINOR} release tag (exact, -multi, bare patch, or ${MINOR}.z-${ARCH}-* components); last error:" >&2
  if [[ -z "${auth}" ]]; then
    echo "No auth found in pull secret for registry host ${REGISTRY} (check .auths keys match your mirror)." >&2
  fi
  echo "${last_err}" >&2
  if echo "${last_err}" | grep -q '404'; then
    suggest_repos_on_404
  fi
  echo "Set mirror_registry_release_path to the repository that contains your release tags (must match imageDigestSources mirror prefix / oc-mirror destination layout)." >&2
  exit 1
}

JSON=""
SKOPEO_ERR=""
if command -v skopeo >/dev/null 2>&1; then
  _sf="$(mktemp)"
  if out="$(discover_via_skopeo 2>"${_sf}")"; then
    if json_has_usable_release_tag "${out}"; then
      JSON="${out}"
    else
      SKOPEO_ERR="skopeo listed tags for ${REPO} but none usable for ${MINOR} release; trying curl."
    fi
  else
    SKOPEO_ERR="$(cat "${_sf}" 2>/dev/null || true)"
  fi
  rm -f "${_sf}"
fi
if [[ -z "${JSON}" ]]; then
  if [[ -n "${SKOPEO_ERR}" ]]; then
    echo "skopeo list-tags failed:" >&2
    echo "${SKOPEO_ERR}" >&2
  fi
  # Must not use JSON="$(discover_via_curl)" — command substitution runs the function in a subshell and
  # drops assignments to EFFECTIVE_REPO (nested mirror path).
  discover_via_curl
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
  echo "no tags returned for ${REGISTRY}/${EFFECTIVE_REPO}" >&2
  exit 1
fi

FULL_TAG=""
if BEST="$(echo "${TAGS}" | grep -E "${PATTERN_ARCH}" || true)" && [[ -n "${BEST//[$'\t\r\n']/}" ]]; then
  VER_LINE=""
  VER_LINE="$(echo "${BEST}" | sed "s/-${ARCH}\$//" | sort -V | tail -1)"
  FULL_TAG="${VER_LINE}-${ARCH}"
elif BEST="$(echo "${TAGS}" | grep -E "${PATTERN_MULTI}" || true)" && [[ -n "${BEST//[$'\t\r\n']/}" ]]; then
  # Multi-arch manifest (common on oc-mirror); use tag as-is for override.
  FULL_TAG="$(echo "${BEST}" | sort -V | tail -1)"
elif BEST="$(echo "${TAGS}" | grep -E "${PATTERN_PLAIN}" || true)" && [[ -n "${BEST//[$'\t\r\n']/}" ]]; then
  VER_LINE="$(echo "${BEST}" | sort -V | tail -1)"
  FULL_TAG="${VER_LINE}-${ARCH}"
elif INFERRED="$(echo "${TAGS}" | grep -oE "^${MINOR_ESC}\\.[0-9]+-${ARCH}" 2>/dev/null | sort -V | tail -1)" && [[ -n "${INFERRED}" ]]; then
  # e.g. tags are only 4.21.2-x86_64-openshift-apiserver — infer highest 4.21.z-x86_64 for the override.
  FULL_TAG="${INFERRED}"
  echo "note: inferred release tag ${INFERRED} from component tag prefixes (verify mirror has image ...:${INFERRED})." >&2
else
  echo "no tags matching ${MINOR}.* (${ARCH}-suffixed, -multi, bare patch, or inferable ${MINOR}.z-${ARCH}-*) on ${REGISTRY}/${EFFECTIVE_REPO}" >&2
  echo "patterns tried: ${PATTERN_ARCH} | ${PATTERN_MULTI} | ${PATTERN_PLAIN} | infer-from-component" >&2
  echo "sample tags from registry (up to 50):" >&2
  echo "${TAGS}" | sort -V | tail -50 >&2
  exit 1
fi

if [[ "${EFFECTIVE_REPO}" != "${REPO}" ]]; then
  echo "${EFFECTIVE_REPO}"
fi
echo "${FULL_TAG}"
