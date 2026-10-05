#!/usr/bin/env bash
# UDP benchmark over the PRP link, with the redundant path cut twice mid-run.
#
# The existing test-prp-failover.sh proves PRP works using ping - about 1
# packet/sec. This runs the Quarkus benchmark at a real rate (5000 msg/s,
# ~1.5M packets over 5 minutes) and cuts one PRP LAN, then the other, while
# traffic is flowing.
#
# WHY THE REDUNDANCY ASSERTIONS ARE THE POINT: PRP masks a dead LAN
# completely - loss stays 0, latency does not move, no application metric
# changes. A test that cuts a link and asserts "0% loss" therefore passes
# identically whether the cut happened or silently failed. Two consequences,
# both verified against this lab:
#
#   1. The app's `redundancyOk` is derived from a ratio gated on
#      `busiest > 10` pkt/s (HostNetworkMetrics.java), so with no traffic
#      nothing is "degraded" and redundancyOk reads true. An idle receiver
#      reports rxPerSec 1 on both LANs and redundancyOk true. Hence the
#      baseline-traffic assertion: without a traffic floor, every other
#      redundancy check is vacuous.
#   2. Both PRP slaves carry prp0's MAC (copy-mac-from), so the libvirt vNIC
#      MAC survives in the guest ONLY as `permaddr`. Mapping a libvirt
#      network to a guest interface by link/ether matches both slaves and
#      silently picks the wrong one.
#
# Must run on the KVM host: needs oc, virsh, curl, jq, and SSH to both nodes.
#
# Usage: ./test-prp-bench.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

NODE_A_NAME="${NODE_A_NAME:-sno-a}"
NODE_B_NAME="${NODE_B_NAME:-sno-b}"
NODE_A_IP="${NODE_A_IP:-192.168.130.101}"
NODE_B_IP="${NODE_B_IP:-192.168.130.102}"
KUBECONFIG_A="${KUBECONFIG_A:-/home/libvirt-images/sno-install/sno-a/auth/kubeconfig}"
KUBECONFIG_B="${KUBECONFIG_B:-/home/libvirt-images/sno-install/sno-b/auth/kubeconfig}"
PRP_LAN_A_NETWORK="${PRP_LAN_A_NETWORK:-prp-lan-a}"
PRP_LAN_B_NETWORK="${PRP_LAN_B_NETWORK:-prp-lan-b}"
MGMT_NETWORK="${MGMT_NETWORK:-ocp-public}"
SSH_USER="${SSH_USER:-core}"
PRP_BENCH_REPO="${PRP_BENCH_REPO:-$(cd .. 2>/dev/null && pwd)/quarkus-prp-bench}"
LOG_DIR="${LOG_DIR:-/tmp/sno-test-matrix-logs}"

# Run shape. Defaults are the live-proven operating point for this VM lab:
# 5000 msg/s / 256B gives 0% loss with RTT p50 ~770us. The app's practical
# ceiling here is ~27k pkt/s, so this sits far enough below that a zero-loss
# assertion means something rather than being a coin flip.
RATE="${RATE:-5000}"
PAYLOAD="${PAYLOAD:-256}"
DURATION="${DURATION:-300}"
CUT1_AT="${CUT1_AT:-60}"
CUT2_AT="${CUT2_AT:-180}"
CUT_LEN="${CUT_LEN:-30}"
BASELINE_AT="${BASELINE_AT:-25}"
POLL="${POLL:-2.5}"
# Traffic floor for "this LAN is carrying the stream". 80% of rate leaves room
# for pacing jitter without being loose enough to pass a dead link.
FLOOR="${FLOOR:-$((RATE * 80 / 100))}"
MIN_DEGRADED_SAMPLES="${MIN_DEGRADED_SAMPLES:-3}"
# Counters refresh at 1Hz, so allow a few seconds after a link change before
# believing a sample either way.
SETTLE="${SETTLE:-5}"
RECOVER_WINDOW="${RECOVER_WINDOW:-30}"
WATCHDOG_TIMEOUT="${WATCHDOG_TIMEOUT:-600}"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o BatchMode=yes)

