# PRP Test Case

## Objective

Confirm that `sno-a` and `sno-b` - two independent OpenShift SNO nodes -
maintain uninterrupted Layer 2 connectivity to each other via a real
Parallel Redundancy Protocol (PRP, RFC 62439-3) link, including surviving
the loss of either individual path with zero packet loss.

## Topology

Both nodes' `eth1`/`eth2` (each on its own dedicated NIC - `eth0` alone
carries br-ex/API/Ingress/egress) land on the same two isolated libvirt
networks:

| Node   | eth1 (`prp-lan-a`) | eth2 (`prp-lan-b`) | `prp0` IP    |
|--------|--------------------|--------------------|--------------|
| sno-a  | 10.10.10.0/24 segment A | segment B | 10.10.10.1/24 |
| sno-b  | segment A | segment B | 10.10.10.2/24 |

`prp0` on each node is a Linux kernel `hsr` interface (`hsr` driver,
`protocol=prp`) binding both physical ports into one logical redundant
interface: every frame `prp0` sends goes out **both** ports simultaneously;
duplicates arriving from either path are suppressed on receive.
`eth1`/`eth2` carry no IP of their own - only `prp0` does.

## Root cause: the Day-0 installer bug (confirmed on TWO OCP versions)

The agent-based installer's Day-0 NMState config (`agent-config.yaml`,
generated from `templates/agent-config.yaml.j2`) declares `prp0` correctly:

```yaml
- name: prp0
  type: hsr
  state: up
  hsr:
    port1: eth1
    port2: eth2
    multicast-spec: 0
    protocol: prp
```

This **validates successfully** at ISO-build time (`nmstatectl gc` on the
build host, nmstate 2.2.60, accepts the schema and even correctly rejects a
first, wrong attempt at the config - see below). **Update - this is not a
version-mismatch between two different translators, as originally
theorized below.** Feeding the exact same NMState input directly to the
stock `nmstatectl gc` on this same build host - no `openshift-install`
involved at all - reproduces the identical broken output. `openshift-install`
generates its Day-0 config the same way `nmstatectl gc` does, and inherits
a real gap in **that specific nmstate code path**: confirmed by reading
`nmstate`'s own source (cloned at the exact installed tag, `v2.2.60`),
`NmConnection::to_keyfile()` (`rust/src/lib/nm/nm_dbus/gen_conf/conn.rs`) -
the function that turns a built connection into a `.nmconnection` keyfile
for offline/`gen_conf` use - has an explicit branch for every other special
settings type (`bond`, `bridge`, `vlan`, `vxlan`, `sriov`, `macsec`, `vrf`,
`veth`, `vpn`, `infiniband`, ...) but none for `hsr`, and there's no
`hsr.rs` at all under `nm_dbus/gen_conf/`, unlike every type just listed.
The in-memory model itself is correct in both modes (`settings/hsr.rs`
populates `port1`/`port2`/`multicast_spec`/`prp` regardless of mode) - only
this one keyfile-writing function skips it. The D-Bus-facing equivalent
(`nm_dbus/connection/hsr.rs`, used when applying live rather than writing a
file) already handles it correctly, which is exactly why `nmcli` and the
Day-2 `kubernetes-nmstate-operator` fix below both work: neither of them
ever calls the function with the gap. Confirmed still open on nmstate's own
upstream `base` branch as of 2026-09-17 (commit `70fa58c`) - not yet fixed
anywhere, packaged or otherwise. Full trace, minimal standalone repro, and
a ready-to-file upstream issue template: kept private (not in this public
repo, since it names internal infrastructure) - ask whoever holds this
repo's context if you need it filed.

Confirmed identically on **both OCP 4.19.45 and 5.0.0-rc.2** - the
resulting on-disk connection profile has `type=hsr` but no `[hsr]` section
at all:

```
[connection]
...
type=hsr
...
[ipv4]
...
```

NetworkManager then refuses to load it, on either version:
```
NetworkManager[1857]: <warn> [...] keyfile: load: "/etc/NetworkManager/system-connections/prp0.nmconnection":
  failed to load connection: invalid connection: hsr: setting required for connection of type 'hsr'
```
Net effect at first boot: `eth1`/`eth2` come up fine (including getting
their shared operational MAC via nmstate's `mac-address` override, which
*does* survive translation), but `prp0` simply doesn't exist:
```
$ ip -d link show prp0
Device "prp0" does not exist.
```

