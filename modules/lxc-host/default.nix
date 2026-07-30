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

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.containersPath != null;
        message = ''
          nixlxc.host.containersPath must be set -- there is no default (see the option doc).
          Set it to the directory this host's own storage provisioning already brings up;
          nixlxc never creates one.
        '';
      }
    ];

    virtualisation.lxc.enable = lib.mkDefault true;
    virtualisation.lxc.systemConfig = lib.mkDefault "lxc.lxcpath = ${effectiveContainersPath}\n";

    # See this file's own header ("WHY lxc.service, NOT A BESPOKE nixlxc AUTOSTART UNIT") for
    # exactly why this mirrors nixpkgs's own lxc.nix module's treatment of lxc-net.service.
    systemd.packages = [ config.virtualisation.lxc.package ];
    systemd.services.lxc = {
      enable = true;
      wantedBy = [ "multi-user.target" ];
    };
  };
}