mkdir -p "$LOG_DIR"
SAMPLES="$LOG_DIR/prp-bench-samples.jsonl"
: > "$SAMPLES"

PASS=0
FAIL=0
SAMPLER_PID=""
DONE_FLAG="/tmp/prp-bench-watchdog-done.$$"
WD_PIDFILE="/tmp/prp-bench-watchdog-pid.$$"
declare -a ALL_LINKS=()

record() {
  local status="$1" name="$2" detail="${3:-}"
  if [ "$status" = "PASS" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi
  printf '[%s] %s%s\n' "$status" "$name" "${detail:+ - $detail}"
}

# virsh domiflist columns: Interface Type Source Model MAC - the MAC is $5,
# NOT $4 (that's the Model, e.g. "virtio").
mac_of() {
  virsh domiflist "$1" 2>/dev/null | awk -v n="$2" '$3==n {print $5}'
}

# Map a libvirt vNIC MAC to its guest interface name. Must match on permaddr:
# both PRP slaves present prp0's MAC in link/ether, so link/ether is ambiguous.
ifname_of() {
  ssh "${SSH_OPTS[@]}" "$SSH_USER@$1" \
    "ip -o link show" 2>/dev/null \
    | sed -n "s/^[0-9]*: \([^:]*\):.*permaddr $2.*/\1/p" | head -1
}

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  [ -n "$SAMPLER_PID" ] && kill "$SAMPLER_PID" 2>/dev/null
  for link in "${ALL_LINKS[@]}"; do
    # shellcheck disable=SC2086
    if ! virsh domif-setlink $link up >/dev/null 2>&1; then
      echo "[FAIL] prp-bench:link-restore - vNIC still down, fix with: virsh domif-setlink $link up"
    fi
  done
  # Two independent disarms: the flag makes the watchdog no-op if it already
  # slipped past us, and the pidfile stops it sleeping on a CI runner for ten
  # minutes after a clean run. Only the flag survives a SIGKILL of this shell.
  touch "$DONE_FLAG"
  if [ -f "$WD_PIDFILE" ] && kill "$(cat "$WD_PIDFILE")" 2>/dev/null; then
    # Watchdog is gone, so the flag has nothing left to disarm.
    rm -f "$DONE_FLAG"
  fi
  rm -f "$WD_PIDFILE"
  exit $rc
}

# Absolute-deadline wait. Never accumulate sleeps across a 5 minute run -
# poll and HTTP latency drift enough to smear the cut windows.
wait_until() {
  local target="$1" now
  while :; do
    now=$(date +%s)
    [ $((now - T0)) -ge "$target" ] && return 0
    sleep 0.5
  done
}

sampler() {
  local now rel js
  while :; do
    now=$(date +%s); rel=$((now - T0))
    if js=$(curl -sf --max-time 2 "http://$NODE_B_IP:8080/api/stats" 2>/dev/null); then
      printf '%s' "$js" | jq -c --argjson t "$rel" '{
        t: $t, received, lost, lossPercent,
        rcvbufErr: .host.udpRcvbufErrors,
        ok: .host.redundancyOk,
        n: (.host.lans | length),
        lans: ([.host.lans[] | {(.iface): {r: .rxPerSec, d: .degraded}}] | add)
      }' >> "$SAMPLES" 2>/dev/null
    fi
    sleep "$POLL"
  done
}

# Samples in [lo,hi] where the named interface is silent AND the app agrees
# redundancy is lost. Both halves matter: rxPerSec==0 alone could be a
# counter stall, redundancyOk==false alone doesn't say which LAN died.
# The deployments declare no readiness probe, so `oc rollout status` reports
# Ready as soon as the container starts - well before Quarkus has bound 8080.
# Poll the API itself before trusting it.
wait_for_endpoint() {
  local ip="$1" name="$2" deadline=$((SECONDS + 120))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if curl -sf --max-time 3 "http://$ip:8080/api/stats" >/dev/null 2>&1; then
      return 0
    fi
    sleep 3
  done
  record FAIL "prp-bench:endpoint-$name" "API on $ip:8080 did not respond within 120s"
  return 1
}