This is a real gap in `nmstate`'s offline configuration-generation feature
itself - not something fixable by changing the YAML schema further, not a
version mismatch between two different tools, and not specific to either
OCP release tested here (both just inherit whatever `nmstate` build they
carry for Day-0 ISO generation).

### An earlier wrong attempt, and what it taught us

The first version of the NMState config gave the two PRP ports **different**
`mac-address` values (each interface's own real hardware MAC). That failed
*validation* itself:
```
NmstateError: InvalidArgument: HSR ports on interface prp0 cannot have different MAC addresses
```
This is a real protocol constraint: `prp0` is one logical LRE identity
presented out two physical ports, so both ports must share one MAC. The
fix is **not** to give the two vNICs the same hardware MAC in the libvirt
domain XML (that broke the installer's separate MAC-based udev renaming
map, which needs unique MACs per physical NIC to know which one is
`eth1` vs `eth2`) - it's to keep the hardware MACs unique, and instead set
`mac-address` in the *nmstate* config for `eth1`/`eth2` to one shared,
explicit, made-up value (`prp_mac_address` in `vars/main.yml`, distinct
between `sno-a` and `sno-b`). nmstate/NetworkManager then reprogram the
NIC's operational MAC to that shared value at bring-up time, on top of its
distinct factory MAC. This part of the pipeline **does** survive the
installer's translation and works correctly at first boot, on both OCP
versions.

## Remediation: kubernetes-nmstate-operator (Day-2)

The durable fix for this topology (PRP as a side network, node keeps
another working interface) is the `kubernetes-nmstate-operator` + a
`NodeNetworkConfigurationPolicy` (NNCP) applied after `install-complete`.

**For a topology where PRP is the node's only interface** (no other
network to reach an operator over), see
`docs/spec-test-case-3-prp-primary.md`'s "Update: workaround confirmed,
new blocker surfaced" section instead - a different, Day-0-applicable
workaround exists there (hand-correct keyfile merged directly into the
ISO's real Ignition config), validated live.
Its handler runs the **real** `nmstatectl` directly on the node via a
privileged DaemonSet pod - a completely different code path from the
installer's broken Day-0 serializer - and correctly produces a keyfile
with a real `[hsr]` section. This is also exactly the mechanism Red Hat's
own KB on configuring HSR/PRP with nmstate calls out: it says this
approach "aligns with the approach used by the OpenShift/MicroShift
Kubernetes NMState Operator" - see "Alignment with Red Hat's KB" below
for the full comparison.

### Extra wrinkle on 5.0.0-rc.2: the operator isn't in the default catalog yet

```
$ oc get packagemanifest -n openshift-marketplace | grep -i nmstate
(no output)
```
Checked across all three default catalogs (`redhat-operators`,
`certified-operators`, `community-operators`) - all three healthy, 85-261
packages each, `kubernetes-nmstate-operator` in none of them. Confirmed via
the subscription's own condition, not just an empty grep:
```
$ oc get subscription kubernetes-nmstate-operator -n openshift-nmstate -o jsonpath='{.status.conditions}'
[{"reason":"ConstraintsNotSatisfiable","status":"True","type":"ResolutionFailed",
  "message":"constraints not satisfiable: no operators found in package kubernetes-nmstate-operator
             in the catalog referenced by subscription kubernetes-nmstate-operator, ..."},
 {"reason":"AllCatalogSourcesHealthy","status":"False","type":"CatalogSourcesUnhealthy"}]
```
This is almost certainly a pre-GA catalog gap (OCP 5.0 jumped to Kubernetes
v1.36; not every operator has been rebuilt/certified against it yet this
early in the RC cycle), not a permanent removal.

**Workaround** (`day2-manifests/00-nmstate-catalogsource.yaml`): point a
second `CatalogSource` at the last 4.x index, `v4.22` -
`registry.redhat.io/redhat/redhat-operator-index:v4.22` - which still
carries the operator, and OLM on 5.0 resolves/installs it from there
without complaint:
```
$ oc get packagemanifest -n openshift-marketplace -o json | \
    python3 -c "... filter catalogSource==redhat-operators-4-22 ..."
total packages from 4.22 index: 151      # includes kubernetes-nmstate-operator
```
```
$ oc get csv -n openshift-nmstate
NAME                                              VERSION               PHASE
kubernetes-nmstate-operator.4.22.0-202609090959   4.22.0-202609090959   Succeeded
```
**A quirk while waiting**: the catalog pod's gRPC server needs a few
restart cycles (3, here) before its `startupProbe` stops killing it -
building the query cache from a fresh 1.5GB index the first time takes
longer than the probe's patience, but the cache persists in the pod's
`/tmp` across restarts and eventually wins:
```
Warning  Unhealthy  kubelet  Startup probe failed: timeout: failed to connect
                              service "10.128.0.115:50051" within 5s: context deadline exceeded
...
$ oc get pods -n openshift-marketplace -l olm.catalogSource=redhat-operators-4-22
NAME                          READY   STATUS    RESTARTS   AGE
redhat-operators-4-22-pbt5w   1/1     Running   3          6m2s
```
Once `kubernetes-nmstate-operator` ships in OCP 5.0's own default catalog,
delete this workaround `CatalogSource` and point the `Subscription` back
at `redhat-operators`.

#### Pruned local mirror, and why tier 2 currently fails in CI

The "few restart cycles" above turned into 10-20 minute catalog-pod
startups and repeated CI timeouts, because the full `v4.22` index carries
151 operators and the `startupProbe` is not patient enough to build that
query cache. `scripts/mirror-nmstate-operator.sh` prunes the index to
`kubernetes-nmstate-operator` only and mirrors it to a local registry; the
pruned index caches in seconds, and the catalog pod went Ready in ~20s.

That worked until the repo's history was scrubbed of internal lab
hostnames, which replaced the registry host with a placeholder that does
not resolve. The host now comes from `MIRROR_REGISTRY_HOST` (a CI secret),
with the placeholder as the committed default, so no site-specific name
sits in this public repo.

**The part worth recording for anyone reproducing this:** supplying that
variable at Day-2 is not sufficient. Pointing the `CatalogSource` at a
reachable mirror still failed with `authentication required`, because a
cluster's mirror credentials, CA trust and `ImageDigestMirrorSet` are all
**Day-0** artifacts - baked in at install time from the pull secret and
extra manifests. A cluster installed against the placeholder can never use
the mirror, no matter what is applied afterwards; it has to be reinstalled
with the variable set. Until then, tier 3 (upstream) is what runs, which is
why recent CI runs show `Falling back to upstream kubernetes-nmstate`.

### Applying the fix

`scripts/apply-day2-prp.sh` does all of this against both clusters, with
waits between each step, and is what CI runs. The manual sequence below is
kept because it is what the script automates, not as a separate path:

```
oc apply -f day2-manifests/00-nmstate-catalogsource.yaml   # only if not in a default catalog
oc apply -f day2-manifests/01-nmstate-operator-subscription.yaml
# wait: oc get csv -n openshift-nmstate -> Succeeded
oc apply -f day2-manifests/02-nmstate-cr.yaml
# wait: oc get pods -n openshift-nmstate -> nmstate-handler Running (1/1)
oc apply -f day2-manifests/03-nncp-sno-a.yaml   # (or -sno-b.yaml, on that cluster)
oc apply -f day2-manifests/04-hsr-module-autoload.yaml
```

The script resolves the operator in three tiers, in order, because none of
them is reliable on its own at this release:

1. **Any default catalog** - works the day the operator ships in OCP 5.0's
   own catalog, at which point tiers 2 and 3 become dead code.
2. **The pruned local mirror** (`00-nmstate-catalogsource.yaml`) - see the
   next section.
3. **Upstream `kubernetes-nmstate` from GitHub releases** (currently
   v0.87.0), applied as plain manifests with no OLM involvement.

Tier 3 is not a formality: it is what has actually been installing the
operator in CI recently, after tier 2 stopped working (below). PRP itself
is unaffected by which tier wins - the NNCP and the resulting `prp0` are
identical - but a Red Hat-supported deployment would want tier 1.
```
$ oc get nncp prp0-hsr
NAME       STATUS      REASON
prp0-hsr   Available   SuccessfullyConfigured
```

## Verification

### 1. Interface state, both nodes

```
$ ip -d link show prp0
9: prp0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1494 qdisc noqueue state UP
    link/ether 52:54:00:aa:aa:01 brd ff:ff:ff:ff:ff:ff
    hsr slave1 enp6s0 slave2 enp7s0 sequence 1800 supervision 01:15:4e:00:01:00 proto 1
```
`proto 1` = PRP mode confirmed (not HSR/`proto 0`). Note: the kernel
interface names ended up `enp6s0`/`enp7s0` on this 3-NIC layout - always
confirm with `ip -br link` before writing the NNCP, predictable naming
depends on PCI slot allocation.

### 2. Cross-node reachability

```
$ ssh core@192.168.130.101 -- ping -c3 -W2 10.10.10.2
64 bytes from 10.10.10.2: icmp_seq=1 ttl=64 time=0.933 ms
64 bytes from 10.10.10.2: icmp_seq=2 ttl=64 time=0.534 ms
64 bytes from 10.10.10.2: icmp_seq=3 ttl=64 time=0.594 ms
--- 10.10.10.2 ping statistics ---
3 packets transmitted, 3 received, 0% packet loss
```

### 3. Failover test: kill one path mid-traffic, confirm zero loss

Tested at the hypervisor level (an administrative link-down on the libvirt
vNIC, not a guest-side toggle - closer to an unplugged cable than a
software reconfiguration):

```bash
virsh domiflist sno-a | grep prp-lan-a
#  vnet33   network   prp-lan-a   virtio   52:54:00:d8:47:f0

ssh core@192.168.130.101 'ping -i 0.2 -w 20 10.10.10.2' > /tmp/prp_failover.log 2>&1 &
sleep 3
virsh domif-setlink sno-a 52:54:00:d8:47:f0 down    # cut prp-lan-a
sleep 8
virsh domif-setlink sno-a 52:54:00:d8:47:f0 up      # restore it
wait
```

**Result, on the OCP 5.0.0-rc.2 / 3-NIC / operator-managed setup**,
`prp-lan-a` down for 8 of the 20 seconds of continuous traffic:
```
--- 10.10.10.2 ping statistics ---
97 packets transmitted, 97 received, 0% packet loss, time 19923ms
rtt min/avg/max/mdev = 0.439/0.560/0.800/0.063 ms
```
**Zero packet loss, no latency spike, across the entire outage window** -
identical to the result on the earlier OCP 4.19.45 / 4-NIC / manual-nmcli
setup. `prp0` kept sending/receiving over the surviving path
(`prp-lan-b`) for the whole 8-second outage.

### 4. Both paths actually carry traffic (not just one active link)

Packet counters on the two slave ports should be **identical** - PRP
duplicates every frame onto both paths, it doesn't merely fail over. (From
the 4.19 run, same mechanism, same result on 5.0):
```
enp7s0 (prp-lan-a)   RX  3392B / 48pkt      TX  6660B / 82pkt
enp8s0 (prp-lan-b)   RX  3392B / 48pkt      TX  6660B / 82pkt   <- identical
```

