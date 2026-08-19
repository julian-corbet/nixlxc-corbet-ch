# checks/default.nix
#
# Two kinds of check, cheapest first -- the same split nixvm's own checks/default.nix uses:
#
#   1. "config-render/*" -- pure unit tests against lib/lxc-config.nix directly. No NixOS eval
#      at all: hand-built plain-value fixtures in, a string out, substring assertions on the
#      result. This is the whole reason that file is `lib`-only rather than living inside
#      modules/containers -- see its own header.
#
#   2. Everything else -- EVAL-TIME tests through real `nixosSystem` composition: does a host
#      importing modules/lxc-host (and modules/containers) evaluate at all, does the rendered
#      config/systemd service actually contain what the container declared, and -- the failing
#      direction, proven as deliberately as the passing one -- does a container missing a
#      required field, a host missing its required `containersPath`, an unresolved `deliver`
#      category (when nixstorage IS declared), or an unresolved `idmap.base` (declared or not)
#      all fail evaluation BY NAME rather than silently producing something half-formed. The
#      one case that must stay SILENT -- an unresolved `deliver` name when nixstorage is not
#      declared AT ALL -- gets its own check proving exactly that (see
#      "deliver/silent-when-nixstorage-entirely-absent" below).
#
#   3. "fact-wiring/*" -- proves `lib.probeFact` (consumed from nixhost's own `lib/facts.nix` via
#      this repo's `nixhost` flake input, see flake.nix) actually distinguishes, THROUGH the real
#      `modules/containers` wiring, "sibling not composed" from "sibling composed but the exact
#      leaf this repo reads was renamed" for all
#      three siblings this repo reads (`nixstorage.delivery.categories`, `nixiam.posix.identities`,
#      `nixhost.environments`). The renamed case is the one this whole check group exists for:
#      before this repo adopted `lib.probeFact`, a rename landed in the exact same silent bucket
#      as the sibling never having been imported at all -- see `stub-modules.nix`'s own decoy
#      stubs, and `modules/containers/default.nix`'s own comments on each probe for the defect
#      this closes.
#
# Nothing here builds a container, starts liblxc, or runs a single line of a rendered script.
# That is exactly the boundary this repo exists to keep: nixlxc declares and renders, `nix
# flake check` proves the declaring and rendering, and nothing more.
{ pkgs, lib, system, lxcHostModule, containersModule }:

let
  lxcConfigLib = import ../lib/lxc-config.nix { inherit lib; };
  stubs = import ./stub-modules.nix { inherit lib; };

  check = name: ok: detail: { inherit name ok detail; };

  # ── Stubs every fixture below needs to reach system.build.toplevel ──────────────────
  bootStub = {
    fileSystems."/" = { device = "nodev"; fsType = "tmpfs"; };
    boot.loader.grub = { enable = true; devices = [ "nodev" ]; };
    networking.hostName = "example-lxc-host";
    system.stateVersion = "25.05";
  };

  evalNixos = extraModules:
    (lib.nixosSystem {
      inherit system;
      modules = [ lxcHostModule containersModule bootStub ] ++ extraModules;
    }).config;

  # Mirrors nixvm's own `buildFails`: forcing `system.build.toplevel` is what actually runs
  # `assertions` (a bare read of `.config.assertions` is a passive list nobody enforced yet).
  # `seq` reaches the wrapping throw without deep-forcing, or building, the whole system
  # closure; the string context is discarded so this stays an EVAL check, never a build.
  buildFails = extraModules:
    !(builtins.tryEval (builtins.seq
      (builtins.unsafeDiscardStringContext (evalNixos extraModules).system.build.toplevel.drvPath)
      true)).success;

  # WHAT `buildFails` DOES NOT PROVE: it reports THAT evaluation failed, never why. A check named
  # for one refusal therefore stays green if an unrelated throw takes its place -- rename an option
  # a fixture sets and every refusal check "passes" while testing nothing. That is fine for the
  # structural cases below (where the fixture is one line and the failure has one candidate cause)
  # and not fine for a refusal this module states in its own words, because the message IS the
  # feature. `failsWith` reads the assertion list instead of forcing a derivation, so it can match
  # the text a reader would actually be shown; a fixture that fails for some other reason makes the
  # whole `assertions` read throw, `tryEval` catches it, and the check goes RED rather than green.
  failsWith = infix: extraModules:
    let r = builtins.tryEval
      (lib.any (a: !a.assertion && lib.hasInfix infix a.message)
        (evalNixos extraModules).assertions);
    in r.success && r.value;

  baseHost = {
    nixlxc.host = {
      enable = true;
      containersPath = "/var/lib/nixlxc/containers";
    };
  };

  # ── Fixtures ─────────────────────────────────────────────────────────────────────
  cfg-host-only = evalNixos [ baseHost ];

  # A host whose liblxc runtime belongs to somebody else -- a bespoke module, a foreign-distro
  # plane, an inherited setup. nixlxc renders and materialises the container; it installs nothing.
  externalRuntimeHost = {
    nixlxc.host = {
      runtimeManagedElsewhere = true;
      containersPath = "/var/lib/nixlxc/containers";
    };
  };

  cfg-external-runtime = evalNixos [
    externalRuntimeHost
    { nixlxc.containers.example-container.rootfs.path = "/var/lib/nixlxc/roots/example"; }
  ];

  cfg-one-container = evalNixos [
    baseHost
    {
      nixlxc.containers.example-container = {
        rootfs.path = "/var/lib/nixlxc/roots/example";
      };
    }
  ];

  # ── THE HARDWARE HALF, WIRED THROUGH THE MODULE ────────────────────────────────────────
  # Every option below is one this module hands to lib/lxc-config.nix in `renderedConfigFor`.
  # Until this fixture existed, NO eval fixture declared any of them: the config-render/* group
  # calls the renderer directly and never sees the wiring, so severing a single line of it --
  # `entries = cfg.<name>.mounts` -> `entries = [ ]` -- rendered a container with ZERO mount
  # entries (no /home, no shared /nix, no device nodes) and all 73 checks stayed green.
  #
  # That is this repo's own study finding #6 one layer up: a check that cannot fail on the
  # mutation it is named for. The assertions below are written against the RENDERED TEXT of a
  # container declared through the options, so cutting any wire fails by name.
  cfg-hardware = evalNixos [
    baseHost
    {
      nixlxc.containers.example-container = {
        rootfs.path = "/var/lib/nixlxc/roots/example";
        arch = "linux32";
        autodev = true;
        hooks.preStart = "/example/guard.sh";
        capabilities.drop = [ "sys_module" "sys_boot" ];
        network = [
          { type = "veth"; link = "example-br0"; up = true; name = "eth0"; hwaddr = "00:16:3e:00:00:01"; }
          { type = "veth"; link = "example-br1"; up = false; name = "eth1"; hwaddr = null; }
        ];
        devices = {
          denyAll = true;
          allow = [ "c *:* m" "c 1:3 rwm" "c 226:0 rwm" ];
        };
        mounts = [
          { source = "/dev/example-node"; target = "/dev/example-node"; fsType = "none"; options = [ "bind" "create=file" ]; }
          { source = "tmpfs"; target = "sys/example"; fsType = "tmpfs"; options = [ "ro" "size=4k" "create=dir" ]; }
        ];
      };
    }
  ];

  cfg-container-autostart = evalNixos [
    baseHost
    {
      nixlxc.containers.example-container = {
        rootfs.path = "/var/lib/nixlxc/roots/example";
        autostart = true;
      };
    }
  ];

  # deliver, resolved for real against the delivery stub -----------------------------------
  cfg-deliver-resolved = evalNixos [
    baseHost
    stubs.deliveryStub
    {
      nixstorage.delivery.categories.media = { source = "/example/media"; home = "media"; };
      nixlxc.containers.example-container = {
        rootfs.path = "/var/lib/nixlxc/roots/example";
        deliver = [ "media" ];
      };
    }
  ];

  # deliver, nixstorage entirely ABSENT (no stub imported at all) -- must stay silent -------
  cfg-deliver-nixstorage-absent = evalNixos [
    baseHost
    {
      nixlxc.containers.example-container = {
        rootfs.path = "/var/lib/nixlxc/roots/example";
        deliver = [ "media" ];
      };
    }
  ];

  # idmap, resolved for real against the posix stub ----------------------------------------
  cfg-idmap-resolved = evalNixos [
    baseHost
    stubs.posixStub
    {
      nixiam.posix.identities.container-base = { uid = 100000; };
      nixlxc.containers.example-container = {
        rootfs.path = "/var/lib/nixlxc/roots/example";
        idmap.base = "container-base";
      };
    }
  ];

  # ── uid != gid, which is the only shape that can see a u/g swap ────────────────────────
  # Every other idmap fixture here resolves an identity whose `gid` is unset -- a User Private
  # Group, numerically equal to the uid -- so `lxc.idmap = u ...` and `= g ...` carry the SAME
  # number and swapping the two arguments in the renderer changes nothing observable. That is
  # precisely the failure this repo says must never pass quietly: a container silently more
  # privileged, or differently privileged, than declared.
  cfg-idmap-split = evalNixos [
    baseHost
    stubs.posixStub
    {
      nixiam.posix.identities.example-split = { uid = 100000; gid = 200000; };
      nixlxc.containers.example-container = {
        rootfs.path = "/var/lib/nixlxc/roots/example";
        idmap.base = "example-split";
      };
    }
  ];

  configText = cfg: name: cfg.environment.etc."nixlxc/containers/${name}.config".text;

  # ── fact-wiring fixtures: `lib.probeFact` proven THROUGH the real `modules/containers` ──────
  #
  # A container that references NOTHING from any of the three siblings (no `deliver`, no
  # `idmap.base`) -- so the only thing that could possibly produce a warning or an assertion is
  # the probe itself, never a value-consuming check reacting to an unresolved name.
  quietContainer = {
    nixlxc.containers.example-container = { rootfs.path = "/var/lib/nixlxc/roots/example"; };
  };

  # All three siblings composed with their REAL, faithful shape (the same stubs the tests above
  # already use) -- must produce zero warnings.
  cfg-facts-all-faithful = evalNixos [
    baseHost
    stubs.deliveryStub
    stubs.posixStub
    stubs.hostEnvStub
    quietContainer
  ];

  # None of the three siblings composed at all -- state (a), must also produce zero warnings.
  cfg-facts-none-composed = evalNixos [ baseHost quietContainer ];

  # Each sibling composed under its RENAMED decoy shape -- state (c) -- one at a time, so each
  # check attributes its one warning to the right probe.
  cfg-facts-nixstorage-renamed = evalNixos [
    baseHost
    stubs.nixstorageDeliveryRenamedStub
    quietContainer
  ];

  cfg-facts-nixiam-renamed = evalNixos [
    baseHost
    stubs.nixiamPosixRenamedStub
    quietContainer
  ];

  cfg-facts-nixhost-renamed = evalNixos [
    baseHost
    stubs.nixhostEnvironmentsRenamedStub
    quietContainer
  ];