degraded_count() {
  jq -s --arg if "$1" --argjson lo "$2" --argjson hi "$3" \
    '[.[] | select(.t >= $lo and .t <= $hi)
          | select(.ok == false and .lans[$if].r == 0)] | length' \
    "$SAMPLES" 2>/dev/null || echo 0
}

recovered_count() {
  jq -s --argjson lo "$1" --argjson hi "$2" --argjson floor "$FLOOR" \
    '[.[] | select(.t >= $lo and .t <= $hi)
          | select(.ok == true and ([.lans[].r] | min) > $floor)] | length' \
    "$SAMPLES" 2>/dev/null || echo 0
}

echo "== PRP UDP benchmark under dual link cuts =="
echo "rate=${RATE} msg/s payload=${PAYLOAD}B duration=${DURATION}s floor=${FLOOR} pkt/s"
echo "cut1 ${PRP_LAN_A_NETWORK} at t+${CUT1_AT}s, cut2 ${PRP_LAN_B_NETWORK} at t+${CUT2_AT}s, each ${CUT_LEN}s"
echo

# --- Preflight: timeline must not overlap ----------------------------------
# Each cut needs its degrade window, then its recovery window, to finish
# before the next event. Overlapping windows would attribute one cut's
# samples to the other and silently invert the result.
CUT1_DONE=$((CUT1_AT + CUT_LEN + SETTLE + RECOVER_WINDOW))
CUT2_DONE=$((CUT2_AT + CUT_LEN + SETTLE + RECOVER_WINDOW))
if [ "$BASELINE_AT" -ge "$CUT1_AT" ] || [ "$CUT1_DONE" -gt "$CUT2_AT" ] || [ "$CUT2_DONE" -gt "$DURATION" ]; then
  record FAIL "prp-bench:timeline" "overlapping windows: baseline ${BASELINE_AT}, cut1 done ${CUT1_DONE}, cut2 at ${CUT2_AT} done ${CUT2_DONE}, duration ${DURATION}"
  echo; echo "== Summary: $PASS passed, $FAIL failed =="
  exit 1
fi

# --- Preflight: resolve vNICs and map them to guest interfaces -------------
MAC_A=$(mac_of "$NODE_A_NAME" "$PRP_LAN_A_NETWORK")
MAC_B=$(mac_of "$NODE_A_NAME" "$PRP_LAN_B_NETWORK")
MAC_MGMT=$(mac_of "$NODE_A_NAME" "$MGMT_NETWORK")

if [ -z "$MAC_A" ] || [ -z "$MAC_B" ]; then
  record FAIL "prp-bench:preflight" "could not resolve PRP vNIC MACs on $NODE_A_NAME via virsh domiflist"
  echo; echo "== Summary: $PASS passed, $FAIL failed =="
  exit 1
fi
if [ "$MAC_A" = "$MAC_B" ] || [ "$MAC_A" = "$MAC_MGMT" ] || [ "$MAC_B" = "$MAC_MGMT" ]; then
  record FAIL "prp-bench:preflight" "PRP vNIC MAC collides with another network - refusing to cut"
  echo; echo "== Summary: $PASS passed, $FAIL failed =="
  exit 1
fi

ALL_LINKS=("$NODE_A_NAME $MAC_A" "$NODE_A_NAME $MAC_B")

# Restore unconditionally: a previously crashed run may have left one down.
for link in "${ALL_LINKS[@]}"; do
  # shellcheck disable=SC2086
  virsh domif-setlink $link up >/dev/null 2>&1
done
trap cleanup EXIT INT TERM

