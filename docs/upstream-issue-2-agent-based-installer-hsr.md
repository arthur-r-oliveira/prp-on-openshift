# Upstream issue draft (2 of 3): OpenShift Agent-Based Installer

**Target**: Jira at https://issues.redhat.com, project **OCPBUGS**,
component **Assisted Installer**. (Not Bugzilla - retired for new
OpenShift product bugs. Confirm the exact component string against the
project's component list before filing.) That looks like the right
primary path here, since the actual generation of the Day-0 network
config from `AgentConfig`/`NMStateConfig` happens in assisted-service's
territory (confirmed by the on-node file layout - see "Evidence" below -
not by reading assisted-service's own source, which wasn't traced the way
nmstate's was for the companion issue). A GitHub issue against
`openshift/assisted-service` is a reasonable mirror if that project takes
issues directly.

**Status**: drafted, not filed. This is the **downstream tracking issue**
- the actual defect lives in `nmstate`: see
`upstream-issue-1-nmstate-hsr-gen-conf.md` for the source trace, and
`rhel-jira-nmstate-hsr-gen-conf.md` for the RHEL Jira that is what
actually produces a fixed package. File those first or alongside this
one, and link them here once they have numbers.

**Why file this too, rather than only the nmstate issue**: three reasons.
1. Someone triaging Agent-Based Installer bugs needs to find this without
   already knowing it's actually an nmstate problem - the installer's own
   UX gives zero indication of that.
2. There's a real, currently-undocumented gap for one specific topology
   (HSR/PRP as the *primary* network) - a Day-0-applicable workaround now
   exists (see below), but it's expert-level (hand-editing the ISO's
   Ignition config) and worth a tracked item regardless of who owns the
   eventual `nmstate` fix.
3. Whoever owns the vendored/packaged `nmstate` version bump on the
   installer side needs their own ticket to track picking that fix up
   once it lands upstream.

---

## Title

```
Agent-Based Installer: Day-0 `hsr` (HSR/PRP) interface config is silently non-functional (upstream nmstate gen_conf bug); total node connectivity loss if HSR is the primary network
```

## Body

### Summary

Declaring an `hsr`-type interface (HSR/PRP, IEC/RFC 62439-3) in
`agent-config.yaml`'s `networkConfig` - a legitimate, schema-valid
NMState construct that the installer accepts without complaint at
ISO-build time - produces a node that never actually gets that interface.
The generated NetworkManager keyfile has `type=hsr` but is missing the
entire `[hsr]` settings section, so NetworkManager refuses to load it and
the interface never exists at boot.

- If `hsr` is a **side interface** (node also has another NIC with
  normal IP connectivity): node installs fine, that one interface is
  just silently absent. Recoverable via Day-2
  `kubernetes-nmstate-operator` + `NodeNetworkConfigurationPolicy` once
  the cluster is up (confirmed working - see "Workaround" below).
- If `hsr` is the **primary/only address-bearing interface** (a
  legitimate topology for protecting the one link that matters, e.g.
  substation/rail control networks - not just a redundant side channel):
  the node gets **zero network connectivity at all**. No DNS, no ping, no
  reachable registry. Installation cannot proceed via the normal Day-2
  path - `kubernetes-nmstate-operator` needs a reachable node/API, which
  doesn't exist here - but a Day-0-applicable workaround does exist (see
  "Workaround, primary-interface case" below): confirmed working, though
  it requires hand-editing the ISO's Ignition config, not something
  `AgentConfig`/`install-config.yaml` expose on their own.

