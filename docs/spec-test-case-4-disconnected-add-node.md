# Spec: Test Case 4 — Adding a Worker Node to a Disconnected Cluster

**Status: PLANNED. Not implemented, not run.**

Plan only. Nothing in this spec has been built or executed yet.

## Why this test case

Every topology in this repo so far installs a cluster and stops. Nothing
exercises what happens *after* day 0 — and adding a node is the step most
likely to be performed by someone who was not present at the install, months
later, with no one around who remembers how the mirror registry was wired.

It is also the step with the weakest disconnected story in the product. Red Hat
has published two solutions against `oc adm node-image create` in disconnected
environments:

- **KB 7120019** — the command fails to use the mirror registry.
- **KB 7111353** — on clusters originally installed at 4.15, added nodes never
  finish installing.

The command needs to pull a release image matching the cluster version, so it
must be handed mirror credentials explicitly, via `--registry-config` or
`REGISTRY_AUTH_FILE`. That is precisely the kind of install-time-versus-later
coupling this repo already found once, in a different guise: mirror
credentials, CA trust and the IDMS are day-0 artifacts, and a cluster installed
against a placeholder registry can never be repointed afterwards
(`docs/ocp5-install-report.md`).

**Central hypothesis, stated up front:** on a cluster this repo installs — day-0
IDMS, mirror CA in the trust bundle, mirror credentials in the pull secret —
`oc adm node-image create` will *not* transparently inherit that configuration,
and will need its registry auth supplied out of band. The interesting question
is not whether the node eventually joins, but **how much of the day-0 mirror
wiring the command silently fails to reuse.**

Both outcomes are publishable. See "Two possible outcomes" below.

---

## Requirement 1: a base cluster to extend

Use **Test Case 1 (`single`)**, not either PRP topology.

The point here is the add-node path, and running it on top of `prp0` would
confound a node-join failure with the HSR/PRP bugs already documented in
`docs/prp-test-case.md` and `docs/spec-test-case-3-prp-primary.md`. One
variable at a time. Extending PRP topologies is a follow-on, not this spec.

Base: 1 node, 1 NIC on `ocp-public`, 8 vCPU / 16 GB, as today.

## Requirement 2: a worker VM definition

A new VM joining the same `ocp-public` network.

| | |
|---|---|
| Name | `worker-01` |
| vCPU / RAM | 4 / 8192 MB (a worker does not need the control-plane profile) |
| Disk | 120 GB, same `sno_storage_base` |
| NIC | 1, `ocp-public`, fixed MAC in the same range as the SNO nodes |

Host budget: 8+4 vCPU and 24 GB against a 46 GB host. Comfortable — and
deliberately so, given `docs/finding-parallel-bootstrap-resource-contention.md`
records what happens on this host when RAM is overcommitted.

New files, following existing conventions:

- `templates/vm-definition/worker.xml.j2`
- `vars/topologies/single-plus-worker.yml` — or a `sno_worker_*` block in
  `vars/main.yml` if a full topology entry proves heavy-handed. Decide during
  implementation; prefer whichever keeps `sno_topology` meaning "what gets
  installed at day 0", since the worker is explicitly *not* a day-0 artifact.

## Requirement 3: the add-node flow itself

A new `scripts/test-add-node.sh`, emitting `[PASS]`/`[FAIL]` lines so
`to-junit-xml.sh` picks it up unchanged, like `test-single.sh` and
`test-prp-failover.sh`.

Phases:

1. **Preflight.** Cluster healthy, all operators available, mirror registry
   reachable from the KVM host.
