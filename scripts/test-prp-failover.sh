#!/usr/bin/env bash
# CI test suite for the PRP-over-dual-SNO deployment. Verifies, end to end:
#   1. both clusters report healthy (ClusterVersion Available, 0 degraded co)
#   2. prp0 exists on both nodes and is in true PRP mode (proto 1, not HSR/proto 0)
#   3. sno-a can reach sno-b over prp0
#   4. a real hypervisor-level failure of ONE PRP path (prp-lan-a) causes
#      ZERO packet loss on a continuous ping running through the outage
#
# Must run somewhere with: `oc` on PATH, `virsh` on PATH (i.e. on the KVM
# host itself, or a self-hosted CI runner with libvirt + SSH access to it),
# and passwordless SSH (agent or default key) to both nodes as `core`.
#
# Without virsh (SNOs on other hypervisors, handed over for Day-2):
# CUT_METHOD=node takes PRP_LAN_A_IFACE down from inside the node instead.
# The kernel then sees a carrier loss rather than a silent wire, which is a
# weaker test of PRP than a hypervisor-side cut, but still proves zero loss
# through a dead path. Pair with NODE_EXEC=oc-debug (scripts/node-exec.sh)
# when there is no node SSH key either.
#
# All defaults match vars/main.yml's out-of-the-box values - override via
# env if your deployment customized them (see the block below).
#
# Exit code 0 = every test passed, 1 = at least one failed. Prints one
# [PASS]/[FAIL] line per test plus a summary, so CI log output is legible
# without opening this script.
#
# Usage: ./test-prp-failover.sh

set -uo pipefail

NODE_A_NAME="${NODE_A_NAME:-sno-a}"
NODE_B_NAME="${NODE_B_NAME:-sno-b}"
NODE_A_IP="${NODE_A_IP:-192.168.130.101}"
NODE_B_IP="${NODE_B_IP:-192.168.130.102}"
PRP_A_IP="${PRP_A_IP:-10.10.10.1}"
PRP_B_IP="${PRP_B_IP:-10.10.10.2}"
PRP_LAN_A_NETWORK="${PRP_LAN_A_NETWORK:-prp-lan-a}"
KUBECONFIG_A="${KUBECONFIG_A:-/home/libvirt-images/sno-install/sno-a/auth/kubeconfig}"
KUBECONFIG_B="${KUBECONFIG_B:-/home/libvirt-images/sno-install/sno-b/auth/kubeconfig}"
NODE_A_HOSTNAME="${NODE_A_HOSTNAME:-sno-a.apps.lab.corp}"
NODE_B_HOSTNAME="${NODE_B_HOSTNAME:-sno-b.apps.lab.corp}"
CUT_METHOD="${CUT_METHOD:-virsh}"              # virsh | node
PRP_LAN_A_IFACE="${PRP_LAN_A_IFACE:-enp6s0}"   # node-side name, CUT_METHOD=node only
FAILOVER_DURATION="${FAILOVER_DURATION:-20}"  # total ping window, seconds
CUT_AT="${CUT_AT:-3}"                          # seconds into the window to cut the link
RESTORE_AT="${RESTORE_AT:-11}"                 # seconds into the window to restore it

# shellcheck source=node-exec.sh
. "$(dirname "${BASH_SOURCE[0]}")/node-exec.sh"

PASS=0
FAIL=0

record() {
  local status="$1" name="$2" detail="${3:-}"
  if [ "$status" = "PASS" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi
  printf '[%s] %s%s\n' "$status" "$name" "${detail:+ - $detail}"
}

packet_loss_pct() {
  # Portable extraction of "N% packet loss" from ping's summary line -
  # avoids relying on grep -P (PCRE) for CI runner portability.
  sed -n 's/.*, \([0-9]\{1,3\}\)% packet loss.*/\1/p' "$1" | tail -1
}

echo "== PRP over Dual SNO :: CI test suite =="
echo "sno-a=$NODE_A_IP  sno-b=$NODE_B_IP  prp0: $PRP_A_IP <-> $PRP_B_IP"
echo

# --- 1. Both clusters report healthy ------------------------------------
for pair in "sno-a:$KUBECONFIG_A" "sno-b:$KUBECONFIG_B"; do
  name="${pair%%:*}"
  kc="${pair#*:}"
  if [ ! -r "$kc" ]; then
    record FAIL "cluster-health:$name" "kubeconfig not readable: $kc"
    continue
  fi
  avail=$(KUBECONFIG="$kc" oc get clusterversion version \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)
  unhealthy=$(KUBECONFIG="$kc" oc get co --no-headers 2>/dev/null \
    | awk '$3!="True" || $4!="False" || $5!="False" {print $1}')
  if [ "$avail" = "True" ] && [ -z "$unhealthy" ]; then
    record PASS "cluster-health:$name" "ClusterVersion Available, all operators healthy"
  else
    record FAIL "cluster-health:$name" "Available=$avail unhealthy_operators=[$(echo "$unhealthy" | tr '\n' ',')]"
  fi
done
echo

# --- 2. prp0 exists and is in true PRP mode on both nodes ---------------
for side in a b; do
  name="sno-${side}"
  proto=$(node_sh "$side" "ip -d link show prp0 2>/dev/null" \
    | grep -o 'proto [0-9]' | awk '{print $2}')
  case "$proto" in
    1) record PASS "prp0-mode:$name" "proto=1 (PRP)" ;;
    0) record FAIL "prp0-mode:$name" "proto=0 - fell back to HSR mode, not PRP" ;;
    *) record FAIL "prp0-mode:$name" "prp0 interface not found or host unreachable" ;;
  esac
