# modules/lxc-host/default.nix
#
# ONE declarative LXC stance per host: liblxc enabled, `lxcpath` (where every container's own
# `<name>/config` and `<name>/rootfs` live) declared -- never created -- and the upstream
# `lxc.service` autostart pass wired up so `nixlxc.containers.<name>.autostart` actually means
# something at host boot. This exists because "can this machine host LXC containers at all" is
# a question every bare-metal host can ask independently of what k3s (nixk3s) or a libvirt/VM
# stance (nixvm) does on the same box -- see the repo README for the full boundary against
# both.
#
# SCOPE -- what this module owns, so no knob has two managers:
#   OWNED : whether liblxc runs at all (host.enable); `lxcpath` -- a DECLARED fact about a
#           directory that already exists, never created here (host.containersPath); wiring
#           the upstream `lxc.service`/`lxc-autostart` boot-time pass so a container's own
#           `autostart` flag (rendered by modules/containers) is actually acted on.
#   NOT   : creating, formatting, or populating ANY directory this module reads --
#           `host.containersPath` must already exist. That is a disk-layout/provisioning
#           concern, not this module's, the same boundary nixvm's own `vm-host` draws around
#           `storagePools.<name>.path`.
#   NOT   : per-container rootfs/idmap/limits/autostart/deliver definitions -- that is
#           modules/containers, which this module composes alongside but never absorbs. A host
#           that only ever wants the LXC capability with no containers defined yet can import
#           this module alone.
#   NOT   : starting, stopping, or restarting a container. See modules/containers' own header,
#           and the note below on exactly what enabling the upstream `lxc.service` unit does
#           and does not do.
#
# ── WHY `lxc.service`, NOT A BESPOKE nixlxc AUTOSTART UNIT ──────────────────────────────────
# `pkgs.lxc` ships a real upstream systemd unit (`lib/systemd/system/lxc.service`,
# confirmed present in this repo's own `nixpkgs` input) whose `ExecStart` runs
# `lxc-containers start`, which in turn calls `lxc-autostart` -- the exact upstream mechanism
# for "start every container under `lxcpath` whose own config carries `lxc.start.auto = 1`" at
# HOST boot. This is the identical boundary nixvm's own `modules/guests` draws around `virsh
# autostart`: "autostart is the one exception worth naming explicitly: it only affects behavior
# at the HOST's next boot, never a live container's current state." Enabling `lxc.service` is
# ALL this module does to make that true for LXC -- it never calls `lxc-start`/`lxc-stop`
# itself, and it has no opinion on any INDIVIDUAL container, only on whether the host-wide
# upstream mechanism that reads their own `lxc.start.auto` flags is switched on at all.
#
# Combining `systemd.packages` (to pull in the unit file `pkgs.lxc` itself ships) with a
# `systemd.services.lxc` override (`wantedBy`) to actually enable it mirrors the exact pattern
# NixOS's OWN `nixos/modules/virtualisation/lxc.nix` uses for `lxc-net.service` (`systemd.
# packages = mkIf cfg.unprivilegedContainers [ pkgs.lxc ]; systemd.services.lxc-net = { enable
# = true; wantedBy = [ "multi-user.target" ]; ... };`) -- confirmed by reading that module's
# own source rather than assumed.
#
# An operator starts/stops an individual container the same native way: `systemctl start
# lxc@<name>` / `systemctl stop lxc@<name>` (the packaged `lxc@.service` template unit), or
# `lxc-start`/`lxc-stop` directly. Neither this module nor modules/containers ever does either
# on an operator's behalf.
{ lib, config, pkgs, ... }:

let
  cfg = config.nixlxc.host;

  effectiveContainersPath = if cfg.containersPath != null then cfg.containersPath else "/unset-containers-path";
