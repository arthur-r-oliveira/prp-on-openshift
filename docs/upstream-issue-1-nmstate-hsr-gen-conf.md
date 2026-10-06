# Upstream issue draft (1 of 3): nmstate/nmstate

**Target**: https://github.com/nmstate/nmstate/issues - or a PR directly,
see "Filing order" below. The Red Hat-internal path is a Jira at
https://issues.redhat.com, project **RHEL**, component **nmstate** -
*not* Bugzilla, which is retired for new RHEL product bugs. See
`rhel-jira-nmstate-hsr-gen-conf.md` for the Jira-shaped version of this
same report.

**Filing order**: RHEL Jira first, then upstream, then cross-link. The
Jira is what creates a backport path into a shipped `nmstate` package - an
upstream merge on its own delivers nothing to RHEL 10.2. But upstream is
where the code has to land regardless: the RHEL package is a rebase of
upstream, so a downstream-only fix would be dropped on the next rebase.
Since the change here is five lines copied from an existing template,
consider opening a PR rather than an issue and letting the review be the
conversation.

**Status**: drafted, not filed. This is the root-cause fix target - see
`upstream-issue-2-agent-based-installer-hsr.md` for the downstream
tracking issue against the Agent-Based Installer side, and
`upstream-issue-3-assisted-installer-agent-hsr-inventory.md` for the
separate inventory-collector defect.

**Why this one first**: this is where the actual defect lives. Filing here
gets the real fix moving; the ABI-side issue exists to track *consuming*
that fix once it exists, and to get the interim risk documented for anyone
who hits this before then.

---

## Title

```
nmstatectl gc / gen_conf: NetworkManager keyfile for `hsr` interfaces is missing the [hsr] section
```

## Labels

