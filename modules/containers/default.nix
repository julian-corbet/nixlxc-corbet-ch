# modules/containers/default.nix
#
# Container DEFINITIONS, as data: `nixlxc.containers.<name>` names what a container is made of
# (`rootfs`), what it's allowed to run as (`idmap`), how big it's allowed to get (`limits`),
# whether it starts with the host (`autostart`), and WHICH delivery categories it receives
# (`deliver`) -- never a host path. This module owns rendering all of that into a real liblxc
# `.config` document and keeping that file materialized at its canonical `lxcpath` location on
# every activation. It never runs `lxc-start`/`lxc-stop` itself -- see "What 'kept applied'
# means" below, the same "declare, don't force" discipline nixvm's own `modules/guests`
# applies to `virsh define`.
#
# THIS IS THE MODULE THE WHOLE REPO EXISTS FOR: `deliver` below takes CATEGORY NAMES, resolved
# against `nixstorage.delivery.categories`, rather than a host path hardcoded as a string
# literal -- an unresolved name is a build error, never a silently-dropped mount.
#
# SCOPE -- what this module owns, so no knob has two managers:
#   OWNED : the per-container rootfs/idmap/limits/autostart/deliver data model; resolving
#           `deliver` entries against `nixstorage.delivery.categories` (defensively -- see
#           below) and `idmap.base` against `nixiam.posix.identities` (also defensively);
#           rendering all of that to a real liblxc `.config` document (`lib/lxc-config.nix`)
#           and keeping that document materialized at `nixlxc.host.containersPath`/<name>/config
#           on every activation.
#   NOT   : starting, stopping, or restarting a container. Materializing a `.config` file only
#           changes what a container WILL boot into next time something starts it -- it never
#           touches a container that is already running. Powering a container on or off is
#           always an operator action (`systemctl start lxc@<name>`, `lxc-start`/`lxc-stop`), or
#           the upstream `lxc.service` autostart pass this module's `autostart` flag feeds (see
#           modules/lxc-host's own header) -- never something a `nixos-rebuild switch` does on
#           this module's behalf.
#   NOT   : which datasets exist, or what shape they take -- `nixstorage.shape`'s job entirely.
#           This module only ever reads a category's already-resolved `source` path; it never
#           declares one.
#   NOT   : exporting anything over a network. A category with `mount = "nfs"` describes a fact
#           for a client-side mount module (nixshare); this module only ever binds a category's
#           `source` path locally, into a container's own mount namespace.
#   NOT   : owning uid/gid. `idmap.base` NAMES an identity in `nixiam.posix.identities`; this
#           module never invents, allocates, or holds a raw uid/gid of its own beyond the
#           `count` (a range SIZE, not an identity fact).
#   NOT   : network attachment (a veth device, a bridge). No option surface for it in this
#           first cut -- the task this module was built to close is `deliver`/`idmap`
#           correctness, not a complete container definition. Attach one via `extraConfig`
#           until it earns a dedicated option (mirrors nixvm's own escape hatch, and its
#           "installer media" non-goal: named honestly rather than silently assumed away).
#
# ── WHAT "KEPT APPLIED" MEANS FOR AN LXC CONTAINER, PRECISELY ───────────────────────────────
# libvirt has a real, separate "declare" verb (`virsh define`) independent of whether a guest
# is running. liblxc has no equivalent: a container's `.config` file, sitting at
# `<lxcpath>/<name>/config`, IS its definition -- `lxc-start` simply reads whatever is there
# the moment it runs. So the honest analogue of "kept declared" here is narrower and more
# literal: this module renders the container's config as NixOS-managed data
# (`environment.etc."nixlxc/containers/<name>.config"`) and a per-container systemd oneshot
# materializes that exact text at the real path liblxc reads, ordered to run before the
# upstream `lxc.service` autostart pass (see modules/lxc-host) and on every activation
# otherwise. This oneshot only ever writes ONE file -- `<lxcpath>/<name>/config` -- and never
# touches `<lxcpath>/<name>/rootfs` or any other data a container owns. Creating the
# container's own `<lxcpath>/<name>/` directory the first time this runs is the same kind of
# narrowly-scoped, this-container-only side effect as `nixvm`'s render of a domain XML file:
# it is not shared infrastructure the way a bridge or a storage pool is (see nixvm's own
# `vm-host` SCOPE block for that boundary) -- nothing else has any claim on it.
{ probeFact, collectProbes }:
{ lib, config, pkgs, ... }:

let
  cfg = config.nixlxc.containers;
  lxcConfigLib = import ../../lib/lxc-config.nix { inherit lib; };

  # ── nixstorage.delivery.categories: read through lib.probeFact, never imported ─────────────
  # An OPTIONS-TREE check (`options ? nixstorage && (options.nixstorage ? delivery) && ...`)
  # cannot tell "nixstorage is not composed here" from "nixstorage IS composed but
  # `delivery.categories` moved or was renamed underneath this exact read": both would land on
  # `nixstorageDeliveryDeclared = false`, silently disarming `deliverAssertions` below in the
  # second case too -- exactly the defect class `lib.probeFact` exists to close (see
  # `lib/facts.nix`'s own header). `probe.state` answers "is nixstorage composed" from `config`,
  # not from a fragile per-leaf options-tree walk, and a genuine rename additionally produces a
  # warning (`config.warnings` below) even on a host where no container currently references
  # `deliver` at all -- the case a value-consuming assertion can never catch because nothing
  # forces it to look.
  nixstorageCategoriesProbe = probeFact {
    inherit config;
    namespace = "nixstorage.delivery";
    path = [ "categories" ];
    fallback = { };
  };
  nixstorageDeliveryDeclared = nixstorageCategoriesProbe.state != "absent";
  deliveryCategories = nixstorageCategoriesProbe.value;
  availableCategories = if deliveryCategories == { } then "(none declared)" else lib.concatStringsSep ", " (lib.attrNames deliveryCategories);

  # ── nixiam.posix.identities: read through lib.probeFact, never imported ───────────────────
  # Same idiom, one repo over. Unlike `deliver` above, an `idmap.base` that fails to resolve is
  # ALWAYS a build error once a container actually sets it (see `idmapAssertions` below) --
  # there is no "silent when nixiam is absent" carve-out here, because the failure mode is not
  # "a mount is missing" (nixstorage's case, a safe empty default) but "a container silently
  # stays MORE privileged than declared", which must never pass quietly. `nixiamPosixDeclared`
  # comes from `probe.state`, not an options-tree walk, for the same reason as the nixstorage
  # probe above: an options-tree walk would report "nixiam not imported" even when nixiam WAS
  # imported and only `posix.identities` had moved, a wrong message pointing at the wrong fix.
  nixiamPosixProbe = probeFact {
    inherit config;
    namespace = "nixiam.posix";
    path = [ "identities" ];
    fallback = { };
  };
  nixiamPosixDeclared = nixiamPosixProbe.state != "absent";
  posixIdentities = nixiamPosixProbe.value;
  availableIdentities = if posixIdentities == { } then "(none declared)" else lib.concatStringsSep ", " (lib.attrNames posixIdentities);

  # Mirrors nixiam.posix's own private `resolvedGid` (modules/posix.nix): an unset `gid` is a
  # User Private Group, numerically equal to `uid`. Duplicated here rather than imported --
  # three lines of pure arithmetic on a value this module already has in hand, not worth a
  # cross-repo function-sharing mechanism neither repo otherwise needs (same reasoning
  # nixstorage's own `reconciler.nix` gives for its identical duplication).
  identGid = ident: if ident.gid == null then ident.uid else ident.gid;

  notImportedHint = ''

    nixiam does not appear to be composed into this configuration at all (checked via
    lib.probeFact against the `nixiam` namespace). Either import it alongside nixlxc, or
    leave idmap.base unset to keep this container privileged, with no idmap at all.'';

  idmapType = lib.types.submodule {
    options = {
      base = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "container-base";
        description = ''
          Name in `nixiam.posix.identities` this container's uid/gid 0 maps to on the HOST.
          `null` (the default) means NO idmap at all -- a privileged container, container
          root == host root, the same shared-init-userns posture this family's own legacy
          deployment used deliberately for its one real desktop LXC. Setting this turns the
          container unprivileged: its own uid/gid range `0..count-1` is remapped to
          `<resolved uid/gid>..<+count-1>` on the host.

          NEVER a raw uid: this field only accepts a NAME, resolved against
          `nixiam.posix.identities.<name>.uid`/`.gid` -- the same "a name has an owner, a raw
          number does not" reasoning `nixstorage.reconciler`'s own `leaves.<path>.identity`
          applies for the identical reason (see that option's own description in nixstorage).
          An unresolved name is ALWAYS a build error the moment this is set to anything other
          than `null` -- regardless of whether `nixiam` is even imported (unlike `deliver`
          below, whose failure mode is a merely-missing mount; a silently-more-privileged
          container must never pass quietly). See this module's own header for that asymmetry
          stated in full.
        '';
      };

      count = lib.mkOption {
        type = lib.types.ints.positive;
        default = 65536;
        description = ''
          Size of the uid/gid range mapped from container-side `0` to the host base `idmap.base`
          resolves to -- `65536` (a full 16-bit id space) is the conventional LXC/LXD default
          and enough for any container that doesn't itself run a nested unprivileged container.
          Not resolved from `nixiam.posix` -- a range SIZE is not a uid/gid fact, only the base
          is.
        '';
      };
    };
  };

  containerType = lib.types.submodule {
    options = {
      rootfs.path = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "/var/lib/nixlxc/roots/example";
        description = ''
          Absolute host directory backing this container's `/` (liblxc's `dir:` rootfs mode --
          the only mode this first cut models; a zvol-backed or image-backed rootfs is future
          scope, same "declared honestly as absent, not silently half-built" stance as this
          module's other non-goals). NO DEFAULT: which directory (and which filesystem/dataset
          backs it) is a fact about this specific container, never a value worth guessing --
          same reasoning as nixvm's own `disks.<dev>.source`. nixlxc never creates, populates,
          or formats this directory; it must already exist.
        '';
      };

      initCmd = lib.mkOption {
        type = lib.types.str;
        default = "/sbin/init";
        description = ''
          What liblxc executes as PID 1 inside the container (`lxc.init.cmd`). The default is
          right for a full-system rootfs that boots its own init/systemd; point this at a single
          binary instead for an application container that runs one process and exits when it
          does.
        '';
      };

      deliver = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "media" "work" ];
        description = ''
          Names into `nixstorage.delivery.categories` -- NEVER a host path. Each resolved
          category's `source` is recursive-bind-mounted into this container at `/<home>`
          (the category's own `home` leaf, mounted at the container's filesystem ROOT -- see
          `lib/lxc-config.nix`'s own header for why a container gets no other notion of
          "home"). This is the whole point of this module's redesign over the legacy
          string-rendering implementation it replaces: a category name that does not exist in
          `nixstorage.delivery.categories` is a BUILD ERROR (see `deliverAssertions` below),
          never a silently-dropped mount -- something the legacy implementation, which
          hardcoded host paths as string literals with nothing to check them against, had no
          way to catch at all.

          What happens when `nixstorage` is not imported at all (its `delivery.categories`
          option does not even exist): every name here resolves to nothing, SILENTLY -- no
          mount is rendered for it, and no assertion fires. This is deliberate, not a gap: a
          cross-repo assertion that fails every host which has not yet adopted `nixstorage`
          would never be adoptable incrementally (see this module's own header comment on
          `nixstorageDeliveryDeclared`, and the repo README's "What nixstorage absence really
          means" for the full reasoning). The moment `nixstorage`'s delivery module IS
          imported, every name here is checked for real.
        '';
      };

      idmap = lib.mkOption {
        type = idmapType;
        default = { };
        description = "This container's uid/gid mapping. See `idmap.base`'s own description for the privileged-by-default posture and why an unresolved name always fails the build.";
      };

      autostart = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Whether this container is started automatically at HOST boot, via the upstream
          `lxc.service`/`lxc-autostart` pass `nixlxc.host` wires up (never a bespoke mechanism
          of this module's own -- see modules/lxc-host's own header). Off by default: a
          newly-declared container should not silently start running before an operator has
          actually looked at it, the same reasoning nixvm's own `guests.<name>.autostart`
          states for libvirt's identical autostart flag.
        '';
      };

      arch = lib.mkOption {
        type = lib.types.str;
        default = "linux64";
        example = "linux32";
        description = ''
          The personality liblxc sets for the container (`lxc.arch`). `linux64` is right for every
          64-bit rootfs on a 64-bit host, which is why it is the default rather than a value a
          caller has to look up. It exists as an option because a 32-bit rootfs on a 64-bit host is
          a real and unremarkable thing, and until this was declarable that container simply could
          not be described here.
        '';
      };

      network = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule {
          options = {
            type = lib.mkOption {
              type = lib.types.str;
              default = "veth";
              description = "liblxc's `lxc.net.<n>.type`. `veth` is the pair-and-bridge shape almost every container wants.";
            };
            link = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              example = "br0";
              description = ''
                The HOST bridge this interface attaches to. NO DEFAULT and never guessed: which
                bridge exists, and what is on the other side of it, is a fact about the host's
                network that this module has no way to know and no business inventing.
              '';
            };
            up = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = ''
                Whether liblxc brings the interface up at start (`flags = up`). True by default
                because an interface declared and left down is almost always a mistake rather than
                a choice, and the failure it produces -- a container that starts fine and simply
                has no network -- is a quiet one.
              '';
            };
            name = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              example = "eth0";
              description = "The interface's name INSIDE the container. Left unset, liblxc picks one.";
            };
            hwaddr = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              example = "00:16:3e:00:00:01";
              description = ''
                A fixed MAC. Worth setting whenever anything off-box identifies this container by
                it -- a DHCP reservation, a router's host table, a switch port policy. Unset, liblxc
                generates a fresh one at every start, and every one of those identifications breaks
                silently the next time the container is restarted.
              '';
            };
          };
        });
        default = [ ];
        description = ''
          The container's network interfaces, in order. The INDEX in liblxc's key
          (`lxc.net.0.*`, `lxc.net.1.*`) is taken from list position, so it is never written by
          hand -- it is the one part of that key nothing can check, and a duplicated or skipped
          index is a config liblxc reads differently from how it looks.

          Empty (the default) renders no network keys at all, which is liblxc's own "inherit the
          host's namespace" behaviour and a deliberate, valid state rather than a missing value.
        '';
      };

      capabilities.drop = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "sys_module" "sys_time" "sys_boot" ];
        description = ''
          Capabilities dropped from the container (`lxc.cap.drop`), written without the `CAP_`
          prefix exactly as liblxc reads them.

          THIS MATTERS MOST FOR A PRIVILEGED CONTAINER, where it is close to the only lever there
          is: with no idmap, the container's root IS the host's root, so a capability left in place
          is a capability over the HOST. `sys_module` loads host kernel modules, `sys_time` sets the
          host clock, `sys_boot` reboots the host. Dropping what a container has no use for costs it
          nothing and removes those outright.

          Empty by default, because which capabilities a given workload actually needs is a fact
          about that workload -- a list guessed here would either break containers or be security
          theatre.
        '';
      };

      autodev = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Whether liblxc mounts a fresh tmpfs `/dev` and populates it at every start
          (`lxc.autodev = 1`).

          THE CONSEQUENCE WORTH KNOWING BEFORE SETTING IT: because that `/dev` is rebuilt from
          scratch each time, anything created there by hand -- a `mknod` for a device node the
          container needs -- is gone at the next start, and the container comes up subtly broken
          rather than failing. Device nodes belong in `mounts` below, bound in from the host, where
          they survive the rebuild.
        '';
      };

      hooks.preStart = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "/var/lib/nixlxc/hooks/example-guard.sh";
        description = ''
          Absolute path to a HOST executable liblxc runs before the container starts
          (`lxc.hook.pre-start`). A non-zero exit refuses the start, which is what makes this the
          right place for a precondition the container cannot check from inside itself -- most
          usefully that its rootfs's backing filesystem is actually mounted.

          That precondition is not hypothetical: a container whose rootfs directory exists but whose
          dataset is NOT mounted starts perfectly and writes into the empty mountpoint underneath,
          so the data goes somewhere nobody looks and the real filesystem silently diverges. A
          pre-start guard is the only place to catch it, because by the time anything inside is
          running the wrong directory is already `/`.

          nixlxc does not write, install or validate the script -- it is a host artifact with its
          own lifecycle, and pointing at one that is missing is a start-time failure, not an
          eval-time one.
        '';
      };

      devices = {
        denyAll = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Emit `lxc.cgroup2.devices.deny = a` -- deny every device, so that `devices.allow` below
            is the container's COMPLETE list rather than an addition to whatever it could already
            reach.

            WITHOUT THIS, AN ALLOWLIST IS DECORATION. liblxc's default is to permit, so a config
            carrying only `allow` lines reads like a restriction while restricting nothing. Turning
            it on is what converts the list below from a description into a boundary.

            The renderer always prints the deny BEFORE the allows, because the cgroup2 filter is
            evaluated in order and an allowlist printed first never applies. That ordering is not a
            caller's to get wrong.
          '';
        };

        allow = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [ "c 1:3 rwm" "c 136:* rwm" ];
          description = ''
            Device rules the container may use, each written in the kernel's own
            `<type> <major>:<minor> <perms>` form and passed through verbatim.

            NOT A PATH LANGUAGE, and the distinction bites: cgroup v2's device filter is a kernel
            ABI keyed on MAJOR:MINOR, so there is no by-path form and no way to say "whatever device
            is at this symlink". A `mounts` entry can follow a stable `/dev/disk/by-path` symlink to
            whichever device currently sits there; the matching rule here cannot, and must be kept
            correct by hand. When a host renumbers, the mount still binds the right hardware while
            the rule may deny the very node just bound -- and the device disappears with nothing
            logged.

            A rule granting only `m` (for example `c *:* m`) grants MKNOD and nothing else: the
            right to create a node, never to open one. That is what `autodev` needs to populate a
            fresh `/dev`, and it weakens nothing, because a node created for a major the container
            may not open is still unopenable.
          '';
        };
      };

      mounts = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule {
          options = {
            source = lib.mkOption {
              type = lib.types.str;
              example = "/dev/net/tun";
              description = "The HOST path, or the filesystem name for a virtual mount (`tmpfs`).";
            };
            target = lib.mkOption {
              type = lib.types.str;
              example = "dev/net/tun";
              description = ''
                Where it lands inside the container. liblxc reads this as container-RELATIVE; a
                leading "/" is stripped rather than refused, so either spelling works.
              '';
            };
            fsType = lib.mkOption {
              type = lib.types.str;
              default = "none";
              example = "tmpfs";
              description = "`none` for a bind of something that already exists; a real filesystem name for a virtual mount.";
            };
            options = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ "bind" "create=file" ];
              example = [ "rbind" "create=dir" "optional" ];
              description = ''
                Mount options, joined with commas in liblxc's own fourth field.

                THE THREE THAT DECIDE BEHAVIOUR HERE:
                `bind` vs `rbind` -- `rbind` carries filesystems mounted UNDERNEATH the source along
                with it. For a source that hides further mounts (a dataset with mounted children, a
                device class directory), a plain `bind` silently delivers an emptier tree than the
                one that was asked for.
                `create=file` vs `create=dir` -- liblxc will not create a mountpoint it was not told
                the shape of, and getting it wrong fails the start rather than guessing.
                `optional` -- the container still starts when the source is absent. Right for
                hardware that may not be present; wrong for anything the workload needs, where a
                loud failure to start beats a container that comes up missing a device.
              '';
            };
          };
        });
        default = [ ];
        description = ''
          Mount entries stated outright, for everything `deliver` above does not cover: host device
          nodes, class directories, a read-only tmpfs laid over a path that must not be reachable.

          SEPARATE FROM `deliver` ON PURPOSE. A delivered mount is RESOLVED -- a category name is
          looked up in `nixstorage.delivery.categories` and a wrong name is a build error. An entry
          here is a raw host fact this module cannot check for you: nothing verifies the source
          exists, and nothing can. Two different authorities, so two different options, rather than
          one that is checked in some cases and not in others.
        '';
      };

      extraConfig = lib.mkOption {
        type = lib.types.lines;
        default = "";
        description = ''
          Escape hatch: raw liblxc config lines appended verbatim, for anything this module
          doesn't model as its own option (see the options above for what it now does --
          mirrors nixvm's own `guests.<name>.extraDomainXML`).
        '';
      };
    };
  };

  # ── resolve `deliver`: unknown names, and the mounts that DO resolve ────────────────────────
  unknownDeliverFor = name: lib.filter (n: !(deliveryCategories ? ${n})) cfg.${name}.deliver;

  resolvedMountsFor = name: lib.filter (m: m != null) (map
    (n:
      if deliveryCategories ? ${n}
      then { source = deliveryCategories.${n}.source; target = deliveryCategories.${n}.home; }
      else null)
    cfg.${name}.deliver);

  deliverAssertions = lib.concatMap
    (name:
      let unknown = unknownDeliverFor name; in
      lib.optional (nixstorageDeliveryDeclared && unknown != [ ]) {
        assertion = false;
        message = ''
          nixlxc.containers.${name}.deliver references categor${if lib.length unknown == 1 then "y" else "ies"} not found in
          nixstorage.delivery.categories: ${lib.concatStringsSep ", " unknown}.
          Declared categories: ${availableCategories}.

          `deliver` accepts ONLY a category name, never a host path -- so an unresolved name is
          always a build error, never a silently-dropped mount. This is the exact gap the
          legacy string-rendering implementation this module replaces could not detect at all
          (see this file's own header).
        '';
      })
    (lib.attrNames cfg);

  # ── resolve `idmap.base`: ALWAYS required to resolve once set, present or not ───────────────
  idmapBaseUnresolvedFor = name: cfg.${name}.idmap.base != null && !(posixIdentities ? ${cfg.${name}.idmap.base});

  idmapAssertions = lib.concatMap
    (name:
      lib.optional (idmapBaseUnresolvedFor name) {
        assertion = false;
        message = ''
          nixlxc.containers.${name}.idmap.base = "${cfg.${name}.idmap.base}" is not a name in
          nixiam.posix.identities. Declared identities: ${availableIdentities}.${lib.optionalString (!nixiamPosixDeclared) notImportedHint}
        '';
      })
    (lib.attrNames cfg);

  resolvedIdmapFor = name:
    let base = cfg.${name}.idmap.base; in
    if base == null then null
    else if posixIdentities ? ${base} then
      let ident = posixIdentities.${base}; in
      { hostUidBase = ident.uid; hostGidBase = identGid ident; count = cfg.${name}.idmap.count; }
    else null; # unresolved -- idmapAssertions above fails the build before this is ever rendered for real

  # ── EVAL SAFETY, same discipline as nixvm's own modules/guests: `rootfs.path` has NO safe
  # default (see its own option doc), which means its
  # value can legitimately be `null` while NixOS is still forcing `config` on the way to
  # `system.build.toplevel` -- independent of, and possibly before, whichever order
  # `assertions` happens to be checked in. Indexing either directly would raise a raw,
  # unhelpful Nix type error instead of this module's own friendly, container-named assertion
  # below. Neither fallback is ever seen by a real user, because `assertions` is what actually
  # stops the build.
  effectiveRootfsPath = name: if cfg.${name}.rootfs.path != null then cfg.${name}.rootfs.path else "/unset-rootfs-path";
  # ── The resource envelope is NOT declared here. It is read from nixhost. ──────────────────
  #
  # Declaring `limits.memoryMiB`/`limits.cpuCores` here would be a fact with two owners: `nixhost`
  # already declares `environments.<name>.resources.ram.limitMiB` and `.cpu.quotaCores`, and it
  # owns the only arithmetic nothing else can do -- summing every environment's claim at each
  # level of the tree and refusing to evaluate when a node's children claim more than that node
  # has.
  #
  # A second ceiling here does not merely duplicate; it DISARMS that check. nixhost would go on
  # summing numbers nobody rendered while this module rendered different ones, which is worse
  # than having no assertion at all, because it reads as coverage. nixhost's own substrate
  # contract states the rule: a substrate must not declare a second resource envelope.
  #
  # Matched BY NAME: `nixlxc.containers.<name>` reads
  # `nixhost.environments.<name>.resources`. Read through `lib.probeFact` (the CONFIG namespace
  # `nixhost` is probed defensively -- never `imports`ed -- exactly as before) rather than a bare
  # `config.nixhost.environments or { }`: the bare form cannot tell "nixhost not imported here"
  # from "nixhost IS imported but `environments` itself moved or was renamed", and the second one
  # is the exact defect class this file's other two probes above close. A host that has never
  # imported nixhost still evaluates either way; the difference is that a rename now warns
  # (`config.warnings` below) instead of silently behaving as if nixhost were never imported at
  # all. NOTE: this repo's flake takes nixhost as a flake input (see flake.nix) only to consume
  # its `lib.probeFact`/`lib.collectProbes` mechanism -- the defensive, no-`imports`-required read
  # of `nixhost.environments` described here does not itself depend on that input.
  #
  # Absent nixhost, or an environment nixhost does not declare, renders NO cgroup ceiling. That
  # is deliberate and it is not a silent downgrade: an unbounded container is liblxc's own
  # default, and `null` already means exactly "no enforced limit" in nixhost's vocabulary. The
  # asymmetry with `idmap` below is intentional -- an unbounded container is an ordinary
  # configuration, whereas a silently-more-privileged one never is.
  nixhostEnvironmentsProbe = probeFact {
    inherit config;
    namespace = "nixhost";
    path = [ "environments" ];
    fallback = { };
  };
  hostEnvs = nixhostEnvironmentsProbe.value;

  # Every fact-probe's warnings, folded into the one list `config.warnings` below expects. Only
  # a genuinely COMPOSED-but-unresolved sibling (state "unresolved") ever contributes here --
  # states "absent" and "resolved" are both legitimate and silent, per `lib/facts.nix`'s own
  # header.
  factWarnings = (collectProbes [
    nixstorageCategoriesProbe
    nixiamPosixProbe
    nixhostEnvironmentsProbe
  ]).warnings;
  envelopeFor = name: (hostEnvs.${name} or { }).resources or null;
  effectiveMemoryMiB = name:
    let e = envelopeFor name; in if e == null then null else e.ram.limitMiB;
  effectiveCpuCores = name:
    let e = envelopeFor name; in if e == null then null else e.cpu.quotaCores;
  effectiveContainersPath =
    if config.nixlxc.host.containersPath != null then config.nixlxc.host.containersPath else "/unset-containers-path";

  renderedConfigFor = name: lxcConfigLib.mkContainerConfig {
    inherit name;
    rootfsPath = effectiveRootfsPath name;
    initCmd = cfg.${name}.initCmd;
    mounts = resolvedMountsFor name;
    idmap = resolvedIdmapFor name;
    limits = { memoryMiB = effectiveMemoryMiB name; cpuCores = effectiveCpuCores name; };
    autostart = cfg.${name}.autostart;
    extraConfig = cfg.${name}.extraConfig;

    # The hardware half. Each of these renders nothing when left at its default, so a container
    # that declares none of them is byte-for-byte what this module produced before they existed.
    arch = cfg.${name}.arch;
    network = cfg.${name}.network;
    capsDrop = cfg.${name}.capabilities.drop;
    autodev = cfg.${name}.autodev;
    hooks = cfg.${name}.hooks;
    devices = cfg.${name}.devices;
    entries = cfg.${name}.mounts;
  };

  # ── Cross-check against nixhost: the two declarations must agree on WHAT this is ───────────
  #
  # `nixlxc.containers.foo` and `nixhost.environments.foo` describe the same object from two
  # sides -- the substrate that builds it and the host that budgets for it. If nixhost has been
  # told that `foo` is a VM while this module is building it as an LXC container, one of those is
  # wrong, and the consequence is not cosmetic: nixhost's envelope arithmetic would be budgeting
  # for the wrong KIND of thing, and this module would silently read a ceiling meant for
  # something else.
  #
  # Only checked when nixhost actually declares that name -- a container with no corresponding
  # environment is the ordinary un-adopted case, not an error.
  kindAssertions = lib.concatMap
    (name:
      # ⚠ `or null` IS NOT ENOUGH HERE, and this cost a real bug. nixhost's `kind` option has NO
      # default: it is mandatory, precisely so an unclassifiable environment cannot slip through.
      # So when nixhost declares an environment but its `kind` is unset, reading it does not yield
      # null -- it raises NixOS's "option accessed but has no value defined". The `or` idiom only
      # catches a MISSING ATTRIBUTE; it does not catch a `throw` from an option that exists and has
      # no value. Measured directly: `tryEval (... .kind or null)` returns success = false.
      #
      # Without tryEval, a host that declared an environment and simply had not yet said what kind
      # it was would fail to evaluate with an error pointing at nixhost rather than at the omission.
      let
        declared =
          let r = builtins.tryEval ((hostEnvs.${name} or { }).kind or null);
          in if r.success then r.value else null;
      in
      lib.optional (declared != null && declared != "lxc") {
        assertion = false;
        message = "nixlxc.containers.${name} builds an LXC container, but nixhost.environments.${name}.kind = \"${declared}\". The same name is declared as two different kinds of thing: nixhost is budgeting an envelope for a ${declared} while this module renders an LXC config against it. Rename one, or correct the kind.";
      })
    (lib.attrNames cfg);

  requiredFieldAssertions = lib.concatMap
    (name:
      lib.optional (cfg.${name}.rootfs.path == null)
        {
          assertion = false;
          message = "nixlxc.containers.${name}.rootfs.path must be set -- there is no default (see the option doc); which directory backs a specific container's rootfs is never a value worth guessing.";
        }
)
    (lib.attrNames cfg);
in
{
  options.nixlxc.containers = lib.mkOption {
    type = lib.types.attrsOf containerType;
    default = { };
    description = ''
      Container definitions, one attrset key per container name. Each renders to a real liblxc
      `.config` document kept materialized at `nixlxc.host.containersPath`/<name>/config -- see
      this file's own header for exactly what "kept materialized" does and does not mean.
    '';
  };

  config = lib.mkIf (cfg != { }) {
    assertions = [
      {
        # `runtimeManagedElsewhere` is the second way to satisfy this, and it is a DECLARATION
        # rather than a bypass: it says liblxc is running and somebody else owns it. The refusal
        # below still stands for the case it was written for -- a container declared with no host
        # at all, whose rendered config nothing can ever start.
        assertion = config.nixlxc.host.enable || config.nixlxc.host.runtimeManagedElsewhere;
        message = ''
          nixlxc.containers defines at least one container, but nothing says a host exists to run
          it on -- a rendered .config nothing can start is a declaration with no effect.

          Either let this repository manage the runtime: import modules/lxc-host alongside
          modules/containers and set nixlxc.host.enable = true.

          Or, if liblxc is already running here under some other owner (a bespoke module, a
          foreign-distro plane, an inherited setup being migrated), say so:
          nixlxc.host.runtimeManagedElsewhere = true. That installs nothing at all and leaves the
          container rendering and materialisation to this module while the runtime stays where it
          is. `nixlxc.host.containersPath` is still required either way, because the renderer has
          to know where containers are kept.
        '';
      }
    ] ++ requiredFieldAssertions ++ deliverAssertions ++ idmapAssertions ++ kindAssertions;

    # THE SHARED READ CONTRACT'S OWN OUTPUT: state (c) on any of the three siblings this module
    # reads (nixstorage.delivery.categories, nixiam.posix.identities, nixhost.environments) warns
    # here even when nothing currently references the renamed fact -- see each probe's own
    # comment above, and `checks/default.nix`'s `factWiringResults` for the proof that this fires.
    # THE ONE THING A RENDER-ONLY CONSUMER CAN GET SILENTLY WRONG. With the runtime owned
    # elsewhere this module renders and stops, so nothing here installs the config at the
    # lxcpath. A consumer who sets the flag and assumes otherwise gets a container that starts
    # from whatever file happens to be there and never picks up a change -- no error, no drift
    # report, just a declaration that quietly stops meaning anything. Say it once, at eval,
    # naming both files, rather than leaving it to an option description nobody re-reads.
    warnings = factWarnings
      ++ lib.optional (config.nixlxc.host.runtimeManagedElsewhere && cfg != { } && config.nixlxc.host.materialisedBy == null) ''
        nixlxc: the LXC runtime here is declared as somebody else's
        (nixlxc.host.runtimeManagedElsewhere), so this module RENDERS the container config and
        does NOT install it. Nothing will copy /etc/nixlxc/containers/<name>.config to
        ${effectiveContainersPath}/<name>/config for you -- the runtime's owner must, and only
        the owner can order that correctly (after the storage holding the lxcpath, before
        whatever starts the container). Containers rendered here: ${lib.concatStringsSep ", " (lib.attrNames cfg)}.

        If something already does this, name it in `nixlxc.host.materialisedBy` -- that answers
        the question rather than muting it, and leaves the next reader a pointer to the thing
        doing the work.
      '';

    environment.etc = lib.mapAttrs'
      (name: _: {
        name = "nixlxc/containers/${name}.config";
        value.text = renderedConfigFor name;
      })
      cfg;

    # MATERIALISATION IS OURS ONLY WHEN THE RUNTIME IS OURS.
    #
    # This oneshot orders itself `before = [ "lxc.service" ]` -- the upstream autostart unit this
    # repository's own host module enables. That is correct when we own the runtime and meaningless
    # when we do not: a foreign owner starts its containers from a unit of its own that this module
    # cannot name, so every ordering edge here is a guess, and the guesses were all wrong on the
    # first host to try it. Measured there:
    #
    #   * `lxc.service` did not exist at all, leaving a dangling
    #     /etc/systemd/system/lxc.service.wants/ symlink and no ordering against anything real;
    #   * the unit's only real edge was `After=local-fs.target`, reached at 1.6s, while the pool
    #     holding `containersPath` imported at 227s -- so `install -D` would create the config on
    #     the ROOT dataset and the later mount would occlude it, leaving invisible junk;
    #   * it rewrote the live file AFTER the container had already started from it, so the file on
    #     disk no longer described the running container and nothing could tell.
    #
    # None of that is fixable from in here, because the missing fact -- which unit starts these
    # containers, and what it must be ordered after -- belongs to the owner. So under
    # `runtimeManagedElsewhere` this module renders to `environment.etc` and stops. Materialising
    # from there is the owner's job, and the owner is the only party that can order it correctly
    # (infra's own consumer does it as an ExecStartPre in the very unit that starts the container,
    # which is the one ordering that cannot race).
    systemd.services = lib.optionalAttrs (!config.nixlxc.host.runtimeManagedElsewhere) (lib.mapAttrs'
      (name: _: {
        name = "nixlxc-container-${name}-apply";
        value = {
          description = "Materialize the nixlxc container '${name}' config at its lxcpath location";
          after = [ "local-fs.target" ];
          before = [ "lxc.service" ];
          wantedBy = [ "multi-user.target" "lxc.service" ];
          serviceConfig.Type = "oneshot";
          # `install -D` is idempotent and non-destructive: it only ever writes the single
          # `config` file, and only ever CREATES `<containersPath>/<name>/` the first time --
          # `<containersPath>/<name>/rootfs` (the container's actual filesystem content) is
          # never touched by this unit. See this file's own header for why that narrow,
          # this-container-only side effect is not the same kind of thing nixvm's own SCOPE
          # block warns hosts away from creating (a bridge, a storage pool -- shared
          # infrastructure with other claimants).
          script = ''
            ${lib.getExe' pkgs.coreutils "install"} -Dm0644 \
              /etc/nixlxc/containers/${name}.config \
              ${effectiveContainersPath}/${name}/config
          '';
        };
      })
      cfg);
  };
}