# A trap does not survive SIGKILL or a CI job cancel, so arm a detached
# watchdog that outlives this process. It no-ops if we finished cleanly.
WATCHDOG_CMD=""
for link in "${ALL_LINKS[@]}"; do
  WATCHDOG_CMD+="virsh domif-setlink $link up >/dev/null 2>&1; "
done
setsid bash -c "echo \$\$ > '$WD_PIDFILE'; sleep $WATCHDOG_TIMEOUT; if [ ! -f '$DONE_FLAG' ]; then $WATCHDOG_CMD fi; rm -f '$DONE_FLAG' '$WD_PIDFILE'" \
  >/dev/null 2>&1 </dev/null &

# The receiver is where we observe degradation, so we need ITS interface
# names - cutting sno-a's vNIC on a shared L2 segment silences sno-b's
# receive on that same LAN.
IF_A=$(ifname_of "$NODE_B_IP" "$(mac_of "$NODE_B_NAME" "$PRP_LAN_A_NETWORK")")
IF_B=$(ifname_of "$NODE_B_IP" "$(mac_of "$NODE_B_NAME" "$PRP_LAN_B_NETWORK")")

if [ -z "$IF_A" ] || [ -z "$IF_B" ]; then
  record FAIL "prp-bench:preflight" "could not map PRP vNIC MACs to guest interfaces on $NODE_B_NAME via permaddr"
  echo; echo "== Summary: $PASS passed, $FAIL failed =="
  exit 1
fi
record PASS "prp-bench:preflight" "${PRP_LAN_A_NETWORK}=${IF_A} ${PRP_LAN_B_NETWORK}=${IF_B} on $NODE_B_NAME"

# --- Deploy (idempotent) ---------------------------------------------------
# k8s/base creates BOTH deployments and fixes the role via a hardcoded
# PRP_BENCH_BIND_ADDRESS, so applying it to both clusters puts a receiver on
# sno-a bound to 10.10.10.2 - an address that does not exist there, so it
# crash-loops forever and pollutes later cluster-health phases. Apply
# selectively instead.
#
# `apply` is a no-op only when the live object already matches the manifest;
# if it has drifted, this recreates the pod (strategy is Recreate, so there
# is a gap with no pod at all) and re-pulls the image. That is tolerable, but
# it is why wait_for_endpoint below polls the API rather than trusting
# `oc rollout status` - the deployments declare no readiness probe.
deploy_ok=1
if [ -d "$PRP_BENCH_REPO/k8s/base" ]; then
  for spec in "$KUBECONFIG_A:sender" "$KUBECONFIG_B:receiver"; do
    kc="${spec%%:*}"; role="${spec#*:}"
    KUBECONFIG="$kc" oc apply \
      -f "$PRP_BENCH_REPO/k8s/base/namespace.yaml" \
      -f "$PRP_BENCH_REPO/k8s/base/${role}-deployment.yaml" >/dev/null 2>&1 || deploy_ok=0
    KUBECONFIG="$kc" oc adm policy add-scc-to-user hostnetwork \
      -z default -n prp-bench >/dev/null 2>&1
  done
  [ "$deploy_ok" -eq 1 ] \
    && record PASS "prp-bench:deploy" "manifests applied from $PRP_BENCH_REPO" \
    || record FAIL "prp-bench:deploy" "oc apply failed"
else
  # "Use the already-deployed app" is only a valid fallback if there IS one.
  # The matrix wipes and reinstalls both clusters, so after a wipe there is
  # not, and assuming otherwise turns a missing checkout into four unrelated
  # failures ("not ready within 300s" that actually returned NotFound in
  # under a second) plus four minutes of endpoint polling. Check and abort.
  missing=""
  for spec in "$KUBECONFIG_A:sender" "$KUBECONFIG_B:receiver"; do
    kc="${spec%%:*}"; role="${spec#*:}"
    KUBECONFIG="$kc" oc get "deploy/prp-${role}" -n prp-bench >/dev/null 2>&1 \
      || missing="${missing} prp-${role}"
  done
  if [ -n "$missing" ]; then
    record FAIL "prp-bench:deploy" "no manifests at $PRP_BENCH_REPO and not already deployed:${missing} - set PRP_BENCH_REPO to a quarkus-prp-bench checkout"
    echo; echo "== Summary: $PASS passed, $FAIL failed =="
    exit 1
  fi
  record PASS "prp-bench:deploy" "repo not present at $PRP_BENCH_REPO, using already-deployed app"
