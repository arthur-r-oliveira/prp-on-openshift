# Upstream issue draft (3 of 3): assisted-installer-agent

**Target**: `openshift/assisted-installer-agent` on GitHub (the host
inventory collector), or - for the internal path - a Jira at
https://issues.redhat.com, project **OCPBUGS**, component **Assisted
Installer**. (Not Bugzilla - retired for new OpenShift product bugs.
Confirm the exact component string against the project's component list
before filing.) This is a *different* project from the other two drafts -
`nmstate` owns the first bug, `assisted-installer-agent` owns this one.
`assisted-service` is a third, unaffected project here: its own
validation logic is correct given the data it's handed, so this should
not be filed against it.

**Status**: drafted, not filed. Found while working around
`upstream-issue-1-nmstate-hsr-gen-conf.md`'s bug for a topology where
`hsr` is the node's primary network - once that workaround got `prp0`
genuinely working, this second, independent defect is what's currently
blocking full install completion for that topology.

---

## Title

```
Host inventory collector drops hsr-type interfaces entirely (vendored netlink library predates HSR support)
```

## Body

### Describe the bug

A node with a working, correctly-configured `hsr` (HSR/PRP, IEC/RFC
62439-3) interface never reports that interface to `assisted-service` at
all. The interface is completely absent from the host's stored inventory
- not present with empty/wrong fields, simply not there - even though the
interface is fully up, has a valid IP, and is confirmed reachable over
SSH. Downstream effect: any validation that depends on inventory data
(concretely, `belongs-to-machine-cidr`) fails permanently for that host,
even when the node's actual live network configuration is entirely
correct and matches what's expected.

### Version

Traced in the vendored `github.com/vishvananda/netlink` dependency at
`v1.2.1-beta.2` (per this project's `go.mod`) - check whether a newer
release of that library has since added HSR link-type support; if so this
may just need a dependency bump rather than a workaround in this repo's
own code.

### To Reproduce

1. Bring up a real `hsr`-type interface on a RHCOS node running the
   assisted-installer-agent (e.g. via `nmstatectl set` or `nmcli
   connection add type hsr port1 <if> port2 <if> ...`), with a real IP
   address in the cluster's declared machine network CIDR. Confirm it's
   correctly up:
   ```
   $ ip -d link show prp0
   4: prp0: <BROADCAST,MULTICAST,UP,LOWER_UP> ...
       hsr slave1 enp1s0 slave2 enp6s0 ... proto 1 ...
   $ ip -4 addr show prp0
       inet 192.168.140.50/24 ... scope global prp0
   ```
2. Let the agent's inventory collector run (it runs automatically as part
   of host registration/discovery; can also confirm it visibly walks the
   interface via its own logs):
   ```
   $ journalctl -t inventory | grep prp0
   ... level=info msg="Executing biosdevname [-i prp0]" file="execute.go:39"
   ... level=warning msg="Could not read prp0 speed" ...  # benign, unrelated
   ```
3. Inspect what actually got stored for this host (from the node, against
   the local `assisted-db` container):
   ```
   $ sudo podman exec assisted-db psql -h 127.0.0.1 -U admin -d installer \
       -t -A -c "select inventory from hosts limit 1;" | python3 -m json.tool
   ```

### Expected behavior

The stored inventory's `interfaces` array includes an entry for the `hsr`
interface, with its real `ipv4_addresses` populated (matching what `nmcli`
/ `ip addr` show live on the node) - the same shape already correctly
reported for every physical interface.

### Actual behavior

The `hsr` interface is entirely missing from the stored inventory's
`interfaces` array. Only the physical port interfaces underneath it
(`enp1s0`, `enp6s0` in this repro) are present, each correctly reported
but with no IP (by design in this topology - the `hsr` interface is the
only address-bearing one). No error is logged that specifically names the
`hsr` interface being dropped.

### Suspected root cause

`src/inventory/interfaces.go`'s `newInterfaces().getInterfaces()` builds
one `models.Interface` record per OS interface, and near the end of that
per-interface loop:
```go
rec.Type, err = in.Type()
if err != nil {
    logrus.WithError(err).Warnf("Retrieiving interface type for %s", in.Name())
    continue
}
ret = append(ret, &rec)
```
`in.Type()` (`src/util/network_interface.go`) resolves a non-physical
interface's kind via `n.dependencies.LinkByName(name)` (from the vendored
`vishvananda/netlink` library) and returns `link.Type()`. That library, at
the pinned version, has **no representation of the `hsr` link kind at
all** - confirmed by grepping its entire vendored source tree for `hsr`/
`Hsr`/`HSR`: zero matches, no `Hsr` struct alongside its `Bridge`, `Vlan`,
`Bond`, `Vxlan`, etc., and no `"hsr"` case in the link-type deserializer's
switch statement (`vendor/.../netlink/link_linux.go`, `LinkDeserialize`).

That switch does have a generic fallback for unrecognized kinds
(`default: link = &GenericLink{LinkType: linkType}`), so `LinkByName`
itself may well succeed and return a `GenericLink` with `LinkType: "hsr"`
rather than erroring outright - in which case `in.Type()` would return
`("hsr", nil)`, no error, and this exact `continue` would **not** be what
drops the record. Checked the collector's own logs for the two
error-logging points in this loop (`Retrieiving interface type for %s`,
`Retrieving addresses for %s`) specifically for `prp0` - neither fired.
So the precise single line responsible for the interface never reaching
`ret` (or reaching assisted-service afterward) is **not confirmed with
certainty** in this writeup - a standalone Go program exercising this
exact vendored library against a real `hsr` interface would settle it,
and wasn't built here. What is confirmed: the library has no purpose-built
understanding of `hsr` anywhere, and the empirically observed symptom
(collector visibly walks the interface, reported inventory never has it)
is consistent with that gap regardless of which exact line is responsible.

### Suggested fix

1. Update the vendored `vishvananda/netlink` dependency to a version with
   HSR link-type support, if one exists upstream - check
   https://github.com/vishvananda/netlink for HSR-related commits/releases
   since `v1.2.1-beta.2`.
2. If no such version exists yet, either contribute HSR support to
   `vishvananda/netlink` upstream first, or add a local special case in
   `NetworkInterface.Type()`/`getInterfaces()` so an interface whose kind
   can't be classified still gets reported (with a best-effort or generic
   `Type` value) rather than silently dropped - losing an entire
   interface record, IP addresses included, over an unrecognized `Type`
   seems too costly a failure mode regardless of which specific kind
   triggers it; today it's `hsr`, tomorrow it could be any other kernel
   feature this library hasn't caught up to yet.

### Downstream impact

Any `assisted-service` validation that depends on inventory-reported
interfaces - concretely `belongs-to-machine-cidr` - fails permanently and
unrecoverably for a host whose only address-bearing interface is `hsr`
(or any other interface kind this library doesn't recognize), even though
the node's actual network configuration is entirely correct. There is no
known workaround from this repo's side: unlike the companion `nmstate`
bug (fixable by hand-delivering a correct static file), this gap is in
what the node itself reports about its live state, which this repo has no
mechanism to override or supplement.

### Related

- `upstream-issue-1-nmstate-hsr-gen-conf.md` - a separate bug, in a
  separate project (`nmstate`), that this repo hit first while validating
  the same `hsr`/PRP topology. Not the same defect and not the same fix,
  but both stem from HSR/PRP being newer than either project has fully
  caught up on.
- `docs/spec-test-case-3-prp-primary.md` - the full test case this was
  found investigating, including the confirmed-working Day-0 workaround
  for the first bug and the point at which this second one surfaced.
