#!/usr/bin/env bash
# Applies the Day-2 NMState operator + PRP NNCP configuration to both
# sno-a and sno-b after a fresh dual-sidecar-prp install.
#
# Three-tier install strategy:
#   1. Check if kubernetes-nmstate-operator is in any default OCP catalog
#   2. If not → add the mirror registry CatalogSource (pruned 4.22 index)
#      and check again
#   3. If still not → fall back to upstream kubernetes-nmstate from GitHub
#
# The upstream fallback exists because the Red Hat operator was dropped
# from the OCP 5.0 / v4.22 catalog. Filed as a bug — once the operator
# reappears in a default catalog, this script will automatically use it
# without needing the mirror.
#
# Usage: ./apply-day2-prp.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

KUBECONFIG_A="${KUBECONFIG_A:-/home/libvirt-images/sno-install/sno-a/auth/kubeconfig}"
KUBECONFIG_B="${KUBECONFIG_B:-/home/libvirt-images/sno-install/sno-b/auth/kubeconfig}"
NODE_A_IP="${NODE_A_IP:-192.168.130.101}"
NODE_B_IP="${NODE_B_IP:-192.168.130.102}"
SSH_USER="${SSH_USER:-core}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o BatchMode=yes)

NMSTATE_VERSION="${NMSTATE_VERSION:-v0.87.0}"
NMSTATE_BASE_URL="https://github.com/nmstate/kubernetes-nmstate/releases/download/${NMSTATE_VERSION}"

# The CatalogSource manifest ships a placeholder registry host so that no
# site-specific hostname is committed. A real lab exports its own; in CI
# that comes from a repository secret. Tier 2 cannot work without it - the
# placeholder does not resolve - so warn rather than spend 120s finding out.
MIRROR_PLACEHOLDER_HOST="bastion.lab.local"
MIRROR_REGISTRY_HOST="${MIRROR_REGISTRY_HOST:-$MIRROR_PLACEHOLDER_HOST}"

FAIL=0

wait_for() {
  local desc="$1" timeout="$2" cmd="$3"
  echo "  Waiting up to ${timeout}s for ${desc}..." >&2
  local elapsed=0
  while [ $elapsed -lt "$timeout" ]; do
    if eval "$cmd" >/dev/null 2>&1; then
      echo "  ${desc}: ready (${elapsed}s)" >&2
      return 0
    fi
    sleep 10
    elapsed=$((elapsed + 10))
  done
  echo "  ERROR: ${desc} not ready after ${timeout}s" >&2
  return 1
}

# install_via_olm <kubeconfig> <name> <catalog> <catalog-ns>
# Installs NMState via OLM (Namespace + OperatorGroup + Subscription).
# Prints the namespace on success, returns non-zero on failure.
install_via_olm() {
  local kc="$1" name="$2" catalog="$3" catalog_ns="$4"

  echo "  Using OLM: catalog=${catalog} (${catalog_ns})" >&2

  KUBECONFIG="$kc" oc apply -f - >&2 <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-nmstate
  labels:
    openshift.io/cluster-monitoring: "true"
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-nmstate
  namespace: openshift-nmstate
spec:
  targetNamespaces:
    - openshift-nmstate
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: kubernetes-nmstate-operator
  namespace: openshift-nmstate
spec:
  channel: stable
  name: kubernetes-nmstate-operator
  source: ${catalog}
  sourceNamespace: ${catalog_ns}
  installPlanApproval: Automatic
EOF

  if ! wait_for "${name} CSV Succeeded" 300 \
    "KUBECONFIG='$kc' oc get csv -n openshift-nmstate -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q Succeeded"; then
    return 1
  fi

  echo "  Downstream operator installed via OLM (${catalog})" >&2
  echo "openshift-nmstate"
}