fi

# Wait for rollout, distinguishing an image-pull problem from a real failure
# so an upstream quay.io blip is never read as a PRP regression.
for spec in "$KUBECONFIG_A:sender:$NODE_A_NAME" "$KUBECONFIG_B:receiver:$NODE_B_NAME"; do
  kc="${spec%%:*}"; rest="${spec#*:}"; role="${rest%%:*}"; vm="${rest#*:}"
  if KUBECONFIG="$kc" oc rollout status "deploy/prp-${role}" -n prp-bench --timeout=300s >/dev/null 2>&1; then
    node=$(KUBECONFIG="$kc" oc get pod -n prp-bench -l "role=${role}" \
      -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null)
    case "$node" in
      *"$vm"*) record PASS "prp-bench:ready-${role}" "running on $node" ;;
      *)       record FAIL "prp-bench:ready-${role}" "pod on unexpected node: ${node:-none}" ;;
    esac
  else
    if KUBECONFIG="$kc" oc get pods -n prp-bench -l "role=${role}" \
         -o jsonpath='{.items[*].status.containerStatuses[*].state.waiting.reason}' 2>/dev/null \
         | grep -q 'ImagePull\|ErrImage'; then
      record FAIL "prp-bench:image-pull" "cannot pull benchmark image for ${role}, not a PRP fault"
    else
      record FAIL "prp-bench:ready-${role}" "deployment did not become ready within 300s"
    fi
  fi
done

wait_for_endpoint "$NODE_A_IP" sender
wait_for_endpoint "$NODE_B_IP" receiver

if [ "$FAIL" -gt 0 ]; then
  echo; echo "== Summary: $PASS passed, $FAIL failed (aborting before run) =="
  exit 1
fi

# --- Start the run ---------------------------------------------------------
# Reset the receiver explicitly first: the sender's resetPeer() is
# fire-and-forget, so a stale receiver can report a large `received` with
# lost:0 and sail through every assertion below.
curl -sf -XPOST -H 'Content-Type: application/json' -d '{}' \
  "http://$NODE_B_IP:8080/api/stats/start" >/dev/null 2>&1

if ! curl -sf -XPOST -H 'Content-Type: application/json' \
     -d "{\"messagesPerSecond\":${RATE},\"payloadBytes\":${PAYLOAD},\"durationSeconds\":${DURATION}}" \
     "http://$NODE_A_IP:8080/api/stats/start" >/dev/null 2>&1; then
  record FAIL "prp-bench:start" "could not start the run on the sender"
  echo; echo "== Summary: $PASS passed, $FAIL failed =="
  exit 1
fi
T0=$(date +%s)
record PASS "prp-bench:start" "run started at ${RATE} msg/s for ${DURATION}s"

sampler & SAMPLER_PID=$!

RCVBUF_START=$(curl -sf --max-time 5 "http://$NODE_B_IP:8080/api/stats" 2>/dev/null \
  | jq -r '.host.udpRcvbufErrors // 0')

# --- Baseline --------------------------------------------------------------
wait_until "$BASELINE_AT"
base=$(curl -sf --max-time 5 "http://$NODE_B_IP:8080/api/stats" 2>/dev/null)
lan_n=$(printf '%s' "$base" | jq -r '.host.lans | length')
lan_min=$(printf '%s' "$base" | jq -r '[.host.lans[].rxPerSec] | min')
# Rate is a sender-side setting; the receiver only ever reports its own env
# default (50000) and never learns what the sender was told to send.
cfg_rate=$(curl -sf --max-time 5 "http://$NODE_A_IP:8080/api/stats" 2>/dev/null \
  | jq -r '.config.messagesPerSecond')