The installer's own network pre-flight check surfaces this as a generic
DNS/HTTP failure, giving no indication that the actual cause is a
malformed NetworkManager profile - a user hitting this has no path to the
real cause without inspecting the node directly (which, in the
primary-interface case, requires dropping into a `dracut` emergency shell
via `rd.break`, since there's no SSH path either).

### Root cause (confirmed, not the installer's own code)

Traced to an upstream `nmstate` bug, not something in the Agent-Based
Installer or assisted-service's own logic: `nmstate`'s offline
configuration-generation mode (`nmstatectl gc`, the same mechanism used to
produce the Day-0 NetworkManager profile baked into the ISO) never
implemented an `hsr`-specific keyfile serializer, while the live-apply
path (D-Bus, used by `nmcli`/`kubernetes-nmstate-operator`) has one and
works correctly. Full trace and a minimal, installer-independent
reproduction (plain `nmstatectl gc` against a 3-interface YAML, no
OpenShift involved) is in the companion upstream issue:
`upstream-issue-1-nmstate-hsr-gen-conf.md` (link once filed).

Confirmed identically on:
- OpenShift 4.19.45
- OpenShift 5.0.0-rc.2

Same symptom, months apart in installer builds - consistent with "this
was never supported," not a regression in either release.

### Steps to reproduce

1. In `agent-config.yaml`, under a host's `networkConfig.interfaces`,
   declare two plain ethernet interfaces and one `hsr` interface binding
   them, with the `hsr` interface carrying the node's address (minimal
   example - adjust MACs/addresses as needed):
   ```yaml
   networkConfig:
     interfaces:
       - name: eth0
         type: ethernet
         state: up
         mac-address: "52:54:00:aa:aa:01"
         ipv4: { enabled: false }
       - name: eth1
         type: ethernet
         state: up
         mac-address: "52:54:00:aa:aa:01"
         ipv4: { enabled: false }
       - name: prp0
         type: hsr
         state: up
         hsr:
           port1: eth0
           port2: eth1
           multicast-spec: 0
           protocol: prp
         ipv4:
           enabled: true
           dhcp: false
           address:
             - ip: 192.168.140.50
               prefix-length: 24
     routes:
       config:
         - destination: 0.0.0.0/0
           next-hop-address: 192.168.140.1
           next-hop-interface: prp0
   ```
   (`eth0`/`eth1` must share one `mac-address` - a real HSR/PRP protocol
   constraint correctly validated elsewhere, unrelated to this bug; noted
   so the repro is directly usable.)
2. `openshift-install agent create image --dir=<dir> --log-level=debug` -
   succeeds, no validation error surfaced.
3. Boot the resulting ISO with `prp0` as the only address-bearing
   interface.
4. Node never obtains any network connectivity. Installer's network
   pre-flight screen shows generic DNS/ping/HTTP failures with no
   indication of the actual cause.

### Evidence

