# RHEL Jira draft: nmstate `gen_conf` drops the `[hsr]` section

**Target**: https://issues.redhat.com, project **RHEL**, component
**nmstate**. (Not Bugzilla - retired for new RHEL product bugs.)

**Status**: drafted, not filed.

**Relationship to the other drafts**: this is the product-tracker version
of `upstream-issue-1-nmstate-hsr-gen-conf.md`. Same defect, framed for
triage and backport rather than for upstream maintainers - the deep
source trace lives in that doc and is summarised here only as much as a
triager needs. File this first (it's what creates the backport path into
a shipped package), then the upstream PR, then cross-link the two.
`upstream-issue-2-agent-based-installer-hsr.md` and
`upstream-issue-3-assisted-installer-agent-hsr-inventory.md` are separate
OpenShift-side items and should be filed in OCPBUGS, not here.

---

## Summary

```
nmstatectl gc generates an unloadable NetworkManager keyfile for hsr (HSR/PRP) interfaces: the [hsr] section is missing entirely
```

## Component / version

- **Component**: `nmstate`
- **Affected NVR**: `nmstate-2.2.60-2.el10_2.x86_64`
- **Affected RHEL**: 10.2
- **Also present upstream**: yes - confirmed on the `nmstate` default
  branch (`base`) at commit `7e698d62f875f4e885601c8db00be553d8958adb`,
  checked 2026-10-06. Not a packaging or backport artefact, and not a
  regression: the offline path appears never to have supported `hsr`.

## Description

`nmstatectl gc` (offline configuration generation) writes a
NetworkManager keyfile for an `hsr`-type interface that sets `type=hsr`
in `[connection]` but contains **no `[hsr]` section at all**.
NetworkManager rejects the resulting profile at load time:

```
NetworkManager[...]: <warn> keyfile: load: ".../prp0.nmconnection":
  failed to load connection: invalid connection: hsr: setting required for connection of type 'hsr'
```

The interface is therefore never created (`ip -d link show prp0` →
`Device "prp0" does not exist.`).

The same interface state applied **live** - `nmstatectl set`, or
`nmcli connection add type hsr ...` - produces a correct, working `hsr`
interface. Only the offline keyfile-generation path is affected.

## Impact

`nmstatectl gc` is the mechanism used to bake Day-0 network configuration
into an installation image, so the failure lands at first boot, before
there is any operator or administrator present to notice it:

- **`hsr` as a secondary interface**: the node comes up normally and the
  HSR/PRP interface is simply, silently absent. Recoverable on Day 2.
- **`hsr` as the primary or only address-bearing interface** - a
  legitimate topology where the point is to protect the one link that
  matters (substation, rail, and similar IEC 62439-3 control networks):
  the node gets **no network connectivity whatsoever**. No DNS, no
  reachable registry, no SSH. Diagnosis requires dropping into a `dracut`
  emergency shell via `rd.break` on the console, because there is no
  remote path to the machine at all.

Nothing in the failure is surfaced to the user by the tooling that
consumed the config - the only evidence is NetworkManager's journal on a
node that, in the second case, cannot be reached. A valid, schema-clean
configuration is accepted without complaint and then silently does
nothing.

Downstream, this reaches OpenShift's Agent-Based Installer, which uses
`gen_conf` for Day-0 network config. Reproduced identically on OpenShift
4.19.45 and 5.0.0-rc.2 - months apart in installer builds, consistent
with "never supported" rather than a recent break. Those are tracked
separately in OCPBUGS; this Jira is the one that needs to produce the
actual package fix.

No known customer case attached - found during HSR/PRP enablement
testing. Filing proactively.

## Steps to reproduce

No OpenShift required; this reproduces against the `nmstate` package
alone.

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
2. Run `nmstatectl gc hsr-state.yaml`.
3. Inspect the generated `prp0.nmconnection`.

(The matching `mac-address` on `eth0`/`eth1` is optional - `nmstate`
propagates one automatically - but if both are set they must be
identical. That validation is correct and unrelated to this bug.)

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

No `[hsr]` section. Copying this profile to
`/etc/NetworkManager/system-connections/` and reloading produces the
`setting required for connection of type 'hsr'` error above.

### Expected result

The generated profile includes a populated `[hsr]` section:

```ini
[hsr]
port1=eth0
port2=eth1
prp=true
```

i.e. the keyfile equivalent of what this same input already sends over
D-Bus on a live system. (`multicast-spec` is correctly omitted at its
default of `0`; keys are emitted sorted.)

## Root cause

Serialization gap in one of two parallel writers - the in-memory model is
correct in both.

`settings/connection.rs` dispatches `Interface::Hsr` to
`gen_nm_hsr_setting()` unconditionally, and that function correctly
populates `nm_conn.hsr` regardless of which mode is running. The two
modes then diverge only at the final step:

- **Live apply** → `NmConnection::to_value()` has an `hsr` branch, backed
  by a correct `ToDbusValue` impl in `nm_dbus/connection/hsr.rs`. Works.
- **Offline (`gc`)** → `NmConnection::to_keyfile()`
  (`nm_dbus/gen_conf/conn.rs`) has a `sections.push(...)` branch per
  settings type and **none for `hsr`**, and there is no `hsr.rs` under
  `nm_dbus/gen_conf/` providing the `ToKeyfile` impl.

So `self.hsr` is fully populated by the time `to_keyfile()` runs and that
function never looks at it. There is no fallback branch or passthrough,
so the setting is dropped silently rather than mangled or diagnosed.

Full trace in `upstream-issue-1-nmstate-hsr-gen-conf.md`.

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
`prp0` up correctly with real `proto 1` (PRP) and full IP connectivity.
That exercised the PRP path (`port1`/`port2`/`prp=true`); the HSR
protocol variants and `interlink` go through the same default `ToKeyfile`
body and the same already-correct `ToDbusValue` impl, so they should
follow, but have not been put on a wire.

Fix must land upstream to survive the next rebase; this Jira should track
the backport into RHEL 10.

## Workaround

Both are expert-level and neither is suitable as a long-term answer.

- **`hsr` as a secondary interface**: configure it on Day 2 via the live
  path instead - `nmcli connection add type hsr ...`, `nmstatectl set`,
  or `kubernetes-nmstate-operator` on OpenShift. The live path is
  unaffected and works correctly.
- **`hsr` as the primary interface**: the node is unreachable, so there
  is no Day-2 path. The config must be corrected before first boot by
  injecting a hand-written keyfile containing the `[hsr]` section into
  the image (on OpenShift ABI, by hand-editing the ISO's Ignition
  config). Confirmed working, but not something the normal configuration
  surfaces expose.

## Suggested fields

- **Severity**: High. Silent total loss of connectivity with no
  user-visible diagnostic in the primary-interface topology; low severity
  in the secondary-interface case. Flagging for triage rather than
  asserting - adjust to whatever the HSR/PRP roadmap commitment warrants.
- **Priority**: defer to triage.
- **Fix version**: RHEL 10 z-stream, if HSR/PRP is a supported
  configuration for 10.2.
- **Links**: upstream GitHub issue/PR once filed; the two OCPBUGS items
  for the OpenShift-side symptoms.