if [ "$lan_n" = "2" ] && [ "${lan_min:-0}" -gt "$FLOOR" ] 2>/dev/null; then
  record PASS "prp-bench:baseline-traffic" "both LANs carrying >${FLOOR} pkt/s (min ${lan_min})"
else
  record FAIL "prp-bench:baseline-traffic" "expected 2 LANs above ${FLOOR} pkt/s, got ${lan_n} LANs min ${lan_min:-0} - every redundancy check below is meaningless without this"
fi

[ "$cfg_rate" = "$RATE" ] \
  && record PASS "prp-bench:config-echo" "sender reports ${cfg_rate} msg/s" \
  || record FAIL "prp-bench:config-echo" "sender reports ${cfg_rate} msg/s, expected ${RATE} - stale pod?"

# --- Cut 1: LAN A ----------------------------------------------------------
wait_until "$CUT1_AT"
echo "t+${CUT1_AT}s: cutting ${PRP_LAN_A_NETWORK} on ${NODE_A_NAME}"
virsh domif-setlink "$NODE_A_NAME" "$MAC_A" down >/dev/null 2>&1

wait_until "$((CUT1_AT + CUT_LEN))"
virsh domif-setlink "$NODE_A_NAME" "$MAC_A" up >/dev/null 2>&1
echo "t+$((CUT1_AT + CUT_LEN))s: restored ${PRP_LAN_A_NETWORK}"

n=$(degraded_count "$IF_A" "$((CUT1_AT + SETTLE))" "$((CUT1_AT + CUT_LEN))")
[ "${n:-0}" -ge "$MIN_DEGRADED_SAMPLES" ] \
  && record PASS "prp-bench:cut1-degraded" "${IF_A} silent and redundancy lost in ${n} samples" \
  || record FAIL "prp-bench:cut1-degraded" "only ${n:-0} degraded samples, need ${MIN_DEGRADED_SAMPLES} - the cut may never have taken effect"

wait_until "$((CUT1_AT + CUT_LEN + SETTLE + RECOVER_WINDOW))"
n=$(recovered_count "$((CUT1_AT + CUT_LEN + SETTLE))" "$((CUT1_AT + CUT_LEN + SETTLE + RECOVER_WINDOW))")
[ "${n:-0}" -ge "$MIN_DEGRADED_SAMPLES" ] \
  && record PASS "prp-bench:cut1-recovered" "both LANs back above ${FLOOR} pkt/s in ${n} samples" \
  || record FAIL "prp-bench:cut1-recovered" "only ${n:-0} healthy samples after restore"

# --- Cut 2: LAN B ----------------------------------------------------------
wait_until "$CUT2_AT"
echo "t+${CUT2_AT}s: cutting ${PRP_LAN_B_NETWORK} on ${NODE_A_NAME}"
virsh domif-setlink "$NODE_A_NAME" "$MAC_B" down >/dev/null 2>&1

wait_until "$((CUT2_AT + CUT_LEN))"
virsh domif-setlink "$NODE_A_NAME" "$MAC_B" up >/dev/null 2>&1
echo "t+$((CUT2_AT + CUT_LEN))s: restored ${PRP_LAN_B_NETWORK}"

n=$(degraded_count "$IF_B" "$((CUT2_AT + SETTLE))" "$((CUT2_AT + CUT_LEN))")
[ "${n:-0}" -ge "$MIN_DEGRADED_SAMPLES" ] \
  && record PASS "prp-bench:cut2-degraded" "${IF_B} silent and redundancy lost in ${n} samples" \
  || record FAIL "prp-bench:cut2-degraded" "only ${n:-0} degraded samples, need ${MIN_DEGRADED_SAMPLES} - the cut may never have taken effect"