2. **Generate.** Write `nodes-config.yaml` (hostname, MAC, static addressing to
   match the lab's layout), then run `oc adm node-image create` with
   `REGISTRY_AUTH_FILE` pointing at the mirror credentials. Record the full
   command and environment in the log — this is the detail ABB and anyone else
   following a runbook will actually need.
3. **Boot.** Define and start `worker-01` from the generated `node.x86_64.iso`.
4. **Monitor.** `oc adm node-image monitor --ip-addresses <ip>` to completion or
   timeout.
5. **Join.** Node reaches `Ready`; no CSRs left pending (the flow is supposed to
   remove the manual approval step — assert that, do not assume it).
6. **Schedule.** Run a trivial workload pinned to the new node and confirm it
   starts.

## Requirement 4: prove it stayed disconnected

The assertion that actually matters, and the one most likely to be skipped.

A node can join while quietly pulling from the internet, which would make a
green result worthless as evidence for an air-gapped site. So:

- Inspect images on the new node (`crictl images`) and assert every reference
  resolves to the mirror host, not `registry.redhat.io` or `quay.io`.
- Confirm the IDMS/ITMS reached the new node and that CRI-O's mirror config is
  present on disk.
- Ideally, block egress from the worker's network for the duration and show the
  join still completes. If the lab's `ocp-public` NAT makes that awkward,
  record it as a limitation of the result rather than quietly dropping the
  check.

## Requirement 5: CI wiring

Mirror the existing split rather than extending the matrix in place. The
benchmark already lives in its own workflow chained off the matrix
(`prp-bench.yml`); do the same here:

- `.github/workflows/add-node-test.yml`, `workflow_dispatch`, self-hosted
  `[self-hosted, kvm-prp-lab]`, `MIRROR_REGISTRY_HOST` from secrets.
- Deploy `single`, run `test-add-node.sh`, convert to JUnit, wipe.
- Extend `scripts/wipe-all-sno.sh` to clean up `worker-01` — easy to forget,
  and a stale worker VM will break the next matrix run by eating host RAM.
- `scripts/build-dashboard.py` should pick the suite up with no change, since
  it reads JUnit. Verify rather than assume.

---

## Two possible outcomes

**Outcome A — it works.** The deliverable is the exact credential and CA wiring
that made it work, written up as a runbook step. That is directly useful: it is
the answer to question 3 in the ABB thread, and it converts an offer into
evidence.

**Outcome B — it fails.** Then this repo has reproduced KB 7120019 or KB 7111353
on a current release, with a minimal, fully-automated reproducer and node-local
evidence — which is exactly the shape of the three upstream issues already
drafted in `docs/upstream-issue-*.md`. Root-cause it, check whether the existing
KBs cover the failure or whether it is distinct, and draft accordingly.

Outcome B is the more valuable result and should not be treated as a failed
test case. Record it the way the 5000 msg/s benchmark failure was recorded:
kept, explained, not tuned away.

---

## Out of scope

- **Control-plane expansion.** Different risk profile (etcd quorum), and SNO to
  3-node is not a supported path. Separate spec if wanted.
- **Node replacement.** The natural follow-on, and arguably more valuable for a
  site runbook, but it needs a healthy multi-node cluster first — so it depends
  on this one landing.
- **Adding workers to the PRP topologies.** Deliberately deferred; see
  Requirement 1.
- **Hub/spoke and ZTP.** A different front end entirely and a much larger piece
  of work.

## Risks

| Risk | Mitigation |
|---|---|
| SNO + worker is an unusual topology and may hit unrelated defects | Confirm the version's support statement for adding workers to SNO before building; if it is not supported, switch the base to a 3-node compact cluster and accept the host-RAM cost |
| Host RAM contention | 24 GB of 46 GB; wipe between phases as the matrix already does |
| A stale `worker-01` breaks later runs | Wipe-script change is part of Requirement 5, not an afterthought |
| Version drift — the KBs are version-specific | Pin and record the exact OCP version in the result; a pass on one release says nothing about another |

## Sequencing

Requirements 1 and 2 are small. Requirement 3 is the real work. Requirement 4 is
what makes the result mean anything, so it should not be deferred to "later" —
if it slips, the test case is a node-join test, not a disconnected one.

Decide Requirement 1's support question before writing any code.