in
{
  options.nixlxc.host = {
    enable = lib.mkEnableOption "a declarative LXC container host";

    runtimeManagedElsewhere = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        The host already runs liblxc, and something other than this module owns it.

        WHY THIS EXISTS RATHER THAN "just enable the host too". `modules/containers` refuses to
        declare a container with no host, which is the right default: a rendered `.config` that
        nothing can start is a declaration with no effect, and that refusal is worth keeping.
        But it assumed the only possible host was THIS module's, and that is a different claim.
        A host may already have liblxc installed and its `lxcpath` set by a module of its own --
        an existing bespoke one, a foreign-distro plane, an inherited setup being migrated
        incrementally -- and on such a host the choice was to either duplicate the runtime (two
        modules setting `virtualisation.lxc`, both believing they own the unit) or abandon typed
        container rendering entirely. Neither is a good answer to "I want this container declared".

        Set true and this module installs NOTHING: no liblxc, no `lxcpath`, no service.

        ⚠ IT ALSO STOPS MATERIALISING. `modules/containers` RENDERS the container to
        `/etc/nixlxc/containers/<name>.config` and stops there; installing that at the lxcpath is
        the runtime owner's job. This is not a limitation to route around -- materialising needs
        an ordering edge (after the storage holding `containersPath`, before whatever starts the
        container) and under an external runtime this module knows NEITHER. It guessed once, on a
        real host, and was wrong three ways at once: it ordered before a unit that did not exist,
        ran 225s before the pool holding its target mounted, and rewrote the live config after the
        container had already started from it.

        So a consumer setting this MUST install the rendered file itself. The reference consumer
        does it as an ExecStartPre in the very unit that starts the container, which is the one
        ordering that cannot race. A warning says so at eval, because a container that silently
        never picks up config changes is exactly the failure this repo exists to prevent.

        `containersPath` is still required, because the renderer has to know where the other owner
        keeps its containers.

        This is a statement about who owns the runtime, never about whether one exists -- nothing
        here can verify that liblxc is actually installed, and a wrong answer surfaces as a
        container that will not start rather than as a silent misconfiguration.
      '';
    };

    materialisedBy = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "lxc-arch.service ExecStartPre";
      description = ''
        WHAT installs the rendered config at the lxcpath, when this module does not.

        Only meaningful with `runtimeManagedElsewhere`. In that mode nothing here copies
        `/etc/nixlxc/containers/<name>.config` into place, and a consumer who assumes otherwise
        gets a container that starts from a stale file and never picks up a change -- silently.
        So the module warns.

        Naming the mechanism here silences that warning, and the point is that it is a
        DECLARATION rather than a mute button: this module cannot verify that anything
        materialises the file, so the honest choice is between an unanswered question and a
        recorded answer. Answering it also leaves the next reader a pointer to the thing that
        actually does the work, which a suppressed warning never would.

        Whatever you name here should be able to order itself correctly: after the storage
        holding `containersPath`, and before whatever starts the container.
      '';
    };

    containersPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/var/lib/nixlxc/containers";
      description = ''
        `lxcpath`: the existing directory liblxc stores and reads containers under -- each
        container lives at `<containersPath>/<name>/` (its own `config` file, kept
        materialized by modules/containers, plus a `rootfs/` this module never touches). NO
        DEFAULT: which directory (and which filesystem/dataset backs it) is a fact about this
        specific host, never a value worth guessing -- the identical reasoning nixvm's own
        `host.storagePools.<name>.path` states for a libvirt storage pool's directory. Declared,
        never created: this module does not create, mount, or format `containersPath` --
        provisioning it is a disk-layout tool's job (`nixstorage`, or whatever else a given
        host already uses).
      '';
    };
  };

  config = lib.mkMerge [
    # `containersPath` is required whenever this module's option surface is being USED for real --
    # whether the runtime is ours or somebody else's. Split out of the block below because that one
    # only runs when we install the runtime, and the renderer needs this path in both cases: it is
    # where the container's `.config` gets materialised, which is a fact about the host regardless
    # of who starts liblxc.
    (lib.mkIf (cfg.enable || cfg.runtimeManagedElsewhere) {
      assertions = [
        {
          assertion = cfg.containersPath != null;
          message = ''
            nixlxc.host.containersPath must be set -- there is no default (see the option doc).
            Set it to the directory this host's own storage provisioning already brings up;
            nixlxc never creates one.
          '';
        }
        {
          # The two are alternatives, not a spectrum. Both set at once means one of them is a
          # leftover, and which runtime is authoritative would be decided by merge order rather
          # than by anybody's intent.
          assertion = !(cfg.enable && cfg.runtimeManagedElsewhere);
          message = ''
            nixlxc.host.enable and nixlxc.host.runtimeManagedElsewhere are both set. They are
            alternatives: the first installs liblxc and its lxcpath here, the second declares that
            something else already does. Setting both means two owners of one runtime -- pick the
            one that is true.
          '';
        }
      ];
    })

    # The RUNTIME half: installed only when this module owns it. Everything here is exactly
    # what `runtimeManagedElsewhere` says somebody else already provides.
    (lib.mkIf cfg.enable {
      virtualisation.lxc.enable = lib.mkDefault true;
      virtualisation.lxc.systemConfig = lib.mkDefault "lxc.lxcpath = ${effectiveContainersPath}\n";

      # See this file's own header ("WHY lxc.service, NOT A BESPOKE nixlxc AUTOSTART UNIT")
      # for exactly why this mirrors nixpkgs's own lxc.nix treatment of lxc-net.service.
      systemd.packages = [ config.virtualisation.lxc.package ];
      systemd.services.lxc = {
        enable = true;
        wantedBy = [ "multi-user.target" ];
      };
    })
  ];
}