in
{
  eval-tests =
    let
      results = [
        # --- host-only composes -------------------------------------------------------
        (check "host-only/toplevel-evaluates"
          (builtins.tryEval (builtins.seq (builtins.unsafeDiscardStringContext cfg-host-only.system.build.toplevel.drvPath) true)).success
          "expected a host with nixlxc.host.enable + containersPath set to evaluate cleanly")

        # ── A runtime this module does NOT own ─────────────────────────────────────────
        # The interesting half is what it does NOT install: a host that already runs liblxc
        # under another owner must get rendering and materialisation and nothing else, or the
        # two owners fight over virtualisation.lxc and the winner is decided by merge order.
        (check "external-runtime/container-renders-without-this-module-owning-the-host"
          (lib.hasInfix "lxc.rootfs.path = dir:/var/lib/nixlxc/roots/example"
            (configText cfg-external-runtime "example-container"))
          "the container must still be rendered when the runtime belongs to somebody else")

        # ALL FOUR attributes the `enable` branch sets, not the two that were easiest to reach.
        # A check that covers half of what it is named for lets the other half regress silently:
        # `systemConfig` writes an lxcpath into /etc/lxc/default.conf and `systemd.packages` pulls
        # in the unit file pkgs.lxc ships. NOT `systemd.packages == [ ]` -- base NixOS puts six
        # packages there before this module is even composed, and asserting emptiness tests the
        # baseline rather than the carve-out (it failed exactly that way when first written). The
        # question is whether THIS module's lxc package is among them; either leak would mean
        # this module is quietly co-owning a runtime it has declared belongs to somebody else --
        # exactly the two-owners state the enable/runtimeManagedElsewhere assertion refuses.
        (check "external-runtime/installs-no-liblxc-runtime-of-its-own"
          (!cfg-external-runtime.virtualisation.lxc.enable
            && !(cfg-external-runtime.systemd.services ? lxc)
            && cfg-external-runtime.virtualisation.lxc.systemConfig == ""
            && !(lib.elem cfg-external-runtime.virtualisation.lxc.package
                   cfg-external-runtime.systemd.packages))
          ("declaring the runtime external must install NOTHING: got lxc.enable="
            + builtins.toJSON cfg-external-runtime.virtualisation.lxc.enable
            + ", systemConfig=" + builtins.toJSON cfg-external-runtime.virtualisation.lxc.systemConfig
            + ", lxc package in systemd.packages="
            + builtins.toJSON (lib.elem cfg-external-runtime.virtualisation.lxc.package
                cfg-external-runtime.systemd.packages)))

        # THIS ASSERTED THE OPPOSITE UNTIL 2026-08-19, and the assumption behind it was wrong.
        # Materialising needs an ordering edge -- after the storage holding containersPath, before
        # whatever starts the container -- and under an external runtime this module knows neither.
        # Its guess produced a dangling wants-link on a unit that did not exist, an install ordered
        # only after local-fs.target (1.6s) onto a pool that mounted at 227s, and a rewrite of the
        # live file AFTER the container had started from it. Render, and stop.
        # A warning nobody has watched fire is a comment. Render-only is the one thing a consumer
        # can get silently wrong -- a container that starts from whatever file is there and never
        # picks up a change -- so the warning that says so is pinned in BOTH directions.
        (check "external-runtime/warns-that-the-owner-must-materialise"
          (
            let w = cfg-external-runtime.warnings; in
            lib.length w == 1
            && lib.hasInfix "does NOT install it" (lib.head w)
            && lib.hasInfix "example-container" (lib.head w)
          )
          "warnings: ${builtins.toJSON cfg-external-runtime.warnings} -- expected exactly one, naming the container and saying this module does not install the config")

        (check "external-runtime/naming-what-materialises-answers-the-warning"
          ((evalNixos [
            { nixlxc.host = { runtimeManagedElsewhere = true; containersPath = "/var/lib/nixlxc/containers"; materialisedBy = "example-start.service ExecStartPre"; }; }
            { nixlxc.containers.example-container.rootfs.path = "/var/lib/nixlxc/roots/example"; }
          ]).warnings == [ ])
          "naming the mechanism must answer the question, not merely mute it -- and must not leave the warning firing forever at a consumer doing it right")

        (check "external-runtime/the-ordinary-path-is-NOT-warned-at"
          (cfg-one-container.warnings == [ ])
          "warnings: ${builtins.toJSON cfg-one-container.warnings} -- when this module owns the runtime it materialises, so warning would be noise")

        (check "external-runtime/does-NOT-materialise-because-it-cannot-order-that-correctly"
          (!(cfg-external-runtime.systemd.services ? "nixlxc-container-example-container-apply"))
          "under an external runtime the owner materialises; this module cannot know what to order against")

        (check "external-runtime/but-the-rendered-config-is-still-published-for-the-owner-to-read"
          (cfg-external-runtime.environment.etc ? "nixlxc/containers/example-container.config")
          "render-only still has to PUBLISH, or the owner has nothing to install from")

        # And when the runtime IS ours, the oneshot must still exist -- otherwise this change would
        # have quietly removed materialisation for every ordinary consumer.
        (check "external-runtime/the-oneshot-still-exists-when-this-module-owns-the-runtime"
          (cfg-one-container.systemd.services ? "nixlxc-container-example-container-apply")
          "the ordinary path must be untouched by the external-runtime carve-out")

        # The original refusal still stands for the case it was written for.
        (check "external-runtime/a-container-with-no-host-at-all-is-still-refused"
          (buildFails [
            { nixlxc.host.containersPath = "/var/lib/nixlxc/containers"; }
            { nixlxc.containers.example-container.rootfs.path = "/var/lib/nixlxc/roots/example"; }
          ])
          "neither enable nor runtimeManagedElsewhere: the rendered config could never be started")

        (check "external-runtime/claiming-both-owners-is-refused"
          (failsWith "two owners of one runtime" [
            {
              nixlxc.host = {
                enable = true;
                runtimeManagedElsewhere = true;
                containersPath = "/var/lib/nixlxc/containers";
              };
            }
          ])
          "they are alternatives; both set means which runtime is authoritative is decided by merge order")

        (check "external-runtime/containersPath-is-still-required"
          (failsWith "nixlxc.host.containersPath must be set" [
            { nixlxc.host.runtimeManagedElsewhere = true; }
            { nixlxc.containers.example-container.rootfs.path = "/var/lib/nixlxc/roots/example"; }
          ])
          "the renderer has to know where the other owner keeps its containers")

        # ── The module -> renderer join, per option. Each of these fails if its wire is cut. ──
        # liblxc: a bare  allow rule clears every previous rule, so it does not add a
        # permission -- it discards denyAll and the whole allowlist above it, silently.
        (check "devices/a-bare-allow-everything-rule-is-refused"
          (failsWith "bare allow-everything device rule" [
            baseHost
            { nixlxc.containers.example-container = {
                rootfs.path = "/var/lib/nixlxc/roots/example";
                devices = { denyAll = true; allow = [ "c 1:3 rwm" "a" ]; };
              }; }
          ])
          "a bare a rule clears denyAll and every rule above it, leaving a container that reads as restricted and is not")

        (check "devices/an-ordinary-allowlist-is-still-accepted"
          (!(buildFails [
            baseHost
            { nixlxc.containers.example-container = {
                rootfs.path = "/var/lib/nixlxc/roots/example";
                devices = { denyAll = true; allow = [ "c 1:3 rwm" "c *:* m" ]; };
              }; }
          ]))
          "refusing every allowlist would make the option unusable -- only the bare clear-everything form is wrong")

        (check "idmap/u-and-g-are-not-interchangeable"
          (
            let t = configText cfg-idmap-split "example-container"; in
            lib.hasInfix "lxc.idmap = u 0 100000 " t
            && lib.hasInfix "lxc.idmap = g 0 200000 " t
          )
          "text: ${configText cfg-idmap-split "example-container"} -- a uid base on the g line (or vice versa) gives the container a different privilege set than declared, and every other fixture here has uid == gid so it cannot see the swap")

        (check "hardware/mounts-reach-the-render"
          (
            let t = configText cfg-hardware "example-container"; in
            lib.hasInfix "lxc.mount.entry = /dev/example-node dev/example-node none bind,create=file 0 0" t
            && lib.hasInfix "lxc.mount.entry = tmpfs sys/example tmpfs ro,size=4k,create=dir 0 0" t
          )
          "text: ${configText cfg-hardware "example-container"}")

        (check "hardware/network-reaches-the-render-indexed-by-position"
          (
            let t = configText cfg-hardware "example-container"; in
            lib.hasInfix "lxc.net.0.type = veth" t
            && lib.hasInfix "lxc.net.0.link = example-br0" t
            && lib.hasInfix "lxc.net.0.flags = up" t
            && lib.hasInfix "lxc.net.0.name = eth0" t
            && lib.hasInfix "lxc.net.0.hwaddr = 00:16:3e:00:00:01" t
            && lib.hasInfix "lxc.net.1.link = example-br1" t
            && !(lib.hasInfix "lxc.net.1.flags" t)
          )
          "text: ${configText cfg-hardware "example-container"}")

        (check "hardware/devices-reach-the-render-deny-first"
          (
            let t = configText cfg-hardware "example-container";
                parts = lib.splitString "lxc.cgroup2.devices.deny = a" t; in
            lib.length parts == 2
            && lib.hasInfix "lxc.cgroup2.devices.allow = c 1:3 rwm" (lib.elemAt parts 1)
            && lib.hasInfix "lxc.cgroup2.devices.allow = c 226:0 rwm" (lib.elemAt parts 1)
          )
          "text: ${configText cfg-hardware "example-container"}")

        (check "hardware/caps-autodev-hook-and-arch-reach-the-render"
          (
            let t = configText cfg-hardware "example-container"; in
            lib.hasInfix "lxc.cap.drop = sys_module sys_boot" t
            && lib.hasInfix "lxc.autodev = 1" t
            && lib.hasInfix "lxc.hook.pre-start = /example/guard.sh" t
            && lib.hasInfix "lxc.arch = linux32" t
          )
          "text: ${configText cfg-hardware "example-container"}")

        (check "host-only/lxc-enabled"
          cfg-host-only.virtualisation.lxc.enable
          "got: ${builtins.toJSON cfg-host-only.virtualisation.lxc.enable}")

        (check "host-only/lxcpath-in-systemConfig"
          (lib.hasInfix "lxc.lxcpath = /var/lib/nixlxc/containers" cfg-host-only.virtualisation.lxc.systemConfig)
          "systemConfig: ${cfg-host-only.virtualisation.lxc.systemConfig}")

        (check "host-only/lxc-service-wanted-by-multi-user"
          (lib.elem "multi-user.target" cfg-host-only.systemd.services.lxc.wantedBy)
          "wantedBy: ${builtins.toJSON cfg-host-only.systemd.services.lxc.wantedBy}")

        (check "host-only/no-container-apply-services"
          (!(lib.any (n: lib.hasPrefix "nixlxc-container-" n) (lib.attrNames cfg-host-only.systemd.services)))
          "systemd.services keys: ${builtins.toJSON (builtins.attrNames cfg-host-only.systemd.services)}")

        # --- containersPath-required (failing direction) ------------------------------
        (check "containersPath-required/fails-when-unset"
          (buildFails [{ nixlxc.host.enable = true; }])
          "expected nixlxc.host.enable with no containersPath set to fail evaluation, but it succeeded")

        # --- containers-need-a-host (failing direction) --------------------------------
        (check "containers-need-a-host/fails-when-host-disabled"
          (buildFails [{
            nixlxc.host.containersPath = "/var/lib/nixlxc/containers";
            nixlxc.containers.orphan = {
              rootfs.path = "/var/lib/nixlxc/roots/orphan";
            };
          }])
          "expected a container defined with nixlxc.host.enable = false (its own default) to fail evaluation, but it succeeded")

        # --- container required fields (failing direction, each named) -----------------
        (check "envelope/read-from-nixhost-renders-the-ceiling"
          (lib.hasInfix "lxc.cgroup2.memory.max = 536870912"
            (configText (evalNixos [ baseHost stubs.hostEnvStub
              { nixlxc.containers.example-container.rootfs.path = "/var/lib/nixlxc/roots/example"; }
              { nixhost.environments.example-container = { kind = "lxc"; resources.ram.limitMiB = 512; }; }
            ]) "example-container"))
          "the ceiling must come from nixhost.environments.<name>.resources, matched by name -- this module declares no envelope of its own")

        (check "envelope/absent-nixhost-renders-NO-ceiling"
          (!(lib.hasInfix "lxc.cgroup2.memory.max"
            (configText (evalNixos [ baseHost
              { nixlxc.containers.example-container.rootfs.path = "/var/lib/nixlxc/roots/example"; }
            ]) "example-container")))
          "with no nixhost envelope there is no ceiling to render: an unbounded container is liblxc's own default and `null` already means exactly that in nixhost's vocabulary -- inventing a number here would be a resourcing decision made silently")

        (check "envelope/absent-nixhost-still-builds"
          (!(buildFails [ baseHost { nixlxc.containers.example-container.rootfs.path = "/var/lib/nixlxc/roots/example"; } ]))
          "a container must still evaluate on a host that has never imported nixhost -- a cross-repo read that cannot be adopted incrementally will not be adopted")

        (check "envelope/environment-with-unset-kind-still-builds"
          (!(buildFails [ baseHost stubs.hostEnvStubKindMandatory
            { nixlxc.containers.example-container.rootfs.path = "/var/lib/nixlxc/roots/example"; }
            { nixhost.environments.example-container.resources.ram.limitMiB = 512; }
          ]))
          "nixhost's `kind` is mandatory with no default, so reading it when unset THROWS rather than yielding null -- `or null` does not catch that, only tryEval does. Without the guard, a host that declared an environment but had not yet said what kind it is fails to evaluate, with an error pointing at nixhost instead of at the omission")

        (check "envelope/kind-disagreement-fails"
          (buildFails [ baseHost stubs.hostEnvStub
            { nixlxc.containers.example-container.rootfs.path = "/var/lib/nixlxc/roots/example"; }
            { nixhost.environments.example-container = { kind = "vm"; resources.ram.limitMiB = 512; }; }
          ])
          "nixhost calling the same name a vm while this module builds an LXC container is two declarations disagreeing about what the thing IS -- nixhost would budget an envelope for the wrong kind and this module would read a ceiling meant for something else")

        (check "envelope/matching-kind-builds-fine"
          (!(buildFails [ baseHost stubs.hostEnvStub
            { nixlxc.containers.example-container.rootfs.path = "/var/lib/nixlxc/roots/example"; }
            { nixhost.environments.example-container = { kind = "lxc"; resources.ram.limitMiB = 512; }; }
          ]))
          "kind = lxc agreeing with an LXC container must not fire -- the check is about disagreement, not about nixhost being present")

        # --- the passing container composes and renders correctly ----------------------
        (check "one-container/toplevel-evaluates"
          (builtins.tryEval (builtins.seq (builtins.unsafeDiscardStringContext cfg-one-container.system.build.toplevel.drvPath) true)).success
          "expected a fully-specified container to evaluate cleanly")

        (check "one-container/config-rendered-to-etc"
          (cfg-one-container.environment.etc ? "nixlxc/containers/example-container.config")
          "environment.etc keys: ${builtins.toJSON (builtins.attrNames cfg-one-container.environment.etc)}")

        (check "one-container/config-contains-rootfs"
          (lib.hasInfix "lxc.rootfs.path = dir:/var/lib/nixlxc/roots/example" (configText cfg-one-container "example-container"))
          "text: ${configText cfg-one-container "example-container"}")

        # A bare container renders NO memory or cpu ceiling: this module declares no envelope of
        # its own, so with no nixhost there is nothing to render. A default here would be a
        # resourcing decision made silently, and it would also disarm nixhost's oversubscription
        # arithmetic by rendering a number nixhost never summed.
        (check "one-container/config-omits-memory-limit-without-nixhost"
          (!(lib.hasInfix "lxc.cgroup2.memory.max" (configText cfg-one-container "example-container")))
          "text: ${configText cfg-one-container "example-container"}")

        (check "one-container/config-omits-cpu-limit-without-nixhost"
          (!(lib.hasInfix "lxc.cgroup2.cpu.max" (configText cfg-one-container "example-container")))
          "text: ${configText cfg-one-container "example-container"}")

        (check "envelope/cpu-quota-from-nixhost-renders"
          (lib.hasInfix "lxc.cgroup2.cpu.max = 400000 100000"
            (configText (evalNixos [ baseHost stubs.hostEnvStub
              { nixlxc.containers.example-container.rootfs.path = "/var/lib/nixlxc/roots/example"; }
              { nixhost.environments.example-container = { kind = "lxc"; resources.cpu.quotaCores = 4; }; }
            ]) "example-container"))
          "a cpu quota declared in nixhost must reach the rendered cgroup line -- 4 cores over a fixed 100ms period")

        # Counterpart to config-render/autostart-false-states-the-decision-rather-than-omitting-it:
        # the default is still OFF, and now it says so in the rendered config instead of leaving a
        # reader to infer it from an absent line.
        (check "one-container/config-states-autostart-off-by-default"
          (lib.hasInfix "lxc.start.auto = 0" (configText cfg-one-container "example-container"))
          "text: ${configText cfg-one-container "example-container"}")

        (check "one-container/config-omits-idmap-by-default"
          (!(lib.hasInfix "lxc.idmap" (configText cfg-one-container "example-container")))
          "text: ${configText cfg-one-container "example-container"}")

        (check "one-container/apply-service-rendered"
          (cfg-one-container.systemd.services ? "nixlxc-container-example-container-apply")
          "systemd.services keys: ${builtins.toJSON (builtins.attrNames cfg-one-container.systemd.services)}")

        (check "one-container/apply-service-installs-to-containersPath"
          (lib.hasInfix "/var/lib/nixlxc/containers/example-container/config"
            cfg-one-container.systemd.services."nixlxc-container-example-container-apply".script)
          "script: ${cfg-one-container.systemd.services."nixlxc-container-example-container-apply".script}")

        (check "one-container/apply-service-ordered-before-lxc-service"
          (lib.elem "lxc.service" cfg-one-container.systemd.services."nixlxc-container-example-container-apply".before)
          "before: ${builtins.toJSON cfg-one-container.systemd.services."nixlxc-container-example-container-apply".before}")

        # --- autostart = true reaches the rendered config -------------------------------
        (check "container-autostart/config-contains-start-auto"
          (lib.hasInfix "lxc.start.auto = 1" (configText cfg-container-autostart "example-container"))
          "text: ${configText cfg-container-autostart "example-container"}")

        # --- deliver: resolves for real against the delivery stub -----------------------
        (check "deliver/resolved-mount-rendered"
          (lib.hasInfix "lxc.mount.entry = /example/media media none rbind,create=dir 0 0"
            (configText cfg-deliver-resolved "example-container"))
          "text: ${configText cfg-deliver-resolved "example-container"}")

        # --- deliver: unknown category fails the build WHEN nixstorage IS declared ------
        (check "deliver/unknown-category-fails-when-nixstorage-declared"
          (buildFails [
            baseHost
            stubs.deliveryStub
            {
              nixstorage.delivery.categories.media = { source = "/example/media"; home = "media"; };
              nixlxc.containers.example-container = {
                rootfs.path = "/var/lib/nixlxc/roots/example";
                deliver = [ "not-a-real-category" ];
              };
            }
          ])
          "expected an unresolved deliver name to fail evaluation once nixstorage.delivery.categories is declared, but it succeeded")

        # --- deliver: SILENT when nixstorage is not declared at all ---------------------
        # THE assertion this whole redesign exists to prove correct: a defensive read
        # resolves to `{ }` whether nixstorage is absent, or present-but-empty -- so
        # without gating on `options ? nixstorage`, EVERY host that has not yet adopted
        # nixstorage, with ANY container declaring `deliver`, would fail evaluation. It
        # must not.
        (check "deliver/silent-when-nixstorage-entirely-absent"
          (
            !(buildFails [
              baseHost
              {
                nixlxc.containers.example-container = {
                  rootfs.path = "/var/lib/nixlxc/roots/example";
                  deliver = [ "media" ];
                };
              }
            ])
          )
          "a deliver entry referencing a category must never fail the build when nixstorage.delivery is not declared at all -- it must resolve to nothing, silently")

        (check "deliver/no-mount-rendered-when-nixstorage-entirely-absent"
          (!(lib.hasInfix "lxc.mount.entry" (configText cfg-deliver-nixstorage-absent "example-container")))
          "text: ${configText cfg-deliver-nixstorage-absent "example-container"}")

        # --- idmap: resolves for real against the posix stub -----------------------------
        (check "idmap/resolved-lines-rendered"
          (
            let text = configText cfg-idmap-resolved "example-container"; in
            lib.hasInfix "lxc.idmap = u 0 100000 65536" text && lib.hasInfix "lxc.idmap = g 0 100000 65536" text
          )
          "text: ${configText cfg-idmap-resolved "example-container"}")

        # --- idmap: unresolved name fails REGARDLESS of whether nixiam is declared -------
        # The asymmetry with `deliver` stated once, and checked twice: a missing mount is a
        # safe empty default; a silently-more-privileged container is not, so this assertion
        # is never gated on nixiam's presence the way deliver's is on nixstorage's.
        (check "idmap/unresolved-fails-when-nixiam-declared"
          (buildFails [
            baseHost
            stubs.posixStub
            {
              nixiam.posix.identities.container-base = { uid = 100000; };
              nixlxc.containers.example-container = {
                rootfs.path = "/var/lib/nixlxc/roots/example";
                idmap.base = "not-a-real-identity";
              };
            }
          ])
          "expected an unresolved idmap.base to fail evaluation when nixiam.posix.identities is declared, but it succeeded")

        (check "idmap/unresolved-fails-when-nixiam-entirely-absent"
          (buildFails [
            baseHost
            {
              nixlxc.containers.example-container = {
                rootfs.path = "/var/lib/nixlxc/roots/example";
                idmap.base = "container-base";
              };
            }
          ])
          "expected idmap.base referencing a name to fail evaluation even when nixiam is not imported at all (unlike deliver, this must NEVER pass silently), but it succeeded")

        # --- idmap left at its null default never fails, with or without nixiam ---------
        (check "idmap/unset-never-fails-without-nixiam"
          (!(buildFails [ baseHost { nixlxc.containers.example-container = { rootfs.path = "/var/lib/nixlxc/roots/example"; }; } ]))
          "a container that never sets idmap.base must build fine on a host with no nixiam at all")

        # --- fact-wiring: lib.probeFact through the real module, not just lib/facts.nix's own ---
        (check "fact-wiring/all-siblings-faithful-has-no-warnings"
          (cfg-facts-all-faithful.warnings == [ ])
          "got warnings=${builtins.toJSON cfg-facts-all-faithful.warnings}, expected none: every sibling composed with its real, un-renamed shape must produce zero warnings")

        (check "fact-wiring/no-siblings-composed-has-no-warnings"
          (cfg-facts-none-composed.warnings == [ ])
          "got warnings=${builtins.toJSON cfg-facts-none-composed.warnings}, expected none: state (a) -- nothing imported at all -- must stay silent")

        (check "fact-wiring/nixstorage-delivery-renamed-warns-exactly-once"
          (
            let w = cfg-facts-nixstorage-renamed.warnings; in
            lib.length w == 1
            && lib.hasInfix "nixstorage.delivery.categories" (lib.head w)
            && lib.hasInfix "nixstorage" (lib.head w)
          )
          "got warnings=${builtins.toJSON cfg-facts-nixstorage-renamed.warnings}, expected exactly one, naming nixstorage.delivery.categories -- the decoy renames it to nixstorage.delivery.mounts while nixstorage itself IS composed, and no container references deliver at all, so nothing but the probe itself can be the source")

        (check "fact-wiring/nixstorage-delivery-renamed-does-not-fail-the-build"
          (!(buildFails [ baseHost stubs.nixstorageDeliveryRenamedStub quietContainer ]))
          "state (c) must warn, not fail the build -- lib.probeFact defaults to mode = \"warn\", never \"assert\", for these three reads")

        (check "fact-wiring/nixiam-posix-renamed-warns-exactly-once"
          (
            let w = cfg-facts-nixiam-renamed.warnings; in
            lib.length w == 1
            && lib.hasInfix "nixiam.posix.identities" (lib.head w)
            && lib.hasInfix "nixiam" (lib.head w)
          )
          "got warnings=${builtins.toJSON cfg-facts-nixiam-renamed.warnings}, expected exactly one, naming nixiam.posix.identities -- the decoy renames it to nixiam.posix.accounts while nixiam itself IS composed, and no container sets idmap.base at all")

        (check "fact-wiring/nixiam-posix-renamed-does-not-fail-the-build"
          (!(buildFails [ baseHost stubs.nixiamPosixRenamedStub quietContainer ]))
          "state (c) must warn, not fail the build, same as the nixstorage case above")

        (check "fact-wiring/nixhost-environments-renamed-warns-exactly-once"
          (
            let w = cfg-facts-nixhost-renamed.warnings; in
            lib.length w == 1
            && lib.hasInfix "nixhost.environments" (lib.head w)
            && lib.hasInfix "nixhost" (lib.head w)
          )
          "got warnings=${builtins.toJSON cfg-facts-nixhost-renamed.warnings}, expected exactly one, naming nixhost.environments -- the decoy renames it to nixhost.workloads while nixhost itself IS composed, and example-container has no matching nixhost.environments entry to trip kindAssertions on top")

        (check "fact-wiring/nixhost-environments-renamed-does-not-fail-the-build"
          (!(buildFails [ baseHost stubs.nixhostEnvironmentsRenamedStub quietContainer ]))
          "state (c) must warn, not fail the build, same as the two cases above")
      ];

      failed = builtins.filter (r: !r.ok) results;
      report = lib.concatMapStringsSep "\n" (r: "  - ${r.name}: ${r.detail}") failed;
    in
    if failed != [ ]
    then
      throw ''
        nixlxc eval-tests FAILED (${toString (builtins.length failed)}/${toString (builtins.length results)}):
        ${report}
      ''
    else
      pkgs.runCommand "nixlxc-eval-tests"
        { passedCount = toString (builtins.length results); }
        ''
          echo "all $passedCount nixlxc eval tests passed"
          touch $out
        '';

  # ── Pure config-render checks: no nixosSystem at all -----------------------------------
  config-render-tests =
    let
      baseArgs = {
        name = "unit-test-container";
        rootfsPath = "/example/rootfs";
        initCmd = "/sbin/init";
        mounts = [ ];
        idmap = null;
        limits = { memoryMiB = null; cpuCores = 2; };
        autostart = false;
        extraConfig = "";
      };

      render = args: lxcConfigLib.mkContainerConfig (baseArgs // args);

      # Forcing the rendered STRING is what reaches a throw raised inside an interpolation --
      # `mkContainerConfig` itself returns without evaluating its body.
      renderThrows = args: !(builtins.tryEval (builtins.seq (render args) true)).success;

      results = [
        (check "config-render/rootfs-dir-mode"
          (lib.hasInfix "lxc.rootfs.path = dir:/example/rootfs" (render { }))
          "rendered: ${render { }}")

        # ── The hardware half ─────────────────────────────────────────────────────────────
        # Everything below renders NOTHING when left alone, so a container declaring none of it
        # is byte-for-byte what this renderer produced before these existed. Each case pins the
        # part of the liblxc key a caller cannot check by reading their own declaration.

        # THE INDEX IS POSITIONAL AND NOT THE CALLER'S. A duplicated or skipped `lxc.net.<n>` is a
        # config liblxc reads differently from how it looks, so the number comes from list order.
        (check "config-render/network-interfaces-are-indexed-by-position"
          (
            let r = render { network = [
              { type = "veth"; link = "br0"; up = true; name = "eth0"; hwaddr = "00:16:3e:00:00:01"; }
              { type = "veth"; link = "br1"; up = false; name = "eth1"; hwaddr = null; }
            ]; }; in
            lib.hasInfix "lxc.net.0.link = br0" r
            && lib.hasInfix "lxc.net.0.hwaddr = 00:16:3e:00:00:01" r
            && lib.hasInfix "lxc.net.1.link = br1" r
            # `up = false` prints no flags line at all, rather than a falsy one liblxc would not read
            && !(lib.hasInfix "lxc.net.1.flags" r)
          )
          "rendered: ${render { network = [{ type = "veth"; link = "br0"; up = true; name = "eth0"; hwaddr = null; }]; }}")

        (check "config-render/no-network-declared-renders-no-net-keys"
          (!(lib.hasInfix "lxc.net." (render { })))
          "rendered: ${render { }}")

        # DENY BEFORE ALLOW, and it is the mechanism rather than tidiness: the cgroup2 filter is
        # evaluated as written, so an allowlist printed before its deny never applies.
        (check "config-render/device-deny-is-rendered-before-its-allows"
          (
            let
              r = render { devices = { denyAll = true; allow = [ "c 1:3 rwm" "c 5:0 rwm" ]; }; };
              # Split on the deny and require BOTH allows in the tail: that is ordering stated as a
              # property of the text rather than as two line numbers compared.
              parts = lib.splitString "lxc.cgroup2.devices.deny = a" r;
              afterDeny = lib.elemAt parts 1;
            in
            lib.length parts == 2
            && lib.hasInfix "devices.allow = c 1:3 rwm" afterDeny
            && lib.hasInfix "devices.allow = c 5:0 rwm" afterDeny
          )
          "rendered: ${render { devices = { denyAll = true; allow = [ "c 1:3 rwm" ]; }; }}")

        (check "config-render/allows-without-deny-render-no-deny-line"
          (
            let r = render { devices = { denyAll = false; allow = [ "c 1:3 rwm" ]; }; }; in
            lib.hasInfix "devices.allow = c 1:3 rwm" r && !(lib.hasInfix "devices.deny" r)
          )
          "rendered: ${render { devices = { denyAll = false; allow = [ "c 1:3 rwm" ]; }; }}")

        # liblxc's five-field entry, including the two trailing zeroes it requires.
        (check "config-render/mount-entry-shape-and-relative-target"
          (
            let r = render { entries = [
              { source = "/dev/net/tun"; target = "/dev/net/tun"; fsType = "none"; options = [ "bind" "create=file" ]; }
              { source = "tmpfs"; target = "sys/power"; fsType = "tmpfs"; options = [ "ro" "size=4k" "create=dir" ]; }
            ]; }; in
            # leading "/" on the target is stripped, because liblxc reads it container-relative
            lib.hasInfix "lxc.mount.entry = /dev/net/tun dev/net/tun none bind,create=file 0 0" r
            && lib.hasInfix "lxc.mount.entry = tmpfs sys/power tmpfs ro,size=4k,create=dir 0 0" r
          )
          "rendered: ${render { entries = [{ source = "/dev/net/tun"; target = "/dev/net/tun"; fsType = "none"; options = [ "bind" ]; }]; }}")

        (check "config-render/caps-autodev-hook-and-arch"
          (
            let r = render {
              capsDrop = [ "sys_module" "sys_boot" ];
              autodev = true;
              hooks.preStart = "/example/guard.sh";
              arch = "linux32";
            }; in
            lib.hasInfix "lxc.cap.drop = sys_module sys_boot" r
            && lib.hasInfix "lxc.autodev = 1" r
            && lib.hasInfix "lxc.hook.pre-start = /example/guard.sh" r
            && lib.hasInfix "lxc.arch = linux32" r
          )
          "rendered: ${render { capsDrop = [ "sys_module" ]; autodev = true; }}")

        # An explicit 0 records a DECISION not to autostart; silence records only that nobody
        # wrote a line. Both are printed so the two are never confused.
        (check "config-render/autostart-is-stated-in-both-directions"
          (
            lib.hasInfix "lxc.start.auto = 0" (render { autostart = false; })
            && lib.hasInfix "lxc.start.auto = 1" (render { autostart = true; })
          )
          "off: ${render { autostart = false; }}")

        (check "config-render/init-cmd"
          (lib.hasInfix "lxc.init.cmd = /sbin/init" (render { }))
          "rendered: ${render { }}")

        # ── Confinement ───────────────────────────────────────────────────────────────────
        # `lxc.mount.auto` used to be a hardcode in the renderer with no option above it, and the
        # hardcoded value was the permissive one. These pin the SAFE default and the override, in
        # that order, because the danger is a caller inheriting `rw` without ever naming it.
        (check "config-render/mount-auto-defaults-to-liblxc-upstream-mixed"
          (lib.hasInfix "lxc.mount.auto = cgroup:mixed proc:mixed sys:mixed" (render { }))
          "rendered: ${render { }}")

        (check "config-render/mount-auto-renders-an-override-verbatim"
          (
            let r = render { mountAuto = "proc:rw sys:rw cgroup:rw:force"; }; in
            lib.hasInfix "lxc.mount.auto = proc:rw sys:rw cgroup:rw:force" r
            && !(lib.hasInfix "cgroup:mixed" r)
          )
          "rendered: ${render { mountAuto = "proc:rw sys:rw cgroup:rw:force"; }}")

        # Absence is the default and it must render NO key -- an empty `lxc.seccomp.profile =`
        # line is not the same fact as no line, and liblxc would read it as a path.
        (check "config-render/seccomp-and-apparmor-render-nothing-by-default"
          (
            let r = render { }; in
            !(lib.hasInfix "lxc.seccomp.profile" r) && !(lib.hasInfix "lxc.apparmor.profile" r)
          )
          "rendered: ${render { }}")

        (check "config-render/seccomp-and-apparmor-render-when-set"
          (
            let r = render { seccompProfile = "/etc/lxc/x.seccomp"; apparmorProfile = "unconfined"; }; in
            lib.hasInfix "lxc.seccomp.profile = /etc/lxc/x.seccomp" r
            && lib.hasInfix "lxc.apparmor.profile = unconfined" r
          )
          "rendered: ${render { seccompProfile = "/etc/lxc/x.seccomp"; apparmorProfile = "unconfined"; }}")

        # ── entryLine: the shapes liblxc MISPARSES rather than rejects ─────────────────────
        # An fstab line is delimited by whitespace RUNS, so a field that renders empty shifts
        # every field after it and liblxc reads a different mount than the one declared -- with
        # no error. These are refusals for that reason, not style.
        (check "config-render/entry-target-is-stripped-to-a-fixed-point"
          (
            let r = render { entries = [ { source = "/dev/kfd"; target = "//dev/kfd"; } ]; }; in
            lib.hasInfix "lxc.mount.entry = /dev/kfd dev/kfd none bind,create=file 0 0" r
          )
          "a target liblxc still reads as absolute is one it silently skips: ${render { entries = [ { source = "/dev/kfd"; target = "//dev/kfd"; } ]; }}")

        (check "config-render/entry-with-empty-options-is-refused"
          (renderThrows { entries = [ { source = "/dev/kfd"; target = "/dev/kfd"; options = [ ]; } ]; })
          "empty options render a double space, so liblxc reads the 0 as the fstype")

        (check "config-render/entry-targeting-the-container-root-is-refused"
          (renderThrows { entries = [ { source = "tmpfs"; target = "/"; fsType = "tmpfs"; options = [ "ro" ]; } ]; })
          "a target that normalises to empty renders the source into the target column")

        # The `or` fallbacks a DIRECT caller gets (no module system applying option defaults)
        # must match the option surface's own, or the two callers render differently. Every other
        # fixture supplies both fields, so nothing else would notice them drifting.
        (check "config-render/entry-fallback-defaults-match-the-option-surface"
          (lib.hasInfix "lxc.mount.entry = /dev/dri dev/dri none bind,create=file 0 0"
            (render { entries = [ { source = "/dev/dri"; target = "/dev/dri"; } ]; }))
          "rendered: ${render { entries = [ { source = "/dev/dri"; target = "/dev/dri"; } ]; }}")

        (check "config-render/idmap-lines-when-set"
          (
            let text = render { idmap = { hostUidBase = 100000; hostGidBase = 100000; count = 65536; }; }; in
            lib.hasInfix "lxc.idmap = u 0 100000 65536" text && lib.hasInfix "lxc.idmap = g 0 100000 65536" text
          )
          "rendered: ${render { idmap = { hostUidBase = 100000; hostGidBase = 100000; count = 65536; }; }}")

        (check "config-render/no-idmap-lines-when-null"
          (!(lib.hasInfix "lxc.idmap" (render { idmap = null; })))
          "rendered: ${render { idmap = null; }}")

        (check "config-render/memory-line-when-set"
          (lib.hasInfix "lxc.cgroup2.memory.max = 536870912" (render { limits = { memoryMiB = 512; cpuCores = 2; }; }))
          "rendered: ${render { limits = { memoryMiB = 512; cpuCores = 2; }; }}")

        (check "config-render/no-memory-line-when-null"
          (!(lib.hasInfix "lxc.cgroup2.memory.max" (render { limits = { memoryMiB = null; cpuCores = 2; }; })))
          "rendered: ${render { limits = { memoryMiB = null; cpuCores = 2; }; }}")

        (check "config-render/cpu-line-scales-with-cores"
          (lib.hasInfix "lxc.cgroup2.cpu.max = 400000 100000" (render { limits = { memoryMiB = null; cpuCores = 4; }; }))
          "rendered: ${render { limits = { memoryMiB = null; cpuCores = 4; }; }}")

        # TWO CHECKS REMOVED HERE rather than kept for the count. They asserted
        # `lxc.start.auto = 1` and `= 0` in isolation, and `autostart-is-stated-in-both-directions`
        # above already asserts BOTH conjuncts -- so neither could fail while that one passed, and
        # a suite reporting three passes for one property overstates its own coverage.
        #
        # Their reason for existing survives them and is worth keeping: printing `= 0` rather than
        # omitting the line renders the same BEHAVIOUR (0 is liblxc's own default) while recording
        # a different FACT -- silence says only that nobody wrote a line, where `lxc.start.auto = 0`
        # says somebody decided this container does not come up with the host. That argument now
        # lives once, next to `autostartLine` in lib/lxc-config.nix, instead of in three places.

        (check "config-render/mount-line-rendered-relative-and-rbind"
          (lib.hasInfix "lxc.mount.entry = /example/media media none rbind,create=dir 0 0"
            (render { mounts = [{ source = "/example/media"; target = "media"; }]; }))
          "rendered: ${render { mounts = [{ source = "/example/media"; target = "media"; }]; }}")

        (check "config-render/multiple-mount-lines-all-present"
          (
            let text = render { mounts = [{ source = "/example/media"; target = "media"; } { source = "/example/work"; target = "work"; }]; }; in
            lib.hasInfix "lxc.mount.entry = /example/media media none rbind,create=dir 0 0" text
            && lib.hasInfix "lxc.mount.entry = /example/work work none rbind,create=dir 0 0" text
          )
          "rendered: ${render { mounts = [{ source = "/example/media"; target = "media"; } { source = "/example/work"; target = "work"; }]; }}")

        (check "config-render/extra-config-appended"
          (lib.hasInfix "lxc.cap.drop = sys_module" (render { extraConfig = "lxc.cap.drop = sys_module"; }))
          "rendered: ${render { extraConfig = "lxc.cap.drop = sys_module"; }}")

        (check "config-render/name-interpolated"
          (lib.hasInfix "lxc.uts.name = unit-test-container" (render { }))
          "rendered: ${render { }}")
      ];

      failed = builtins.filter (r: !r.ok) results;
      report = lib.concatMapStringsSep "\n" (r: "  - ${r.name}: ${r.detail}") failed;
    in
    if failed != [ ]
    then
      throw ''
        nixlxc config-render-tests FAILED (${toString (builtins.length failed)}/${toString (builtins.length results)}):
        ${report}
      ''
    else
      pkgs.runCommand "nixlxc-config-render-tests"
        { passedCount = toString (builtins.length results); }
        ''
          echo "all $passedCount nixlxc config-render tests passed"
          touch $out
        '';
}
