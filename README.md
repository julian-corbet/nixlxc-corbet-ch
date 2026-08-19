# nixlxc

**A declarative home for LXC container workloads on NixOS: an LXC host stance, and container
definitions as data — where WHAT a container receives is named, never restated as a host path
or a raw number.**

`nixlxc` is the LXC container substrate in a small family of workload-substrate repos: a peer
of [nixk3s](https://github.com/julian-corbet/nixk3s-corbet-ch) (bare metal running k3s),
[nixvm](https://github.com/julian-corbet/nixvm-corbet-ch) (bare metal running VMs), and
`nixpods` (bare metal running podman). A host declares which containers stand on it, what each
one is made of, and what it receives; none of the four substrates owns another.

## The pitch

Running LXC by hand is easy, and the part that always rots first is exactly the part this repo
exists to fix: which storage a container's mount table actually points at, and whether that
still matches what a sibling storage repo calls the same data a year later. `nixlxc` packages
the two questions that matter as one small pair of NixOS modules:

- **Can this host run containers at all?** (`modules/lxc-host`) — liblxc enabled, `lxcpath`
  declared, the upstream `lxc.service`/`lxc-autostart` boot-time pass wired up. Every fact this
  module reads (a directory) already exists; it never creates, formats, or populates anything.
- **What containers does it run?** (`modules/containers`) — per-container
  `rootfs`/`idmap`/`autostart`, and WHICH storage categories each one receives
  (`deliver`), rendered to a real liblxc `.config` document and kept materialized at its
  `lxcpath` location on every activation.

Neither module starts, stops, or restarts a container. Declaring a container's definition is
this repo's job; deciding when it actually runs is the operator's — the same "declare, don't
force" discipline nixvm applies to `virsh define`/`virsh start`.

## What nixlxc replaces, and what it deliberately does differently

This design replaces a private, already-running implementation — a pure string-rendering
function, driven by a per-host storage option of its own, kept in this operator's own private
infrastructure configuration and not ported here — that emitted literal `lxc.mount.entry` lines
with host paths **hardcoded as string literals**. Those same paths
were already declared, once, as data in a private storage model elsewhere. That is a second
copy of facts that already have an owner: exactly the duplication this whole design exists to
remove, and it had a real, concrete cost — a typo'd category name was **structurally
undetectable**. The rendering function had no table to check a name against; a wrong string
just produced a wrong (or missing) mount, silently, discovered only by whoever noticed the
container's data was in the wrong place.

`modules/containers.<name>.deliver` fixes exactly this: it takes **category names**, resolved
against `nixstorage.delivery.categories` at eval time, and an unresolved name is a **build
error**, not a silently-dropped mount — see `modules/containers/README.md`'s own "deliver vs
idmap" section for the one nuance that makes this adoptable incrementally rather than a
breaking requirement on every host. `idmap.base` applies the identical "a name has an owner, a
raw number does not" discipline to uid/gid, resolved against `nixiam.posix.identities` instead
of restating a literal uid.

## Boundaries — stated once, so no knob gets two managers

```
nixlxc owns    : which containers exist, their rootfs, idmap, autostart, and WHICH
                 delivery categories each receives -- and it renders the container's own mount
                 table, because a container's mount table has no other owner.
nixlxc must NOT: declare which datasets exist (nixstorage), export anything over a network
                 (nixshare), own uid/gid (nixiam), or hold any real host's values (that is
                 private and stays in infra).
```

Concretely, three places this repo could quietly absorb scope, and doesn't:

- **vs. `nixstorage` — nixlxc never declares a dataset.** `nixstorage.delivery.categories` is
  the one and only table `deliver` reads; `nixlxc` holds no path of its own beyond a
  container's own `rootfs.path` and `nixlxc.host.containersPath` (both genuinely
  container/host-specific facts, not storage-model facts). nixstorage's own README says as
  much from its side: "a container's mount TABLE is not [nixstorage's job] ... [it] should
  read a category BY NAME from `nixstorage.delivery.categories` rather than restating a host
  path" — this repo is the consumer that sentence describes.
- **vs. `nixiam` — nixlxc never owns uid/gid.** `idmap.base` names an identity in
  `nixiam.posix.identities`; this repo never allocates, invents, or holds a raw uid/gid of its
  own beyond a range SIZE (`idmap.count`, not an identity fact at all).
- **vs. `nixshare` — nixlxc never exports anything over a network.** A category with
  `mount = "nfs"` is a fact for a client-side mount module; this repo only ever binds a
  category's already-resolved `source` locally, into a container's own mount namespace.

## What ships

- **`lxc-host`** (`nixosModules.lxc-host`) — the LXC host stance: liblxc enabled, the declared
  `lxcpath`, the upstream autostart pass wired up.
- **`containers`** (`nixosModules.containers`) — container definitions as data, rendered to a
  real liblxc `.config` document and kept materialized. Always composed alongside `lxc-host` —
  see its own README for why that composition is required, not just conventional.
- **`nixosModules.default`** — both together, for the common case.
- **`lib.mkContainerConfig`** — the pure config-rendering function `containers` is built on,
  exposed for inspection or reuse without a NixOS evaluation (mirrors nixvm exposing its own
  `lib.mkDomainXML`).

## Status

**First cut, freshly built — a clean slate, not a migration.** No LXC state survives from any
earlier era; this repo starts from an idle liblxc stack with nothing defined on top of it. `nix
flake check` proves both modules compose into a real NixOS system and render a correct liblxc
`.config` from typed container data — and, just as deliberately, that a host missing its
required `containersPath`, a container missing its rootfs or memory allocation, an unresolved
`deliver` category (once `nixstorage.delivery.categories` is actually declared), and an
unresolved `idmap.base` (declared or not) all fail evaluation by name rather than producing
something half-formed — while an unresolved `deliver` name on a host that has never declared
`nixstorage` at all stays completely silent, on purpose (see `modules/containers/README.md`).
**It hosts a real container now.** corbet-server's arch desktop LXC -- a privileged, GPU-bearing,
USB- and audio-passthrough workstation container with fourteen device binds, a twenty-two-rule
deny-by-default cgroup policy and fourteen dataset-backed mounts -- is declared entirely through
these options and rendered by this module. It uses **no `extraConfig` at all**, which is the
sharpest statement available about whether the option surface is complete: an escape hatch that
nothing reaches for is a boundary that holds.

That adoption is also where most of this repo's sharper edges came from, and they are written up
in [`studies/adopting-a-live-container.md`](studies/adopting-a-live-container.md) rather than
left as folklore -- an immutable selector that makes adoption and replacement different acts, a
probe merge that silently produces an invalid object, and device majors that no amount of
declaring can stabilise.

## License

[MIT License](LICENSE) &copy; 2026 Julian Corbet