`bug`, `kind/bug`, and whatever label nmstate uses for the NetworkManager
backend specifically (haven't confirmed the exact label taxonomy - check
the repo's label list before filing and adjust).

## Body

### Describe the bug

`nmstatectl gc` (offline configuration generation - the `gen_conf` Cargo
feature) produces a NetworkManager keyfile for an `hsr`-type interface
with `type=hsr` set but **no `[hsr]` section at all**. NetworkManager then
refuses to load the resulting profile:

```
NetworkManager[...]: <warn> keyfile: load: ".../prp0.nmconnection":
  failed to load connection: invalid connection: hsr: setting required for connection of type 'hsr'
```

and the interface never comes up (`ip -d link show prp0` → `Device
"prp0" does not exist.`).

The identical interface state, applied **live** instead of generated
offline (`nmstatectl set`, or `nmcli connection add type hsr ...`),
produces a working `hsr` interface with a correct settings group. Only the
offline/`gen_conf` keyfile-writing path is affected - the live D-Bus-apply
path is fine.

### Version

`nmstate 2.2.60` (`nmstate-2.2.60-2.el10_2.x86_64`, RHEL 10.2).

Also checked against the current `base` branch (upstream default branch,
HEAD `7e698d62f875f4e885601c8db00be553d8958adb` as of 2026-10-06): the same
gap is present there too, so this isn't a regression that's already been
fixed and just hasn't shipped yet.

Not a regression at all, in fact - `gen_conf` support for `hsr` was never
implemented, rather than added and later broken. Checked against history
rather than inferred from the tree:

```console
$ git log --all -- rust/src/lib/nm/nm_dbus/gen_conf/hsr.rs
                                  # empty: the file has never existed

$ git log --all -S'hsr' -- rust/src/lib/nm/nm_dbus/gen_conf/
                                  # empty: 'hsr' has never appeared in any
                                  # file under gen_conf/, in any commit

$ git log --all -S'vrf' -- rust/src/lib/nm/nm_dbus/gen_conf/
c9fea9ed rust: Sync with base branch a9cee09...
592d24d0 rust: Conditional compiling by cargo feature
                                  # control: same query, a type that IS wired up
```

Every commit touching HSR under `rust/src/lib/nm/` stayed on the D-Bus
side: `b23da648` (2023-11-20, the original "hsr: add support to HSR/PRP
interface"), `ea255551` (HSRv1/2012), `e7481ab9` (`interlink`), plus
`19e60c17` and `9787cfc9` (reapply/reactivate fixes). None of them added
anything under `gen_conf/`. So the offline path has been missing `hsr`
since the feature's first commit, about two years.

If `gen_conf` coverage was deliberately out of scope for that work, that
would be useful to know and I'll happily drop this - but I couldn't find
a note to that effect in the source, the CHANGELOG, or those commits.

Possibly related: the original feature request for HSR/PRP (#2302, opened
2023-03-30) is still open, despite the feature merging in November 2023.

`ipvlan` looks like the same omission: `gen_conf/ipvlan.rs` exists and
provides the `ToKeyfile` impl, but `conn.rs` never references it, so no
`[ipvlan]` section can be emitted either. Untested - flagging it in case a
fix here should cover both.

### To Reproduce

```yaml
# hsr-state.yaml
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

```
$ nmstatectl gc hsr-state.yaml
```

Note: the explicit `mac-address` on `eth0`/`eth1` is optional -
`copy_hsr_mac()` propagates one automatically. It's spelled out here only
to keep the repro self-contained. If you do set both, they have to match:
`validate_hsr_mac()` rejects differing port MACs on a PRP interface (one
logical LRE identity presented out two ports). That validation is correct
and unrelated to this bug.

### Expected behavior

The generated `prp0.nmconnection` includes a populated `[hsr]` section:
```ini
[hsr]
port1=eth0
port2=eth1
prp=true
```
i.e. the keyfile equivalent of what the same input already sends over
D-Bus via `nmstatectl set` on a live system. (No `multicast-spec` line:
`NmSettingHsr::to_value()` only emits it when `> 0`, so the default `0`
is correctly left out of both paths. Keys come out sorted.)

### Actual behavior

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
No `[hsr]` section anywhere in the file.

### Suspected root cause (traced in source, tag `v2.2.60` and current `base`)

The in-memory model is correct in **both** modes - this isn't a data
problem, it's a serialization gap in exactly one of two parallel writers.

`settings/connection.rs` (shared by both `gen_conf` and live-apply)
unconditionally dispatches:
```rust
Interface::Hsr(iface) => {
    gen_nm_hsr_setting(iface, &mut nm_conn);
}
```
and `settings/hsr.rs`'s `gen_nm_hsr_setting()` correctly populates
`nm_conn.hsr` - `port1`, `port2`, `interlink`, `multicast_spec`, `prp`,
plus `protocol_version` for HSRv1/2012 - regardless of which mode is
calling it.

The two modes only diverge at the final serialization step:

- **Live apply** → `nm_dbus/dbus.rs`'s `connection_add()` /
  `connection_update()` → `NmConnection::to_value()`
  (`nm_dbus/connection/conn.rs`), which has:
  ```rust
  if let Some(hsr) = &self.hsr {
      ret.insert("hsr", hsr.to_value()?);
  }
  ```
  backed by `nm_dbus/connection/hsr.rs`'s `ToDbusValue` impl for
  `NmSettingHsr` - **present and correct**.

- **Offline generate** (`gc`) → `nm/gen_conf.rs`'s `nm_gen_conf()` →
  `NmConnection::to_keyfile()` (`nm_dbus/gen_conf/conn.rs`), which has a
  `sections.push(...)` branch per settings type - and **none for `hsr`**.
  There is also no `hsr.rs` under `nm_dbus/gen_conf/` providing the
  `ToKeyfile` impl.

So `self.hsr` is fully populated by the time `to_keyfile()` runs, but that
function simply never looks at it.

There's no fallback branch or `_other` passthrough in `to_keyfile()`
either, so the setting isn't mangled or partially written - it's dropped
silently. No warning, no error, just a keyfile that NetworkManager then
refuses to load.

### Suggested fix

Since `ToKeyfile`'s default body just reuses `ToDbusValue::to_value()`,
and `NmSettingHsr` already has a correct `ToDbusValue` impl, no field
list needs writing - this is five lines, following `vrf.rs`:

- `rust/src/lib/nm/nm_dbus/gen_conf/hsr.rs` (new):
  ```rust
  // SPDX-License-Identifier: Apache-2.0

  use super::super::{NmSettingHsr, ToKeyfile};

  impl ToKeyfile for NmSettingHsr {}
  ```
- `nm_dbus/gen_conf/mod.rs`: add `mod hsr;`
- `nm_dbus/gen_conf/conn.rs`'s `NmConnection::to_keyfile()`: add
  ```rust
  if let Some(hsr_set) = &self.hsr {
      sections.push(("hsr", hsr_set.to_keyfile()?));
  }
  ```
  alongside the existing branches.

There's no unit-test coverage of keyfile generation to extend other than
`unit_tests/ovs.rs`, so I'd propose a small `nmstatectl gc` round-trip
test for `hsr` unless maintainers prefer it elsewhere.

Happy to submit a PR for this if a maintainer confirms the approach and
there isn't a reason `hsr` was deliberately left out of `gen_conf`
(couldn't find one in the source or the CHANGELOG, but flagging the
possibility rather than assuming).

### Related

Searched open and closed issues and PRs for an existing report of this
and didn't find one. #2302 ("Feature request: Support for PRP/HSR")
appeared to still be open when I checked, even though the feature itself
has clearly landed - if that's still the case, this gap may be part of
why it hasn't been closed out.

### Downstream impact (context, not part of the ask)

This affects any consumer of nmstate's offline/`gen_conf` mode for `hsr`
interfaces - concretely, OpenShift's Agent-Based Installer, where an
`hsr` interface declared for Day-0 network configuration silently fails
to come up at first boot, with no error surfaced anywhere the installer's
own tooling shows the user - only visible via NetworkManager's journal on
the (possibly otherwise unreachable) node itself. A separate downstream
tracking issue covers that side; linking here once both exist.

### Update: the suggested fix is confirmed correct for the PRP case

Validated by hand-writing exactly the keyfile section the analysis above
says `to_keyfile()` is missing - same field names, same values `nmstate`
already produces correctly for every other section of this exact input -
and merging it into a real boot's NetworkManager configuration in place
of `gen_conf`'s output. Result: `prp0` comes up correctly, real `proto 1`
(PRP), full IP connectivity. This isn't a second, independent
confirmation of a different bug - it's the same one, closed by supplying
by hand exactly what the missing `hsr.rs` module would generate.

To be precise about what that does and doesn't establish: the section
exercised was `port1`/`port2`/`prp=true` - the PRP path. The HSR protocol
variants and `interlink` go through the same default `ToKeyfile` body and
the same already-correct `ToDbusValue` impl, so they should follow by
construction, but I haven't put them on a wire. Confirmed for PRP,
expected-correct for the rest of the `hsr` type.