# install_upstream <kubeconfig> <name>
# Installs upstream kubernetes-nmstate from GitHub releases.
# Prints the namespace on success, returns non-zero on failure.
install_upstream() {
  local kc="$1" name="$2"

  echo "  Falling back to upstream kubernetes-nmstate ${NMSTATE_VERSION}" >&2

  for manifest in nmstate.io_nmstates.yaml namespace.yaml service_account.yaml role.yaml role_binding.yaml operator.yaml; do
    KUBECONFIG="$kc" oc apply -f "${NMSTATE_BASE_URL}/${manifest}" >&2
  done

  # Upstream handler DaemonSet runs privileged containers — grant SCC
  KUBECONFIG="$kc" oc adm policy add-scc-to-user privileged \
    system:serviceaccount:nmstate:nmstate-operator -n nmstate >&2 2>&1 || true
  KUBECONFIG="$kc" oc adm policy add-scc-to-user privileged \
    system:serviceaccount:nmstate:nmstate-handler -n nmstate >&2 2>&1 || true

  if ! wait_for "${name} nmstate-operator ready" 300 \
    "KUBECONFIG='$kc' oc get deploy -n nmstate nmstate-operator -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -qE '^[1-9]'"; then
    return 1
  fi

  echo "  Upstream operator installed from GitHub releases" >&2
  echo "nmstate"
}

echo "== Day-2 PRP configuration =="
echo "sno-a kubeconfig: $KUBECONFIG_A"
echo "sno-b kubeconfig: $KUBECONFIG_B"
echo

declare -A NMSTATE_NS

for pair in "sno-a:$KUBECONFIG_A" "sno-b:$KUBECONFIG_B"; do
  name="${pair%%:*}"
  kc="${pair#*:}"
  echo "--- ${name}: installing kubernetes-nmstate ---"

  ns=""

  # Tier 1: check default OCP catalogs
  if KUBECONFIG="$kc" oc get packagemanifests kubernetes-nmstate-operator &>/dev/null; then
    echo "  Found kubernetes-nmstate-operator in default catalogs"
    catalog=$(KUBECONFIG="$kc" oc get packagemanifests kubernetes-nmstate-operator \
      -o jsonpath='{.status.catalogSource}' 2>/dev/null)
    catalog_ns=$(KUBECONFIG="$kc" oc get packagemanifests kubernetes-nmstate-operator \
      -o jsonpath='{.status.catalogSourceNamespace}' 2>/dev/null)
    ns=$(install_via_olm "$kc" "$name" "$catalog" "$catalog_ns")
  fi

  # Tier 2: add mirror registry CatalogSource (pruned 4.22 index) and retry
  if [ -z "$ns" ]; then
    echo "  Not in default catalogs, trying mirror registry..."
    if [ "$MIRROR_REGISTRY_HOST" = "$MIRROR_PLACEHOLDER_HOST" ]; then
      echo "  WARNING: MIRROR_REGISTRY_HOST is unset, so the CatalogSource"
      echo "  points at the placeholder ${MIRROR_PLACEHOLDER_HOST}, which does not"
      echo "  resolve. Expect this tier to time out and fall back to upstream."
    fi
    sed "s|${MIRROR_PLACEHOLDER_HOST}|${MIRROR_REGISTRY_HOST}|g" \
      day2-manifests/00-nmstate-catalogsource.yaml \
      | KUBECONFIG="$kc" oc apply -f -

    if wait_for "${name} mirror catalog pod ready" 120 \
      "KUBECONFIG='$kc' oc get pods -n openshift-marketplace -l olm.catalogSource=redhat-operators-4-22 -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q Running"; then

      # Give OLM a moment to sync the package list from the new catalog
      sleep 10

      if KUBECONFIG="$kc" oc get packagemanifests kubernetes-nmstate-operator &>/dev/null; then
        echo "  Found kubernetes-nmstate-operator via mirror registry catalog"
        catalog=$(KUBECONFIG="$kc" oc get packagemanifests kubernetes-nmstate-operator \
          -o jsonpath='{.status.catalogSource}' 2>/dev/null)
        catalog_ns=$(KUBECONFIG="$kc" oc get packagemanifests kubernetes-nmstate-operator \
          -o jsonpath='{.status.catalogSourceNamespace}' 2>/dev/null)
        ns=$(install_via_olm "$kc" "$name" "$catalog" "$catalog_ns")
      fi
    else
      echo "  Mirror catalog pod did not become ready"
    fi
  fi

  # Tier 3: upstream fallback
  if [ -z "$ns" ]; then
    ns=$(install_upstream "$kc" "$name")
  fi

  if [ $? -ne 0 ] || [ -z "$ns" ]; then
    echo "  ERROR: all install methods failed on ${name}"
    FAIL=1
    continue
  fi

  NMSTATE_NS[$name]="$ns"

  # NMState CR — cluster-scoped, works with both downstream and upstream
  KUBECONFIG="$kc" oc apply -f day2-manifests/02-nmstate-cr.yaml
  echo "  Applied NMState CR"

  # Wait for handler DaemonSet in the correct namespace
  if ! wait_for "${name} nmstate-handler ready" 300 \
    "KUBECONFIG='$kc' oc get ds -n '${ns}' nmstate-handler -o jsonpath='{.status.numberReady}' 2>/dev/null | grep -qE '^[1-9]'"; then
    FAIL=1
    continue
  fi

  # MachineConfig for hsr module autoload
  KUBECONFIG="$kc" oc apply -f day2-manifests/04-hsr-module-autoload.yaml
  echo "  Applied hsr module autoload MachineConfig"
  echo
