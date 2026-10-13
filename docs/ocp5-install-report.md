# OCP 5 Install Report

**Day-2 works out of the box. Day-0 does not.** Three agent-based-installer
SNO topologies on OpenShift 5.0.0-rc.2 - what passed in CI, what blocks
PRP as the primary network, and what we learned running three SNO VMs on
one 46GB KVM host. Standalone visual counterpart:
[ocp5-install-report.html](ocp5-install-report.html) (open
directly in a browser) - keep both in sync when either changes.

Host: internal KVM lab (RHEL 10). Dates: 2026-09-17 to 2026-10-13.
OCP: 5.0.0-rc.2 (also re-validated Day-2 PRP on 4.19.45).
CI: [test health dashboard](https://arthur-r-oliveira.github.io/prp-on-openshift/).

**Status at a glance**

| Topology | Test Case | Result |
|---|---|---|
| `single` | 1 | PASS - clean install, passing in CI |
| `dual-sidecar-prp` | 2 | PASS - Day-2 PRP OOTB, 0% ping failover, passing in CI |
| `single-primary-prp` | 3 | BLOCKED - two Day-0 defects; nmstate worked around locally, assisted inventory still blocks |
| 3 VMs concurrently | - | Host RAM oversubscribed -> CVO errors (resolved, documented) |

## 01. Three topologies, one playbook

One Ansible playbook, selected per run with `-e sno_topology=...`. Each
topology gets its own libvirt network layout, VM domain XML, and
AgentConfig template - templated from `vars/topologies/*.yml`, not
copy-pasted per node.

| Topology | Nodes | Sizing | NICs | PRP role |
|---|---|---|---|---|
| `single` | 1 | 8 vCPU / 16GB | 1 -> `ocp-public` | none - baseline sanity check |
| `dual-sidecar-prp` | 2 independent | 8 vCPU / 16GB each | 3 each -> ocp-public + prp-lan-a + prp-lan-b | sidecar link between two clusters, not in the critical path |
| `single-primary-prp` | 1 | 8 vCPU / 16GB | 2 -> prp-lan-a + prp-lan-b, `prp0` underlies `br-ex` | load-bearing for cluster networking, not a sidecar |

## 02. Results

### Test Case 1 - `single` - PASS

Deploy -> bootstrap-complete -> install-complete -> health check, run in
isolation, all clean.

```
PLAY RECAP **********************************************************
localhost  : ok=28  changed=10  unreachable=0  failed=0  skipped=5  rescued=0  ignored=0

INFO All cluster operators have completed progressing
INFO Install complete!

== Single SNO (no PRP) :: test suite ==
[PASS] cluster-health:sno-single - ClusterVersion Available, all operators healthy
[PASS] node-ready:sno-single - kubelet Ready
== Summary: 2 passed, 0 failed ==
```

### Test Case 2 - `dual-sidecar-prp` - PASS (Day-2 OOTB)

Both clusters healthy. PRP is applied Day-2 via
`kubernetes-nmstate-operator` + an NNCP - no workarounds, the approach
Red Hat's own HSR/PRP KB recommends. Protocol-level checks hold:
`proto 1` (PRP, not HSR), identical frame counters on both ports, peer
registered as `DAN-P` in the kernel node table. Validated on
**5.0.0-rc.2** and **4.19.45**.

A hypervisor-level link cut on one of the two redundant paths loses
**zero** packets at ping rate. Full writeup with charts:
`docs/prp-hackathon-report.html`.

```
[PASS] cluster-health:sno-a - ClusterVersion Available, all operators healthy
[PASS] cluster-health:sno-b - ClusterVersion Available, all operators healthy
[PASS] prp0-mode:sno-a - proto=1 (PRP)
[PASS] prp0-mode:sno-b - proto=1 (PRP)
[PASS] prp0-reachability - 0% loss, sno-a -> sno-b over prp0
[PASS] failover-prp-lan-a - 0% packet loss with prp-lan-a down for 8s
[PASS] prp-node-table:sno-a - 2 peer entries
[PASS] prp-node-table:sno-b - 3 peer entries
== Summary: 8 passed, 0 failed ==
```

**On zero loss under load:** CI also runs a sustained UDP load test via
[quarkus-prp-bench](https://github.com/arthur-r-oliveira/quarkus-prp-bench)
(`scripts/test-prp-bench.sh` / `prp-bench.yml`) - a Quarkus/Vert.x
sender/receiver across the PRP link with mid-run LAN cuts. The
redundancy assertions (each cut silences the named LAN while its partner
carries full rate, then both recover) are the result that speaks to PRP -
they pass every run. End-to-end zero loss at sustained high packet rates
is intermittent and still under investigation; residual losses so far
point at the test harness, not at PRP. Never present a bare load-bench
loss percentage out of context - it reads as *"PRP loses packets"*, the
opposite of the finding. Detail: `docs/prp-test-case.md` and the
[test health dashboard](https://arthur-r-oliveira.github.io/prp-on-openshift/).

### Test Case 3 - `single-primary-prp` - BLOCKED (two Day-0 defects)

Day-0 (install-time) PRP as the primary network under `br-ex` is blocked
by two independent defects. Fixing one does not unblock the other.

#### Defect 1: nmstate `gen_conf` drops the `[hsr]` section

**Not an OpenShift bug.** The Day-0 NMState config for `prp0` is
schema-valid and builds a clean ISO, but `nmstatectl gc` (offline
keyfile generation - the same path the installer uses) writes a profile
with `type=hsr` and **no `[hsr]` section**. NetworkManager refuses to
load it, so `prp0` never exists at first boot. Reproduces with stock
`nmstatectl`, no installer involved.

This is not a regression - verified, not inferred: `hsr` has never
appeared in any file under `nm_dbus/gen_conf/`, on any branch, in any
commit since HSR landed (Nov 2023). All HSR work stayed on the live
D-Bus path - which is why Day-2 (`nmstatectl set` / the operator) works.
A five-line fix is identified, following the existing `vrf.rs` pattern:
`docs/upstream-issue-1-nmstate-hsr-gen-conf.md`.

Severity is topology-dependent: as a side network the interface is
silently absent (recoverable Day-2). As the *primary* interface under
`br-ex`, the host boots with **no network at all** - no DNS, no
registry, no SSH.

Confirmed directly by adding a serial-console kernel arg plus a one-time
`rd.break` to drop into the boot's dracut shell *after* ignition writes
its files but *before* NetworkManager or the `hsr` kernel module ever
run:

```
$ cat /sysroot/etc/assisted/manifests/nmstateconfig.yaml   # source (input) - correct
    - hsr:
        multicast-spec: 0
        port1: eth0
        port2: eth1
        protocol: prp
      name: prp0
      state: up
      type: hsr

$ cat /sysroot/etc/assisted/network/host0/prp0.nmconnection   # staged keyfile (output) - broken
[connection]
type=hsr
          # no [hsr] section anywhere in the file
[ipv4]
address0=192.168.140.50/24
...
```

**There is no Day-2 workaround for this topology** - the
`kubernetes-nmstate-operator` fix that works for Test Case 2 needs a
reachable API server. A Day-0 workaround does exist and is confirmed
working: a hand-corrected `prp0.nmconnection` (nmstate's own correct
output plus the missing `[hsr]` section) is merged directly into the
ISO's Ignition config via `scripts/embed-day0-file.py`, bypassing the
broken translation entirely. Confirmed live over SSH:
```
$ ip -d link show prp0
4: prp0: <BROADCAST,MULTICAST,UP,LOWER_UP> ...
    hsr slave1 enp1s0 slave2 enp6s0 sequence ... proto 1 ...
IP4.ADDRESS[1]: 192.168.140.50/24
```
`proto 1` - real PRP, same signature already proven on Test Case 2.

One correction along the way: Day-0 "extra manifests"
(`<install_dir>/openshift/*.yaml`) do **not** apply pre-boot at all - they
stage at `/etc/assisted/extra-manifests/` for the Machine Config Operator
to pick up once a cluster exists, confirmed via a `dracut rd.break` shell.
The `hsr`-module-autoload manifest never had any effect on this topology's
original failure; the kernel's `rtnl-link-hsr` alias autoloads the module
on demand regardless, with no preload needed.

#### Defect 2: Assisted Installer inventory drops `hsr` interfaces

With `prp0` working via the Day-0 workaround, a second distinct blocker
surfaces. `assisted-installer-agent`'s inventory collector drops `hsr`
interfaces entirely - its vendored `netlink` library (`v1.2.1-beta.2`)
predates HSR kernel support - so the stored host inventory has entries
for the two physical NICs only; `prp0` is completely absent even though
the interface is live. Confirmed by querying the node's `assisted-db`
directly.

This is consistent with the `"Host does not belong to machine network
CIDRs"` validation failure that stops the install (despite the live
address matching `machineNetwork.cidr` exactly), though **that causal
link is unproven**. No workaround exists yet for this one - unlike the
nmstate bug, this gap is in what the node reports about its own live
state, not a static file this repo can hand-correct. Full trace:
`docs/spec-test-case-3-prp-primary.md` and
`docs/upstream-issue-3-assisted-installer-agent-hsr-inventory.md`.

**Outcome, as decided with the team:** still not a hard blocker on the
plan - out-of-box install for this exact topology is a *good to have*
from a production-deployment perspective, not a requirement, and worth
reporting upstream rather than silently accepted. Four paste-ready
drafts exist and are **not yet filed** (RHEL Jira for nmstate, upstream
nmstate, OCPBUGS for the installer, assisted-installer-agent inventory):
see `docs/upstream-issue-{1,2,3}-*.md`,
`docs/rhel-jira-nmstate-hsr-gen-conf.md`.

## 03. What "8vCPU/16GB x 3" actually costs on a 46GB host

Test Case 1 was deployed *alongside* the already-running `sno-a`/`sno-b`
pair rather than after wiping them - three SNO VMs at once, ~48GB of
combined requested RAM against 46GB of physical host RAM.

**Symptom: looked like a cluster bug, wasn't one.**

```
NAME      VERSION      AVAILABLE   PROGRESSING   SINCE   STATUS
version   5.0.0-rc.2   False       True          64m     Unable to apply 5.0.0-rc.2: an unknown error has occurred: MultipleErrors

$ oc get nodes
Unable to connect to the server: stream error: stream ID 1; INTERNAL_ERROR; received from peer
```

| Moment | Free RAM | Swap in use | API server |
|---|---|---|---|
| 3 VMs running concurrently | ~400-450MB | 4.8 -> 5.3GB, climbing | timing out |
| After wiping down to 2 VMs | 13GB | 633MB | normal |

Tearing down the contended VM (`sno-single`) recovered the host instantly,
and a full regression pass on `sno-a`/`sno-b` came back 8/8 clean - they
were never actually damaged, just starved. Re-running Test Case 1 in
isolation afterward passed cleanly end to end.

**Practical takeaway:**
- This host comfortably runs **two** 8vCPU/16GB SNO nodes at once. A third
  pushes it into swap and produces CVO/apiserver errors that look like a
  product bug but are host contention.
- `scripts/run-test-matrix.sh` already wipes between every phase, so the
  CI path never hits this - it only bit us here because Test Case 1 ran
  *alongside* a live demo pair instead of after wiping.
- If you need to demo two topologies simultaneously on one host, budget
  accordingly (32GB+ headroom above the two demo clusters) or use a
  second physical host.

## 04. RHEL 10 host gotchas worth knowing before you start

None of these are OCP bugs - they're EL10 packaging/permission specifics
(and a few install/test lessons) that cost real time the first time
through.

- **libvirt-daemon doesn't pull in networking or QEMU support.**
  `libvirt-daemon-driver-network` and `-qemu` are separate packages on
  EL10 - install them explicitly.
- **genisoimage doesn't exist on EL10.** Use `xorriso` instead for any
  ISO-building step.
- **qemu-kvm moved.** The binary lives at `/usr/libexec/qemu-kvm`, not
  `/usr/bin/`.
- **The unprivileged qemu user can't see into /root.** uid 107 can't
  traverse a 0700 home directory. VM storage has to live somewhere it can
  reach - this repo uses `/home/libvirt-images` with `0711` perms and the
  `virt_image_t` SELinux context.
- **ENOSPC pauses the VM, it doesn't corrupt it.** Each SNO's disk
  reliably hits 25-30GB+ during install. A full filesystem shows up as
  `paused (I/O error)` in `virsh domstate --reason` - relocate storage to
  a filesystem with headroom, fix ownership/SELinux, redefine the domain,
  resume.
- **XFS has no shrink.** Don't try to grow one LV by shrinking another
  when both are XFS - there's no shrink operation at all, only
  `xfs_growfs`. Point VM storage at whichever filesystem already has room
  instead.
- **A hard power-cycle mid-install wrecks cluster health for hours.**
  `virsh destroy` on a node that's already rolling out operators leaves
  `oc get co` stuck `Progressing=True` for a long time. Prefer `virsh
  shutdown`, or just wipe and rebuild - it's faster than nursing a
  disrupted single-node control plane back to health.
- **Installs must be staggered.** Bootstrapping both SNOs at once starves
  kube-apiserver past its deadline and fails the install. Power the second
  node off until the first finishes (~47 and ~51 min serially).
- **The zero-loss assertion alone is worthless.** PRP masks a dead LAN so
  completely that a test cutting a link and checking only for 0% loss
  passes identically whether the cut happened or silently failed. The
  degraded/recovered assertions are what make the result evidence.
- **Mirror / IDMS / pull-secret config is Day-0 only.** Credentials, CA
  trust, and ImageDigestMirrorSet are baked in at install time. A cluster
  installed against a placeholder can never use the real mirror afterward
  - it needs a full reinstall with the correct values already set.

## 05. What's automated already

Three CI workflows on a self-hosted runner labeled `kvm-prp-lab`, plus a
[test health dashboard](https://arthur-r-oliveira.github.io/prp-on-openshift/)
built from JUnit artifacts. Last figures (as of 2026-10-08): **18 runs,
176 test executions, 97.2%**.

Load under PRP failover is exercised in CI by
[quarkus-prp-bench](https://github.com/arthur-r-oliveira/quarkus-prp-bench)
(UDP benchmark tool, Quarkus + Vert.x), driven by
`scripts/test-prp-bench.sh` and the `prp-bench.yml` workflow.

| Script | Does |
|---|---|
| `wipe-all-sno.sh` | Destroys/undefines every known SNO VM, cleans install dirs and `/etc/hosts` |
| `test-single.sh` | Test Case 1 health check: ClusterVersion Available, no degraded operators, node Ready |
| `apply-day2-prp.sh` | Day-2: three-tier operator install + NNCPs for the PRP sidecar |
| `test-prp-failover.sh` | Test Case 2: health + PRP mode + reachability + a real hypervisor-level link cut + kernel node-table check |
| `test-prp-bench.sh` | Runs [quarkus-prp-bench](https://github.com/arthur-r-oliveira/quarkus-prp-bench) across PRP with mid-run LAN cuts (check 6) |
| `run-test-matrix.sh` | Orchestrates wipe → install → test end to end and writes a markdown report |

| Workflow | Trigger | Does |
|---|---|---|
| `sno-test-matrix.yml` | `workflow_dispatch` | Full wipe → Test Case 1 → wipe → Test Case 2 → Day-2 PRP → failover suite |
| `prp-test.yml` | daily | Failover check against the left-running dual-sidecar pair |
| `prp-bench.yml` | after matrix, + manual | [quarkus-prp-bench](https://github.com/arthur-r-oliveira/quarkus-prp-bench) UDP load test (rate/duration/payload are inputs); split out so it reports as its own suite |

- CI dashboard: https://arthur-r-oliveira.github.io/prp-on-openshift/
- Benchmark app: https://github.com/arthur-r-oliveira/quarkus-prp-bench

The matrix deliberately leaves `dual-sidecar-prp` running at the end -
run `./scripts/wipe-all-sno.sh` when you want the host back. The
benchmark was split out of the matrix so it can be re-run without a
3-hour wipe+reinstall.

## 06. What's not covered yet: TNF

Two-Node OpenShift with Fencing + PRP is a fourth, deliberately separate
topology - not just another `-e sno_topology=...` value. Specified but
not started; it needs its own design pass:

- **Different install flow.** Agent-based installer support for TNF
  starts at **OCP 4.22** - confirmed, supersedes an earlier read of the
  docs that only found IPI/UPI documented (that was against 4.20-era
  docs).
- **Needs a virtual BMC.** TNF's fencing credentials expect a real
  Redfish BMC per node; on a KVM lab that means `sushy-tools` backed by
  libvirt.
- **Needs an external load balancer.** Unlike SNO, a 2-node control plane
  needs something in front of it (Red Hat's own docs show a sample
  haproxy config forwarding 6443/80/443).

Deliberately out of this report and out of the current CI matrix -
tracked as its own follow-up spec.
