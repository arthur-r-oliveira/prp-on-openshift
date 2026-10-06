# RHEL Jira draft: nmstate `gen_conf` drops the `[hsr]` section

**Target**: https://issues.redhat.com, project **RHEL**, component
**nmstate**. (Not Bugzilla - retired for new RHEL product bugs.)

**Status**: drafted, not filed.

**Relationship to the other drafts**: this is the product-tracker version
of `upstream-issue-1-nmstate-hsr-gen-conf.md`. Same defect, framed for
RHEL triage and backport rather than for upstream maintainers - the deep
source trace lives in that doc and is summarised here only as much as a
triager needs. File this first (it's what creates the backport path into
a shipped package), then the upstream PR, then cross-link the two.
`upstream-issue-2-agent-based-installer-hsr.md` and
`upstream-issue-3-assisted-installer-agent-hsr-inventory.md` are separate
OpenShift-side items and belong in OCPBUGS, not here.

**Note on framing**: everything below the line is written for a RHEL
audience and stands on its own against the `nmstate` package - no
OpenShift knowledge required, and nothing in the reproducer or the fix
involves it. OpenShift appears only in a clearly-marked appendix, as one
affected consumer among a class of them. Please keep it that way if you
edit this; the people triaging it do not work on OpenShift.

---

## Summary

```
nmstatectl gc generates an unloadable NetworkManager keyfile for hsr (HSR/PRP) interfaces: the [hsr] section is missing entirely
```

## Component / version

- **Component**: `nmstate`
- **Affected NVR**: `nmstate-2.2.60-2.el10_2.x86_64`
- **Affected RHEL**: 10.2 (expected to affect 9.8+ equally - both ship the
  GA HSR/PRP support; only 10.2 was tested here)
- **Also present upstream**: yes - `nmstate` default branch (`base`) at
  commit `7e698d62f875f4e885601c8db00be553d8958adb`, checked 2026-10-06.
  Not a packaging or backport artefact, and not a regression: the offline
  path appears never to have supported `hsr`.

## Description

HSR/PRP (IEC 62439-3) interface support is GA in RHEL 10.2 and documented
in the Red Hat KB *"How to configure HSR/PRP interfaces using nmstate in
Red Hat Enterprise Linux"*. `nmstate` offers two ways to apply an
interface state, and **only one of them honours `hsr`**:

| Path | Command | Result |
|---|---|---|
| Live apply | `nmstatectl set`, `nmcli connection add type hsr ...` | **Works correctly** |
| Offline generation | `nmstatectl gc` | **Silently produces an unloadable profile** |

`nmstatectl gc` writes a keyfile that sets `type=hsr` under `[connection]`
but contains **no `[hsr]` section at all**. NetworkManager rejects the
profile at load time:

```
NetworkManager[...]: <warn> keyfile: load: ".../prp0.nmconnection":
  failed to load connection: invalid connection: hsr: setting required for connection of type 'hsr'
```

The interface is therefore never created:

```
# ip -d link show prp0
Device "prp0" does not exist.
```

The input YAML is schema-valid and `gc` exits 0. Nothing warns, nothing
fails, and the resulting file looks plausible unless you know to check for
the missing section.

## Steps to reproduce

Needs only the `nmstate` package on a RHEL 10.2 host. No other product,
no special hardware, no running NetworkManager required.

1. Save as `hsr-state.yaml`:
   ```yaml
   interfaces:
   - name: eth0
     type: ethernet
     state: up
     mac-address: "52:54:00:aa:aa:10"
     ipv4: { enabled: false }
     ipv6: { enabled: false }
   - name: eth1
     type: ethernet
     state: up
     mac-address: "52:54:00:aa:aa:10"
     ipv4: { enabled: false }
     ipv6: { enabled: false }
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
   ```
2. `nmstatectl gc hsr-state.yaml`
3. Inspect the generated `prp0.nmconnection`.

(The matching `mac-address` on `eth0`/`eth1` is optional - `nmstate`
propagates one automatically - but if both are set they must be identical.
That validation is correct and unrelated to this bug.)

### Actual result

