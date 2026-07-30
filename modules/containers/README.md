# containers

Container definitions, as data. One attrset key per container under
`nixlxc.containers.<name>`; each renders to a real liblxc `.config` document and stays
materialized at `nixlxc.host.containersPath`/<name>/config on every activation. See the
module's own header comment for the full SCOPE block, and its "ALWAYS COMPOSED WITH
modules/lxc-host" note — this module reads `nixlxc.host.containersPath` directly and asserts
`nixlxc.host.enable`.

## What "kept materialized" means, precisely

liblxc has no separate "declare" verb the way libvirt's `virsh define` does — a container's
`.config` file, sitting at `<lxcpath>/<name>/config`, *is* its definition; `lxc-start` simply
reads whatever is there. So this module renders that file as NixOS-managed data and a
per-container systemd oneshot writes it to the real path on every activation, ordered to run
before the upstream `lxc.service` autostart pass. That oneshot only ever writes ONE file — it
never touches `<lxcpath>/<name>/rootfs`, and it never calls `lxc-start`/`lxc-stop`. Starting,
stopping, or restarting a container remains entirely an operator action (see
`modules/lxc-host/README.md`'s own "Starting and stopping a container, day to day").

## Options

| Option | Type | Default | Description |
|---|---|---|---|
| `nixlxc.containers.<name>.rootfs.path` | null or str | **no default** | Absolute host directory backing this container's `/` (liblxc's `dir:` rootfs mode). |
| `nixlxc.containers.<name>.initCmd` | str | `"/sbin/init"` | What liblxc executes as PID 1. |
| `nixlxc.containers.<name>.deliver` | list of str | `[ ]` | Names into `nixstorage.delivery.categories` — **never a host path**. See "deliver vs idmap" below. |
| `nixlxc.containers.<name>.idmap.base` | null or str | `null` | Name into `nixiam.posix.identities` this container's uid/gid 0 maps to on the host. `null` = privileged (no idmap at all). See "deliver vs idmap" below. |
| `nixlxc.containers.<name>.idmap.count` | positive int | `65536` | Size of the mapped uid/gid range. |
| `nixlxc.containers.<name>.autostart` | bool | `false` | Started at HOST boot via the upstream `lxc.service` pass — see `modules/lxc-host`. |
| *(no resource ceiling option)* | — | — | **Read from `nixhost.environments.<name>.resources`, matched by name.** `ram.limitMiB` renders `lxc.cgroup2.memory.max`; `cpu.quotaCores` renders `lxc.cgroup2.cpu.max`. Absent nixhost renders neither — an unbounded container is liblxc's own default, and inventing a number here would both make a silent resourcing decision and disarm nixhost's oversubscription arithmetic. |
| `nixlxc.containers.<name>.extraConfig` | lines | `""` | Escape hatch: raw liblxc config lines appended verbatim. |

## `deliver` vs `idmap` — two defensive reads, two different failure modes

Both `deliver` and `idmap.base` are **names**, resolved against a sibling repo's own table
(`nixstorage.delivery.categories`, `nixiam.posix.identities`), read defensively
(`config.<x> or { }`) exactly as `nixstorage`'s own `modules/reconciler.nix` reads
`nixiam.posix.identities` — importing `nixlxc` without either sibling evaluates fine. What
happens when a name does NOT resolve is deliberately **not** the same in both cases:

- **`deliver`**: an unresolved name is a hard, named build error **only once
  `nixstorage.delivery.categories` is actually declared** (that module is imported). If
  `nixstorage` is not imported into this configuration **at all**, every `deliver` entry
  silently resolves to nothing — no mount is rendered, and no assertion fires. This is
  deliberate, not a gap: a cross-repo assertion that fails every host which has not yet
  adopted `nixstorage` would never be adoptable incrementally. The failure mode being made
  safe here — a missing mount — has a safe empty default.
- **`idmap.base`**: an unresolved name is **always** a hard, named build error the moment it
  is set to anything other than `null`, whether or not `nixiam`'s posix module is imported at
  all. There is no "silent when absent" carve-out here, because the failure mode is not "a
  mount is missing" but "a container silently stays MORE privileged than declared" — and that
  must never pass quietly. The error message states plainly when `nixiam` does not appear to
  be imported at all, as a hint, but it fails either way.

Both are proven in `checks/`, including the one case that must stay **silent**
(`deliver/silent-when-nixstorage-entirely-absent`) and the one that must **never** be silent
even in the symmetric-looking absent case (`idmap/unresolved-fails-when-nixiam-entirely-absent`).

## Why the mount target is a category's own `home` leaf, at the container's root

`nixstorage.delivery.categories.<name>.home` is documented, in nixstorage's own
`modules/delivery.nix`, as "the leaf name a consumer surfaces it at". A container has no
single human `$HOME` the way a desktop session does, so a delivered category surfaces directly
at `/<home>` under the container's own filesystem root (`/media`, `/work`, …) — see
`lib/lxc-config.nix`'s own header for the full reasoning.

## What is deliberately NOT modeled in this first cut

- **Network attachment** (a veth device, a bridge). No option surface for it — this module was
  built to fix `deliver`/`idmap` correctness, not to be a complete container definition. Attach
  one via `extraConfig` until it earns a dedicated option.
- **Any rootfs backend other than a plain host directory** (`dir:`). A zvol-backed or
  image-backed rootfs is future scope.
- **Multiple, discontiguous idmap ranges.** `idmap.base`/`.count` render a single contiguous
  range starting at container-side `0` — the common case. Reach for `extraConfig` for anything
  more elaborate.

## Minimal example

```nix
{
  imports = [ nixlxc.nixosModules.default ]; # lxc-host + containers together

  nixlxc.host = {
    enable = true;
    containersPath = "/var/lib/nixlxc/containers";
  };

  nixlxc.containers.example-container = {
    rootfs.path = "/var/lib/nixlxc/roots/example-container";
    # ceiling comes from nixhost.environments.<name>.resources -- see the table above
    deliver = [ "media" ]; # resolves once nixstorage.delivery.categories.media is declared
    autostart = false;
  };
}
```

## Status

First cut. Not yet re-verified against a live host with a real container running — see the
repo README's "Status" section.