wait_until "$((CUT2_AT + CUT_LEN + SETTLE + RECOVER_WINDOW))"
n=$(recovered_count "$((CUT2_AT + CUT_LEN + SETTLE))" "$((CUT2_AT + CUT_LEN + SETTLE + RECOVER_WINDOW))")
[ "${n:-0}" -ge "$MIN_DEGRADED_SAMPLES" ] \
  && record PASS "prp-bench:cut2-recovered" "both LANs back above ${FLOOR} pkt/s in ${n} samples" \
  || record FAIL "prp-bench:cut2-recovered" "only ${n:-0} healthy samples after restore"

# --- Final read ------------------------------------------------------------
wait_until "$((DURATION + 2))"
kill "$SAMPLER_PID" 2>/dev/null; SAMPLER_PID=""

rx=$(curl -sf --max-time 5 "http://$NODE_B_IP:8080/api/stats" 2>/dev/null)
tx=$(curl -sf --max-time 5 "http://$NODE_A_IP:8080/api/stats" 2>/dev/null)
curl -sf -XPOST --max-time 5 "http://$NODE_A_IP:8080/api/stats/stop" >/dev/null 2>&1
curl -sf -XPOST --max-time 5 "http://$NODE_B_IP:8080/api/stats/stop" >/dev/null 2>&1

received=$(printf '%s' "$rx" | jq -r '.received // 0')
lost=$(printf '%s' "$rx" | jq -r '.lost // -1')
loss_pct=$(printf '%s' "$rx" | jq -r '.lossPercent // -1')
rcvbuf_end=$(printf '%s' "$rx" | jq -r '.host.udpRcvbufErrors // 0')
sent=$(printf '%s' "$tx" | jq -r '.sent // 0')

# `lost` is gap-anchored to the first sequence number seen, so it structurally
# cannot see packets missing at the very start or the very end of the run.
# The sent/received delta can, which is why both are checked.
#
# The delta tolerance absorbs an unavoidable startup race: the sender's
# /api/stats/start also fires resetPeer() at the receiver asynchronously, so
# the receiver's counter can be wiped a few tens of milliseconds AFTER the
# first packets have already landed. Measured here at ~237 packets (~47ms at
# 5000/s). A quarter-second of traffic gives comfortable margin while keeping
# the check meaningful: real loss during a 30s outage would be CUT_LEN*RATE
# packets - 150,000 at these settings, two orders of magnitude above this.
TOLERANCE=$((RATE / 4))
delta=$((sent - received))
if [ "$lost" = "0" ] && [ "$delta" -le "$TOLERANCE" ] && [ "$delta" -ge "-$TOLERANCE" ]; then
  record PASS "prp-bench:zero-loss" "sent ${sent} received ${received} no sequence gaps across 2 link cuts, startup delta ${delta} within ${TOLERANCE}"
else
  record FAIL "prp-bench:zero-loss" "sent ${sent} received ${received} lost ${lost} (${loss_pct}%) delta ${delta} exceeds tolerance ${TOLERANCE}"
fi

drops=$((rcvbuf_end - ${RCVBUF_START:-0}))
[ "$drops" -eq 0 ] \
  && record PASS "prp-bench:no-kernel-drops" "udpRcvbufErrors unchanged" \
  || record FAIL "prp-bench:no-kernel-drops" "${drops} kernel receive-buffer drops during the run"

# Reported, not gated: on a shared KVM host a tight latency bound is a flake
# generator, and a PRP fault would not move latency anyway - this catches
# application or host regressions only.
record PASS "prp-bench:latency" "$(printf '%s' "$tx" | jq -r \
  '"RTT p50 \(.rtt.p50)us p99 \(.rtt.p99)us p99.9 \(.rtt.p999)us"') / $(printf '%s' "$rx" | jq -r \
  '"jitter p50 \(.jitter.p50)us p99 \(.jitter.p99)us, throughput \(.throughputMbps) Mbps"')"

echo
echo "Samples: $SAMPLES"
echo "== Summary: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