```ini
[connection]
autoconnect=true
autoconnect-slaves=1
id=prp0
interface-name=prp0
type=hsr
uuid=fcd9e789-3883-51eb-aa9c-64012cfee9af

[ipv4]
address0=192.168.140.50/24
dhcp-timeout=2147483647
method=manual
...

[ethernet]
cloned-mac-address=52:54:00:AA:AA:10
```

No `[hsr]` section. Copy this profile to
`/etc/NetworkManager/system-connections/`, `chmod 600`, and
`nmcli connection reload` - it is rejected with the error above.

### Expected result

A populated `[hsr]` section, i.e. the keyfile equivalent of what this same
input already sends over D-Bus on a live system:

```ini
[hsr]
port1=eth0
port2=eth1
prp=true
```

(`multicast-spec` is correctly omitted at its default of `0`; keys are
emitted sorted.)

### Contrast: the live path on the same host

```
# nmcli connection add type hsr con-name prp0 ifname prp0 \
    hsr.port1 eth0 hsr.port2 eth1 hsr.prp yes
# ip -d link show prp0
9: prp0: <BROADCAST,MULTICAST,UP,LOWER_UP> ...
    hsr slave1 eth0 slave2 eth1 ... proto 1
```

Same interface definition, same `nmstate` build, working interface. Only
the offline writer is affected.

## Impact

`nmstatectl gc` exists specifically to produce NetworkManager
configuration **without a running NetworkManager** - that is, to bake
networking into an image or lay it down before the first boot. Everything
in that class is affected when the interface is `hsr`:

- image-build pipelines that pre-populate
  `/etc/NetworkManager/system-connections/`
- kickstart `%post` and other provisioning scripts generating profiles
  ahead of first boot
- image-mode / golden-image workflows where the network config ships
  inside the image
- any automation that validates a state file with `nmstate` and writes the
  result out rather than applying it live

Because the failure lands at first boot, there is no administrator present
to see it. Severity splits sharply by topology:

- **`hsr` as a secondary interface**: the host boots normally and the
  HSR/PRP interface is simply, silently absent. Recoverable afterwards via
  the live path.
- **`hsr` as the primary or only address-bearing interface**: the host
  comes up with **no network connectivity whatsoever**. No DNS, no package
  or container repositories, no SSH. Recovery requires physical or
  out-of-band console access and `rd.break` into a `dracut` emergency
  shell, because no remote path to the machine exists.

That second case is not a contrived configuration - it is the main reason
to deploy PRP at all. HSR/PRP is an IEC 62439-3 protocol for substation
automation, rail signalling and comparable control networks, where the
whole point is seamless redundancy on *the* link that matters. A host
whose only network is PRP is the normal shape of that deployment.

No known customer case attached - found during HSR/PRP enablement testing.
Filing proactively.

## Root cause

A serialization gap in one of two parallel writers. The in-memory model is
correct in both; only the final step differs.

`settings/connection.rs` dispatches `Interface::Hsr` to
`gen_nm_hsr_setting()` unconditionally, and that function correctly
populates `nm_conn.hsr` in either mode. Then:

- **Live apply** → `NmConnection::to_value()` has an `hsr` branch, backed
  by a correct `ToDbusValue` impl in `nm_dbus/connection/hsr.rs`. Works.
- **Offline (`gc`)** → `NmConnection::to_keyfile()`
  (`nm_dbus/gen_conf/conn.rs`) has a `sections.push(...)` branch per
  settings type and **none for `hsr`**, and there is no `hsr.rs` under
  `nm_dbus/gen_conf/` providing a `ToKeyfile` impl.

So `self.hsr` is fully populated by the time `to_keyfile()` runs, and that
function never looks at it. There is no fallback branch or passthrough,
which is why the setting is dropped silently rather than mangled or
diagnosed.

`gen_conf/` has explicit handling for `bond`, `bridge`, `vlan`, `vxlan`,
`sriov`, `macsec`, `vrf`, `veth`, `vpn`, `infiniband` and others - `hsr` is
the omission, consistent with it never having been wired up rather than
having regressed. (`ipvlan` looks like the same gap; not verified.)

Full trace: `upstream-issue-1-nmstate-hsr-gen-conf.md`.

## Proposed fix

Five lines, following the existing `vrf.rs` pattern exactly. `ToKeyfile`'s
default body reuses `ToDbusValue::to_value()`, and `NmSettingHsr` already
has a correct `ToDbusValue` impl, so no field list needs writing:

- new `rust/src/lib/nm/nm_dbus/gen_conf/hsr.rs`:
  ```rust
  // SPDX-License-Identifier: Apache-2.0

  use super::super::{NmSettingHsr, ToKeyfile};

  impl ToKeyfile for NmSettingHsr {}
  ```
- `nm_dbus/gen_conf/mod.rs`: add `mod hsr;`
- `nm_dbus/gen_conf/conn.rs`, in `NmConnection::to_keyfile()`:
  ```rust
  if let Some(hsr_set) = &self.hsr {
      sections.push(("hsr", hsr_set.to_keyfile()?));
  }
  ```

Verified by hand: writing exactly that `[hsr]` section into a real boot's
NetworkManager configuration, in place of `gen_conf`'s output, brings
`prp0` up correctly with `proto 1` (PRP) and full IP connectivity. That
exercised the PRP path (`port1`/`port2`/`prp=true`); the HSR protocol
variants and `interlink` go through the same default `ToKeyfile` body and
the same already-correct `ToDbusValue` impl, so they should follow, but
have not been put on a wire.

We are happy to submit the upstream PR. The fix has to land upstream to
survive the next rebase; this Jira is for the backport into RHEL.

### Verifying a fix

`nmstatectl gc` on the reproducer above emits an `[hsr]` section; the
resulting keyfile loads without the `setting required` error; `prp0`
appears with `proto 1`. A `gc` round-trip unit test for `hsr` would catch
any future recurrence - there is currently no keyfile-generation test
coverage to extend other than `unit_tests/ovs.rs`.

## Workaround

Both are expert-level; neither is a long-term answer.

- **`hsr` as a secondary interface**: skip `gc` and configure the
  interface after first boot via the live path (`nmcli connection add type
  hsr ...` or `nmstatectl set`), which is unaffected.
- **`hsr` as the primary interface**: the host is unreachable, so there is
  no after-the-fact path. A hand-written keyfile containing the `[hsr]`
  section must be injected into the image before first boot, replacing
  `gc`'s output. Confirmed working, but not something the normal
  configuration surfaces expose.

## Related (not duplicates)

- `nmstate/nmstate#2302` - "Support for PRP/HSR", still open upstream even
  though the feature landed in `#2469`. This `gen_conf` gap may be part of
  why it has not been closed out.
- **RHEL-75817**, **RHEL-85769**, **RHEL-40917** - existing RHEL-side
  HSR/PRP items concerning `copy-mac-from` behaviour. Different defect;
  listed only to connect this to the HSR/PRP work already tracked in RHEL.
- KB *"How to configure HSR/PRP interfaces using nmstate in Red Hat
  Enterprise Linux"* - the documented, supported configuration path, whose
  schema this reproducer follows exactly.

## Suggested fields

- **Severity**: High. Silent, total loss of connectivity with no
  user-visible diagnostic in the primary-interface topology; low in the
  secondary-interface case. Flagged for triage rather than asserted -
  adjust to whatever the HSR/PRP support commitment warrants.
- **Priority**: defer to triage.
- **Fix version**: RHEL 10 z-stream, given HSR/PRP is GA in 10.2. Worth
  checking whether 9.8+ needs the same backport.
- **Links**: upstream GitHub PR once filed; the OCPBUGS items below.

---

## Appendix: downstream consumer (context only, not needed for triage)

Not required to understand or fix the bug - included only because it is
where we hit it, and because it shows the defect reaching a shipping
product.

OpenShift's Agent-Based Installer uses `nmstatectl gc` to generate
first-boot network configuration for the hosts it installs. It therefore
inherits this defect exactly: a schema-valid HSR/PRP definition produces a
host with no `prp0`. Reproduced identically on OpenShift 4.19.45 and
5.0.0-rc.2, builds months apart - again consistent with "never supported"
rather than a recent break. OpenShift's own Day-2 mechanism
(`kubernetes-nmstate-operator`) works fine, because it drives the live
D-Bus path rather than `gen_conf`.

Those symptoms are tracked separately in OCPBUGS. **This Jira is the one
that produces the actual package fix**; the OpenShift items are downstream
trackers that close when a fixed `nmstate` ships.