done

if [ "$FAIL" -ne 0 ]; then
  echo "ERROR: operator installation failed on one or both nodes, skipping NNCP application"
  exit 1
fi

# Apply NNCPs — each node's NNCP goes to its own cluster
echo "--- Applying NNCPs ---"
KUBECONFIG="$KUBECONFIG_A" oc apply -f day2-manifests/03-nncp-sno-a.yaml
echo "  Applied NNCP to sno-a"
KUBECONFIG="$KUBECONFIG_B" oc apply -f day2-manifests/03-nncp-sno-b.yaml
echo "  Applied NNCP to sno-b"
echo

# Wait for MachineConfig-triggered reboots before checking NNCPs
echo "--- Waiting for MachineConfig rollout (node reboots) ---"
for pair in "sno-a:$KUBECONFIG_A" "sno-b:$KUBECONFIG_B"; do
  name="${pair%%:*}"
  kc="${pair#*:}"
  if ! wait_for "${name} MachineConfigPool updated" 600 \
    "KUBECONFIG='$kc' oc get mcp master -o jsonpath='{.status.conditions[?(@.type==\"Updated\")].status}' 2>/dev/null | grep -q True"; then
    echo "  WARNING: ${name} MCP not yet Updated, continuing"
  fi
done
echo

# Wait for NNCPs to be Available
for pair in "sno-a:$KUBECONFIG_A" "sno-b:$KUBECONFIG_B"; do
  name="${pair%%:*}"
  kc="${pair#*:}"
  if ! wait_for "${name} NNCP Available" 300 \
    "KUBECONFIG='$kc' oc get nncp prp0-hsr -o jsonpath='{.status.conditions[?(@.type==\"Available\")].status}' 2>/dev/null | grep -q True"; then
    FAIL=1
  fi
done

# Verify prp0 is actually up on both nodes via SSH
echo
echo "--- Verifying prp0 on nodes ---"
for pair in "sno-a:$NODE_A_IP" "sno-b:$NODE_B_IP"; do
  name="${pair%%:*}"
  ip="${pair#*:}"
  if ! wait_for "${name} prp0 link up" 120 \
    "ssh ${SSH_OPTS[*]} ${SSH_USER}@${ip} 'ip -br link show prp0 2>/dev/null | grep -q UP'"; then
    FAIL=1
  else
    proto=$(ssh "${SSH_OPTS[@]}" "$SSH_USER@$ip" "ip -d link show prp0 2>/dev/null" \
      | grep -o 'proto [0-9]' | awk '{print $2}')
    echo "  ${name} prp0 proto=${proto} (1=PRP, 0=HSR)"
  fi
done

echo
if [ "$FAIL" -eq 0 ]; then
  echo "== Day-2 PRP configuration complete, prp0 is up on both nodes =="
else
  echo "== Day-2 PRP configuration finished with errors =="
fi
exit $FAIL
