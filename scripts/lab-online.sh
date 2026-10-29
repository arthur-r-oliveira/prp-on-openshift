#!/usr/bin/env bash
# Exits 0 when both SNOs are up - API answering and the node Ready - and 1
# otherwise. CI runs this before any test, so a lab outage skips the suite
# instead of filling the dashboard with failures that say nothing about PRP
# (every sno-a check failing at once is the outage signature, not a result).
#
# With a wait (seconds), polls every 30s until both are up or time runs out:
# the continuous loop uses that to idle through an outage rather than
# re-dispatching itself every few seconds.
#
# Reads KUBECONFIG_{A,B} like the test scripts (the runner's .env sets them).
#
# Usage: ./lab-online.sh [wait-seconds]

set -uo pipefail

KUBECONFIG_A="${KUBECONFIG_A:-/home/libvirt-images/sno-install/sno-a/auth/kubeconfig}"
KUBECONFIG_B="${KUBECONFIG_B:-/home/libvirt-images/sno-install/sno-b/auth/kubeconfig}"
WAIT="${1:-0}"

# node_ready <name> <kubeconfig>: every node's Ready condition is True.
node_ready() {
  local status
  status=$(KUBECONFIG="$2" oc get nodes --request-timeout=15s \
    -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null)
  if [ -n "$status" ] && ! grep -qv '^True$' <<<"$status"; then
    echo "$1: Ready"
    return 0
  fi
  echo "$1: NOT ready (${status:-API unreachable})"
  return 1
}

deadline=$((SECONDS + WAIT))
while :; do
  a=0 b=0
  node_ready sno-a "$KUBECONFIG_A" || a=1
  node_ready sno-b "$KUBECONFIG_B" || b=1
  [ $a -eq 0 ] && [ $b -eq 0 ] && exit 0
  [ $SECONDS -ge $deadline ] && break
  sleep 30
done
echo "lab offline - skipping the tests"
exit 1