### 5. Kernel-level PRP node table shows the peer

Not just IP-level reachability - the HSR/PRP driver's own peer table,
populated from real supervision frames:
```
$ ssh core@192.168.130.101 -- sudo cat /sys/kernel/debug/hsr/prp0/node_table
Node Table entries for (PRP) device
MAC-Address-A,    MAC-Address-B,    time_in[A], time_in[B], Address-B port, SAN-A, SAN-B, DAN-P
52:54:00:aa:aa:02 00:00:00:00:00:00  100d23deb,  100d23deb,              0,     0,     0,     1
```
`DAN-P: 1` = sno-a has registered sno-b as a Dual Attached Node - PRP at
the protocol level. Symmetric on sno-b (registers sno-a's MAC the same
way). `scripts/test-prp-failover.sh` asserts this table is non-empty on
both nodes.

### 6. Under real load: 1.5M packets across two link cuts

Checks 1-5 prove PRP with `ping` - roughly one packet per second. That is
enough to show the mechanism works and nothing like enough to show it
holds up under traffic. `scripts/test-prp-bench.sh` drives the
[prp-bench](https://github.com/arthur-r-oliveira/quarkus-prp-bench) UDP
sender/receiver across `prp0` for 300 seconds and cuts `prp-lan-a`, then
`prp-lan-b`, for 30 seconds each while traffic flows.

**The load is not the point; what it asserts is.** PRP masks a dead LAN so
completely that loss stays zero and no application metric moves, so a test
that cuts a link and checks only for 0% loss passes identically whether the
cut happened or silently failed. That was verified, not assumed: with
`virsh domif-setlink` stubbed to a no-op, the zero-loss check still passed
at 449,930/450,000. The suite therefore also asserts that each cut
*actually degraded redundancy* - the named interface's `rxPerSec` dropping
to 0 while its partner carries the full rate - and that both recovered.
Those four assertions are what give the zero-loss number meaning.

Representative results, all on OCP 5.0.0-rc.2, dual-sidecar-prp:

| Rate | Sent / received | Loss | Redundancy assertions | RTT p50 / p99 | Verdict |
|---|---|---|---|---|---|
| 1500 msg/s | 450,000 / 449,996 | no sequence gaps (delta 4, startup race) | 4/4 pass | 819 us / 2.20 ms | **14/14 pass** |
| 5000 msg/s | 1,500,017 / 1,499,421 | no sequence gaps (delta 596) | 4/4 pass | 434 us / 2.22 ms | **14/14 pass** |
| 5000 msg/s | 1,500,028 / 1,493,661 | 6,012 lost (0.4%) | 4/4 pass | 467 us / 2.48 ms | 12/14 - see below |

The `sent`/`received` delta is checked separately from the sequence-gap
count because each is blind to something the other catches: `lost` is
gap-anchored to the first sequence number the receiver sees, so it cannot
see packets missing at the very start or end of a run, while the delta can
but cannot say where they went. The tolerance (`RATE / 4`, a quarter-second
of traffic) absorbs a real startup race - the sender's `/api/stats/start`
resets the receiver's counter asynchronously, so the first few packets can
land before the counter is listening. Real loss during a 30-second outage
would be `CUT_LEN * RATE` packets, two orders of magnitude above that
tolerance, so a missed cut cannot hide inside it.

#### The 5000 msg/s loss is receiver-side, not PRP

One run at 5000 msg/s failed `zero-loss` and `no-kernel-drops` together:
6,012 packets lost alongside **1,020 `udpRcvbufErrors`**. Those two numbers
are the same event. `udpRcvbufErrors` is the kernel discarding datagrams
because the receive buffer was full - the packets crossed the PRP link and
were dropped after arrival, by the receiving host, not lost on the wire.

Three things corroborate that reading:

- All four redundancy assertions passed in that same run. Both cuts
  degraded and recovered correctly, so the link behaved exactly as in the
  passing runs.
- The hypervisor was not contended: load average 7.86 across 72 CPUs, with
  no concurrent CI job.
- The same code, same clusters, ~20 minutes apart, passed cleanly at 1500
  msg/s and in an earlier 5000 msg/s run.

So this is a property of the benchmark application's socket buffer
(`SO_RCVBUF` / `net.core.rmem_max` in the receiver pod), not a PRP or
OpenShift defect. It is recorded here rather than tuned away because it
sets an honest ceiling on what these runs demonstrate: **PRP redundancy is
proven to ~1.5M packets with zero wire loss, and the harness itself becomes
the bottleneck somewhere around 5000 msg/s on this hardware.** A single
green 5000 msg/s run is weaker evidence than it looks; 1500 msg/s is
currently the rate that reproduces reliably.

### Pass criteria summary

| Check | Expected | 5.0.0-rc.2 result |
|---|---|---|
| `ip -d link show prp0` | exists, `proto 1` | Pass |
| Cross-node ping | succeeds, sub-ms after warm-up | Pass |
| Slave port counters | identical on both ports | Pass |
| Single-path failure, mid-traffic | **0% packet loss** for the duration | Pass - 97/97 |
| Link restore | both ports return to `UP`/`LOWER_UP`, `prp0` still `proto 1` | Pass |
| `/sys/kernel/debug/hsr/prp0/node_table` | peer MAC registered, `DAN-P: 1` | Pass |
| 300s UDP benchmark, two 30s cuts | no sequence gaps; both cuts degrade and recover | Pass - 14/14 at 1500 msg/s |

All six original checks passed on both `sno-a` and `sno-b`, on both OCP
versions tested. The benchmark (check 6) is newer and runs only on the
5.0.0-rc.2 dual-sidecar-prp topology; see the rate caveat above.

## Alignment with Red Hat's KB on configuring HSR/PRP with nmstate

Red Hat publishes an official KB, "How to configure HSR/PRP interfaces
using nmstate in Red Hat Enterprise Linux" (RHEL 9.8+/10.2+ GA), that this
work was checked against directly - including by testing its specific
recommendations live against `sno-a`/`sno-b`, not just reading it.

| KB says | This repo | Aligned? |
|---|---|---|
| nmstate is the recommended tool; explicitly "aligns with the approach used by the OpenShift/MicroShift Kubernetes NMState Operator" | Uses exactly that operator + NNCP for the Day-2 fix | **Yes** - this is the strongest validation: Red Hat names our approach as the recommended one |
| `port1`/`port2`/`multicast-spec`/`protocol: prp` schema | Identical fields, identical structure | **Yes** |
| GA in RHEL 9.8+ / RHEL 10.2+, no Tech Preview taint | RHCOS base confirmed as `VERSION_ID="10.2"`, `dmesg \| grep -i hsr` shows no taint/Tech-Preview warning | **Yes, confirmed live** |
| `copy-mac-from: <port1>` on the hsr interface (replaces manually hardcoding a shared MAC on both ports) | Adopted in `day2-manifests/03-nncp-sno-*.yaml` after testing it live - see below | **Yes, adopted** |
| Load `hsr` via `modprobe`, persist via `/etc/modules-load.d/` (KB 230963) | Was relying on the kernel's on-demand `rtnl-link-hsr` alias alone (verified working, including across a reboot) - now **also** ships `day2-manifests/04-hsr-module-autoload.yaml` for explicit alignment | **Yes, now added** |
| Verify via `nmstatectl show`, `ip -s -s link`, and `/sys/kernel/debug/hsr/<if>/node_table` | Added the `node_table` check (§5 above and in the test script); already had the `ip`-based checks | **Yes** |
| Failover test: bring one port down, confirm ~0% loss, restore | Same idea, done at the hypervisor level (`virsh domif-setlink`) rather than guest-level `ip link set down` - a stronger test (closer to an unplugged cable) | **Yes, and more rigorous** |

### `copy-mac-from`: tested live, adopted, with an honest caveat

The KB frames `copy-mac-from` as the modern replacement for manually
setting an identical `mac-address` on both ports (which is what this repo
did on OCP 4.19.45/5.0.0-rc.2's Day-0 config, before this KB was checked
against). Tested directly against our nmstate 2.2.60 handler:
```yaml
- name: prp0
  type: hsr
  state: up
  copy-mac-from: enp6s0
  hsr:
    port1: enp6s0
    port2: enp7s0
    multicast-spec: 0
    protocol: prp
```
Result: accepted, applied cleanly, and gives `prp0` itself an explicit
matching MAC (not just the two ports) - confirmed in the resulting keyfile:
```
$ cat /etc/NetworkManager/system-connections/prp0-<uuid>.nmconnection
[ethernet]
cloned-mac-address=52:54:00:AA:AA:01
[hsr]
port1=enp6s0
port2=enp7s0
prp=true
```
```
$ ip -br link show enp6s0; ip -br link show enp7s0; ip -br link show prp0
enp6s0   UP   52:54:00:aa:aa:01   ...
enp7s0   UP   52:54:00:aa:aa:01   ...
prp0     UP   52:54:00:aa:aa:01   ...
```
PRP kept working throughout (`proto 1`, cross-node ping 0% loss, both
NNCPs `Available`). **Caveat, straight from the KB's own internal notes**:
Red Hat's authors flag open issues with `copy-mac-from` alone in some
configurations (tracked as RHEL-75817, RHEL-85769, RHEL-40917, and
nmstate/nmstate#2302), with a possible fallback of setting `mac-address`
explicitly on all three interfaces (`port1`, `port2`, **and** the hsr
interface itself) if it regresses. If `prp0` ever comes up with a MAC that
doesn't match its ports after a nmstate/NetworkManager update, that's the
first thing to check - and reverting to explicit `mac-address` values (as
this repo did before adopting `copy-mac-from`) is the documented fallback,
not a dead end.

### Where this differs, and why that's fine

- **Guest-level vs. hypervisor-level failover test.** The KB's example
  (`ip link set down dev enp7s0`) tests NetworkManager/kernel behavior
  from inside the guest. This repo's `virsh domif-setlink ... down` cuts
  the link from outside the guest entirely - strictly a superset of what
  the KB's test proves, not a substitute that's weaker in some way.
- **`multicast-spec: 0` vs. the KB's example value of `40`.** Arbitrary in
  both cases; it only has to match across every node in the same PRP
  group, which it does here (`sno-a` and `sno-b` both use `0`).
- **This repo's context is OpenShift's agent-based installer's Day-0
  pipeline**, which the KB doesn't cover at all (it's written for direct
  RHEL/nmstate usage via `nmstatectl apply` against a policy file under
  `/etc/nmstate/`). The Day-0 serializer bug documented above is specific
  to that installer pipeline, not something the KB would have caught or
  needs to address - but the underlying nmstate schema it confirms
  (`port1`/`port2`/`protocol`/`copy-mac-from`) is exactly what both paths
  ultimately rely on.

## Testing & Validation

### Automated

```bash
./scripts/test-prp-failover.sh   # checks 1-5: health, prp0 mode, reachability,
                                 # one hypervisor-level cut, node_table
./scripts/test-prp-bench.sh      # check 6: 300s UDP benchmark, two 30s cuts
```

Exit 0 = all passed. All defaults match `vars/main.yml`; override via env
vars if needed (`NODE_A_IP`, `KUBECONFIG_A`, `RATE`, `DURATION`, ...).

`test-prp-bench.sh` needs the benchmark repo checked out and pointed at by
`PRP_BENCH_REPO` (it defaults to `../quarkus-prp-bench`, a sibling of this
one) so it can apply the manifests itself. If the repo is absent **and** the
app is not already deployed, it aborts immediately rather than reporting a
cascade of unrelated readiness failures. It also needs `jq` on the KVM host,
and is safe to interrupt: a detached watchdog restores both links even on
`SIGKILL`, where a shell trap cannot run.

In CI these are three separate workflows, so each reports as its own suite:

| Workflow | Trigger | What it runs |
|---|---|---|
| `sno-test-matrix.yml` | manual | wipe → Test Case 1 → wipe → Test Case 2 → Day-2 PRP → failover suite |
| `prp-test.yml` | daily + manual | failover suite against whatever is running |
| `prp-bench.yml` | after the matrix, + manual | the UDP benchmark (rate/duration/payload are inputs) |

Historical pass rates per test and per run:
**https://arthur-r-oliveira.github.io/ocp-abi-local-sno/**

### Manual sanity checks

#### 1. Cluster health

```bash
KUBECONFIG=/home/libvirt-images/sno-install/sno-a/auth/kubeconfig oc get clusterversion
KUBECONFIG=/home/libvirt-images/sno-install/sno-a/auth/kubeconfig oc get co | awk '$3!="True" || $4!="False" || $5!="False"'
```

Repeat with sno-b's kubeconfig. Expect: `Available=True`, no unhealthy operators.

#### 2. prp0 interface and protocol mode

```bash
ssh core@192.168.130.101 "ip -d link show prp0"
ssh core@192.168.130.102 "ip -d link show prp0"
```

Expect: `proto 1` (PRP). If `proto 0`, the interface fell back to HSR mode.

#### 3. Cross-node reachability over prp0

```bash
ssh core@192.168.130.101 "ping -c5 -W2 10.10.10.2"
```

Expect: 0% packet loss.

#### 4. Failover (hypervisor-level link cut)

This tests that cutting one PRP path causes zero packet loss — the defining property of PRP.

```bash
# Find sno-a's MAC on prp-lan-a
virsh domiflist sno-a
# Note the MAC address for the prp-lan-a network

# Start continuous ping from sno-a to sno-b over prp0
ssh core@192.168.130.101 "ping -i 0.2 -w 20 10.10.10.2" &

# After ~3 seconds, cut the link
virsh domif-setlink sno-a <MAC> down

# After ~8 seconds, restore it
virsh domif-setlink sno-a <MAC> up

# Wait for ping to finish — check output
```

Expect: 0% packet loss despite the link being down for ~8 seconds.

#### 5. PRP node table (kernel-level peer registration)

```bash
ssh core@192.168.130.101 "sudo cat /sys/kernel/debug/hsr/prp0/node_table"
ssh core@192.168.130.102 "sudo cat /sys/kernel/debug/hsr/prp0/node_table"
```

Expect: at least one entry showing the peer's MAC address. An empty table means PRP is configured but the nodes haven't seen each other at the protocol level.
