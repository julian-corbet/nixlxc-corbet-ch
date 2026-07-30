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
# THIS IS THE MODULE THE WHOLE REPO EXISTS FOR. The legacy implementation this design replaces
# (`infra/lib/render-storage.nix`, private, not ported here on purpose -- see the repo README's
# "What nixlxc replaces") was a pure string-rendering function that emitted literal
# `lxc.mount.entry` lines with host paths HARDCODED as string literals, re-typing facts already
# declared once elsewhere. `deliver` below fixes that: it takes CATEGORY NAMES, resolved
# against `nixstorage.delivery.categories`, and an unresolved name is a build error -- something
# the legacy string-rendering function had no way to detect at all, typo or not.
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
{ lib, config, options, pkgs, ... }:

let
  cfg = config.nixlxc.containers;
  lxcConfigLib = import ../../lib/lxc-config.nix { inherit lib; };

  # ── nixstorage.delivery.categories: read defensively, never imported ───────────────────────
  # Mirrors nixstorage's own `modules/disks.nix`/`modules/reconciler.nix` convention for
  # `nixid.posix` (now `nixiam.posix`) exactly: `config.nixstorage.delivery.categories or { }`
  # so importing this module WITHOUT nixstorage evaluates fine as long as no container's
  # `deliver` list is non-empty. `nixstorageDeliveryDeclared` gates the ONE assertion that
  # would otherwise fire on every such host -- see `deliverAssertions` below for exactly what
  # it does and does not catch, and the repo README's "What nixstorage absence really means"
  # for the reasoning stated once, in full.
  nixstorageDeliveryDeclared = options ? nixstorage && (options.nixstorage ? delivery) && (options.nixstorage.delivery ? categories);
  deliveryCategories = config.nixstorage.delivery.categories or { };
  availableCategories = if deliveryCategories == { } then "(none declared)" else lib.concatStringsSep ", " (lib.attrNames deliveryCategories);

  # ── nixiam.posix.identities: read defensively, never imported ──────────────────────────────
  # Same idiom, one repo over. Unlike `deliver` above, an `idmap.base` that fails to resolve is
  # ALWAYS a build error once a container actually sets it (see `idmapAssertions` below) --
  # there is no "silent when nixiam is absent" carve-out here, because the failure mode is not
  # "a mount is missing" (nixstorage's case, a safe empty default) but "a container silently
  # stays MORE privileged than declared", which must never pass quietly. This mirrors
  # `nixstorage.reconciler`'s own `posixDeclared` gate: it too always asserts once a name is
  # actually referenced, present or not, and only varies the HINT in its message.
  nixiamPosixDeclared = options ? nixiam && (options.nixiam ? posix) && (options.nixiam.posix ? identities);
  posixIdentities = config.nixiam.posix.identities or { };
  availableIdentities = if posixIdentities == { } then "(none declared)" else lib.concatStringsSep ", " (lib.attrNames posixIdentities);

  # Mirrors nixiam.posix's own private `resolvedGid` (modules/posix.nix): an unset `gid` is a
  # User Private Group, numerically equal to `uid`. Duplicated here rather than imported --
  # three lines of pure arithmetic on a value this module already has in hand, not worth a
  # cross-repo function-sharing mechanism neither repo otherwise needs (same reasoning
  # nixstorage's own `reconciler.nix` gives for its identical duplication).
  identGid = ident: if ident.gid == null then ident.uid else ident.gid;

  notImportedHint = ''

    nixiam's posix module does not appear to be imported into this configuration at all
    (checked via options.nixiam.posix.identities). Either import it alongside nixlxc, or
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

      extraConfig = lib.mkOption {
        type = lib.types.lines;
        default = "";
        description = ''
          Escape hatch: raw liblxc config lines appended verbatim, for anything this first cut
          doesn't model as its own option (network/veth attachment, device passthrough, extra
          cgroup rules, and so on all belong here until/unless they earn a dedicated option --
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
  # An earlier draft of this module declared `limits.memoryMiB` (required) and `limits.cpuCores`
  # (default 2) of its own. That is a fact with two owners: `nixhost` already declares
  # `environments.<name>.resources.ram.limitMiB` and `.cpu.quotaCores`, and it owns the only
  # arithmetic nothing else can do -- summing every environment's claim at each level of the
  # tree and refusing to evaluate when a node's children claim more than that node has.
  #
  # A second ceiling here does not merely duplicate; it DISARMS that check. nixhost would go on
  # summing numbers nobody rendered while this module rendered different ones, which is worse
  # than having no assertion at all, because it reads as coverage. nixhost's own substrate
  # contract states the rule: a substrate must not declare a second resource envelope.
  #
  # Matched BY NAME: `nixlxc.containers.<name>` reads
  # `nixhost.environments.<name>.resources`. Read defensively and never as a flake input, so a
  # host that has never imported nixhost still evaluates.
  #
  # Absent nixhost, or an environment nixhost does not declare, renders NO cgroup ceiling. That
  # is deliberate and it is not a silent downgrade: an unbounded container is liblxc's own
  # default, and `null` already means exactly "no enforced limit" in nixhost's vocabulary. The
  # asymmetry with `idmap` below is intentional -- an unbounded container is an ordinary
  # configuration, whereas a silently-more-privileged one never is.
  hostEnvs = config.nixhost.environments or { };
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
      let declared = (hostEnvs.${name} or { }).kind or null; in
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
        assertion = config.nixlxc.host.enable;
        message = ''
          nixlxc.containers defines at least one container, but nixlxc.host.enable is false. A
          container needs a host to run on -- import modules/lxc-host alongside
          modules/containers and set nixlxc.host.enable = true.
        '';
      }
    ] ++ requiredFieldAssertions ++ deliverAssertions ++ idmapAssertions ++ kindAssertions;

    environment.etc = lib.mapAttrs'
      (name: _: {
        name = "nixlxc/containers/${name}.config";
        value.text = renderedConfigFor name;
      })
      cfg;

    systemd.services = lib.mapAttrs'
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
      cfg;
  };
}