Node-local confirmation (this topology has no SSH path once it fails):
added `console=tty0 console=ttyS0,115200n8` plus, for this investigation,
`rd.break=pre-pivot` to the ISO's kernel args (`coreos-installer iso kargs
modify`) to capture a dracut emergency shell over serial - after ignition
writes its files to `/sysroot` but before NetworkManager or the `hsr`
kernel module ever run.

Confirms the on-node file layout for how this installer stages Day-0
network config:
```
/sysroot/etc/assisted/manifests/nmstateconfig.yaml       # source NMStateConfig - correct
/sysroot/etc/assisted/network/host0/eth0.nmconnection
/sysroot/etc/assisted/network/host0/eth1.nmconnection
/sysroot/etc/assisted/network/host0/prp0.nmconnection    # staged keyfile - broken
/sysroot/etc/systemd/system/NetworkManager.service.wants/nmstate.service
```
`nmstateconfig.yaml` has a complete, correct `hsr:` block. The staged
`prp0.nmconnection` has `type=hsr` with no `[hsr]` section - identical
defect shape to feeding the same input directly to plain `nmstatectl gc`
on a non-OpenShift host (see companion nmstate issue).

Screenshots of the installer's own failure screen (generic DNS/HTTP
errors, no hint of the real cause): available, not reproduced inline
here since they're stored as local evidence files rather than pasted
images in this draft.

### Ask

1. **Track and consume the upstream `nmstate` fix** once it lands
   (`upstream-issue-1-nmstate-hsr-gen-conf.md` / its filed equivalent) -
   bump whatever `nmstate` version/vendoring the Day-0 ISO-build path
   uses.
2. **In the meantime**, two independent, smaller asks worth considering
   on their own:
   - Improve the network pre-flight check's diagnostics to distinguish
     "no interface ever came up because its NetworkManager profile is
     malformed" from a generic DNS/connectivity failure - would have
     surfaced this specific class of bug (and similar future ones) far
     faster, without needing console/kernel-arg surgery to even see the
     real cause.
   - Document the Day-0 Ignition-merge workaround below as official
     guidance for HSR/PRP-as-primary-network topologies - Day-2
     `kubernetes-nmstate-operator` still can't help here (no reachable
     node/API), but the Day-0 path works and shouldn't require reverse-
     engineering the ISO's staging directories to discover, the way it did
     here.

### Workaround, side-interface case: Day-2 operator

For topologies where the `hsr`/PRP interface is *not* the node's only
connectivity (a normal NIC also exists for API/Ingress/egress):
`kubernetes-nmstate-operator` + a `NodeNetworkConfigurationPolicy` applied
Day-2, once the cluster is up, correctly configures the interface - it
goes through nmstate's live-apply/D-Bus path rather than the broken
offline-generation path, so it's unaffected by this bug. Confirmed
working in this environment. **Not usable** when HSR/PRP is the primary
network, since there's no way to reach the operator's handler on a node
with no network at all - see "Summary" above.

### Workaround, primary-interface case: Day-0 Ignition merge (new, confirmed working)

Turns out there is a Day-0-applicable option after all, just not through
the mechanism you'd reach for first. **"Day-0 extra manifests"
(`<install_dir>/openshift/*.yaml`, MachineConfigs) do not help here** -
confirmed via a `dracut rd.break` shell that they stage at
`/etc/assisted/extra-manifests/` for the Machine Config Operator to apply
once a cluster exists, not on the live boot filesystem. What does work:
omit the `hsr` interface from `AgentConfig`'s `networkConfig` entirely,
and merge a hand-correct `.nmconnection` keyfile - `nmstate`'s own correct
output for this input, plus the one missing `[hsr]` section - directly
into the ISO's real Ignition config via `coreos-installer iso ignition
show`/`embed`, targeting `/etc/assisted/network/host0/<name>.nmconnection`
(not `/etc/NetworkManager/system-connections/` directly - a script baked
into the ISO's own ignition, `pre-network-manager-config.sh`, wipes that
directory and repopulates it only from the `host0/` staging path before
NetworkManager starts). Confirmed live: `prp0` comes up as
`hsr slave1 enp1s0 slave2 enp6s0 ... proto 1`, node fully reachable over
SSH. Implementation: `scripts/embed-day0-file.py`,
`day0-manifests/prp0.nmconnection.j2` in this repo.

Worth folding into official guidance regardless of whether/when the
upstream `nmstate` fix lands - it's a real, validated path forward for
this exact topology today.

### A second, distinct, now-root-caused issue found via this workaround

With the `hsr` bug fully worked around and `prp0` fully functional,
`assisted-service`'s own pre-install validation still fails:
`Host does not belong to machine network CIDRs`, despite the node's live
address matching the declared `machineNetwork.cidr` exactly. Confirmed
persistent and deterministic across a full wipe + fresh redeploy, not
transient.

**Root-caused - a third, separate upstream bug, in a third project**: see
`docs/upstream-issue-3-assisted-installer-agent-hsr-inventory.md` for the
full trace. Short version: `assisted-installer-agent`'s host inventory
collector never reports `prp0` to `assisted-service` at all (confirmed via
direct DB query - the stored inventory has only the two physical NICs),
because its vendored `netlink` library (`v1.2.1-beta.2`) has no awareness
of the `hsr` link kind. `assisted-service`'s CIDR validator is working
correctly against the (incomplete) data it's given - the defect is
upstream of it, in what the node reports about itself.
