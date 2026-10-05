#!/usr/bin/env bash
# Mirrors the kubernetes-nmstate-operator from the Red Hat v4.22 operator
# index to the local bastion registry. Creates a pruned catalog index
# containing only this one operator (reducing catalog-pod cache-build from
# ~10 minutes to seconds) and copies all referenced operator images.
#
# Prerequisites:
#   - opm, oc, podman, skopeo, jq installed on this host
#   - Auth for registry.redhat.io in /run/user/0/containers/auth.json
#   - Auth for the mirror registry in podman login
#   - Mirror registry running (see below)
#
# Run this whenever the v4.22 index is updated (roughly every 2 weeks)
# or after setting up a fresh mirror registry.
#
# Usage: ./scripts/mirror-nmstate-operator.sh

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# bastion.lab.local is a placeholder, not a resolvable host - set
# MIRROR_REGISTRY_HOST (or MIRROR_REGISTRY for a full host:port) to your
# own registry. Kept out of git so this public repo carries no lab names.
MIRROR_HOST="${MIRROR_REGISTRY:-${MIRROR_REGISTRY_HOST:-bastion.lab.local}:${MIRROR_REGISTRY_PORT:-8443}}"
SOURCE_INDEX="registry.redhat.io/redhat/redhat-operator-index:v4.22"
PRUNED_TAG="${MIRROR_HOST}/redhat/redhat-operator-index:v4.22-nmstate-only"
WORK_DIR="/tmp/mirror-nmstate-work"
export XDG_RUNTIME_DIR=/run/user/0

echo "== Mirror NMState operator to ${MIRROR_HOST} =="
echo "Source index: ${SOURCE_INDEX}"
echo

mkdir -p "${WORK_DIR}"

# --- Step 1: Render the full catalog ---
echo "--- Step 1: Rendering full v4.22 catalog (this takes several minutes) ---"
opm render "${SOURCE_INDEX}" --output=json > "${WORK_DIR}/full-catalog.json" 2>"${WORK_DIR}/opm-render.log"
TOTAL_PKGS=$(jq -r 'select(.schema == "olm.package") | .name' "${WORK_DIR}/full-catalog.json" | wc -l)
echo "  Full catalog: ${TOTAL_PKGS} packages, $(du -h "${WORK_DIR}/full-catalog.json" | cut -f1)"

# --- Step 2: Prune to NMState only ---
echo "--- Step 2: Pruning to kubernetes-nmstate-operator only ---"
mkdir -p "${WORK_DIR}/pruned-catalog"
jq 'select(
  .package == "kubernetes-nmstate-operator" or
  (.schema == "olm.package" and .name == "kubernetes-nmstate-operator")
)' "${WORK_DIR}/full-catalog.json" > "${WORK_DIR}/pruned-catalog/index.json"

opm validate "${WORK_DIR}/pruned-catalog"
echo "  Pruned catalog: $(du -h "${WORK_DIR}/pruned-catalog/index.json" | cut -f1) (validated OK)"

# --- Step 3: Build and push pruned index image ---
echo "--- Step 3: Building and pushing pruned index image ---"
opm generate dockerfile "${WORK_DIR}/pruned-catalog" 2>/dev/null || true
podman build -t "${PRUNED_TAG}" -f "${WORK_DIR}/pruned-catalog.Dockerfile" "${WORK_DIR}" --quiet
podman push "${PRUNED_TAG}" --quiet
echo "  Pushed ${PRUNED_TAG}"

# --- Step 4: Generate mirror mappings ---
echo "--- Step 4: Generating mirror mappings ---"
rm -rf "${WORK_DIR}/manifests"
mkdir -p "${WORK_DIR}/manifests"
oc adm catalog mirror \
  "${PRUNED_TAG}" \
  "${MIRROR_HOST}" \
  --manifests-only \
  --to-manifests="${WORK_DIR}/manifests" \
  --index-filter-by-os="linux/amd64" \
  2>/dev/null

# Remove self-reference line
grep -v "^${MIRROR_HOST}" "${WORK_DIR}/manifests/mapping.txt" \
  > "${WORK_DIR}/manifests/mapping-filtered.txt"
IMG_COUNT=$(wc -l < "${WORK_DIR}/manifests/mapping-filtered.txt")
echo "  ${IMG_COUNT} images to mirror"

# --- Step 5: Mirror operator images ---
echo "--- Step 5: Mirroring operator images (${IMG_COUNT} images) ---"
oc image mirror \
  -f "${WORK_DIR}/manifests/mapping-filtered.txt" \
  --filter-by-os="linux/amd64" \
  --skip-missing=true \
  --max-per-registry=6

echo
echo "== Mirror complete =="
echo "Pruned catalog index: ${PRUNED_TAG}"
echo "IDMS manifest: ${WORK_DIR}/manifests/imageDigestMirrorSet.yaml"
echo
echo "Verify with:"
echo "  curl -s -u mirror:mirror-pass https://${MIRROR_HOST}/v2/_catalog | jq ."