done
echo

# --- 3. Cross-node reachability over prp0 -------------------------------
ping_log=$(mktemp)
node_sh a "ping -c5 -W2 $PRP_B_IP" > "$ping_log" 2>&1
loss=$(packet_loss_pct "$ping_log")
if [ "$loss" = "0" ]; then
  record PASS "prp0-reachability" "0% loss, sno-a -> sno-b over prp0"
else
  record FAIL "prp0-reachability" "packet loss=${loss:-unknown}%"
fi
rm -f "$ping_log"
echo

# --- 4. Failover: cut prp-lan-a mid-traffic, expect 0% loss --------------
if [ "$CUT_METHOD" = node ]; then
  # Ping and cut share one session on sno-a, so the cut lands exactly
  # CUT_AT seconds into the ping however slow the session was to start.
  # The trap brings the port back even if the session is killed mid-cut.
  # CUT-OK only prints once the kernel reports the port down, so a cut
  # that silently failed cannot pass as zero loss.
  ping_log=$(mktemp)
  node_sh a "ip link show $PRP_LAN_A_IFACE >/dev/null || exit 9
    trap 'ip link set $PRP_LAN_A_IFACE up' EXIT
    ping -i 0.2 -w $FAILOVER_DURATION $PRP_B_IP &
    sleep $CUT_AT; ip link set $PRP_LAN_A_IFACE down
    ip -br link show $PRP_LAN_A_IFACE | grep -qw DOWN && echo CUT-OK
    sleep $((RESTORE_AT - CUT_AT)); ip link set $PRP_LAN_A_IFACE up
    wait" > "$ping_log" 2>&1
  loss=$(packet_loss_pct "$ping_log")
  if ! grep -q CUT-OK "$ping_log"; then
    record FAIL "failover-prp-lan-a" "$PRP_LAN_A_IFACE never went down on sno-a - link was never actually cut"
  elif [ "$loss" = "0" ]; then
    record PASS "failover-prp-lan-a" "0% packet loss with $PRP_LAN_A_IFACE down for $((RESTORE_AT - CUT_AT))s"
  else
    record FAIL "failover-prp-lan-a" "packet loss=${loss:-unknown}% - $(tail -3 "$ping_log" | tr '\n' ' ')"
  fi
  rm -f "$ping_log"
  mac=""
else
# virsh domiflist columns: Interface Type Source Model MAC (5 columns) -
# the MAC is $5, NOT $4 (that's the Model, e.g. "virtio").
mac=$(virsh domiflist "$NODE_A_NAME" 2>/dev/null | awk -v net="$PRP_LAN_A_NETWORK" '$3==net {print $5}')
if [ -z "$mac" ]; then
  record FAIL "failover-prp-lan-a" "could not resolve $NODE_A_NAME's vNIC MAC on $PRP_LAN_A_NETWORK via virsh domiflist"
else
  ping_log=$(mktemp)
  node_sh a "ping -i 0.2 -w $FAILOVER_DURATION $PRP_B_IP" > "$ping_log" 2>&1 &
  ping_pid=$!

  sleep "$CUT_AT"
  if ! virsh domif-setlink "$NODE_A_NAME" "$mac" down; then
    kill "$ping_pid" 2>/dev/null; wait "$ping_pid" 2>/dev/null
    record FAIL "failover-prp-lan-a" "virsh domif-setlink ... down failed for MAC $mac - link was never actually cut"
    rm -f "$ping_log"
    mac=""
  fi
fi
if [ -n "${mac:-}" ] && [ -f "$ping_log" ]; then
  sleep "$((RESTORE_AT - CUT_AT))"
  if ! virsh domif-setlink "$NODE_A_NAME" "$mac" up; then
    echo "WARNING: failed to restore link for MAC $mac - fix manually with: virsh domif-setlink $NODE_A_NAME $mac up" >&2
  fi

  wait "$ping_pid" 2>/dev/null
  loss=$(packet_loss_pct "$ping_log")
  if [ "$loss" = "0" ]; then
    record PASS "failover-prp-lan-a" "0% packet loss with prp-lan-a down for $((RESTORE_AT - CUT_AT))s"
  else
    record FAIL "failover-prp-lan-a" "packet loss=${loss:-unknown}% - $(tail -3 "$ping_log" | tr '\n' ' ')"
  fi
  rm -f "$ping_log"
fi
fi
echo

# --- 5. Kernel-level PRP node table shows the peer (per Red Hat's KB on
#        configuring HSR/PRP with nmstate - not just IP-level reachability) --
for side in a b; do
  name="sno-${side}"
  table=$(node_sh "$side" "sudo cat /sys/kernel/debug/hsr/prp0/node_table 2>/dev/null")
  # node_table rows list the PEER's MAC, not an IP - just confirm the
  # table has at least one real (non-header) entry.
  entries=$(echo "$table" | grep -c '^[0-9a-f][0-9a-f]:')
  if [ "${entries:-0}" -ge 1 ]; then
    record PASS "prp-node-table:$name" "$entries peer entr$([ "$entries" = 1 ] && echo y || echo ies) in /sys/kernel/debug/hsr/prp0/node_table"
  else
    record FAIL "prp-node-table:$name" "no peer registered at the HSR/PRP protocol level (debugfs table empty)"
  fi
done
echo

echo "== Summary: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
