# checks/stub-modules.nix
#
# Two tiny, self-contained stand-in modules -- NOT the real nixstorage/nixiam -- declaring just
# enough option surface to exercise the "declared" branch of `modules/containers`'s two
# defensive reads (`config.nixstorage.delivery.categories or { }` /
# `config.nixiam.posix.identities or { }`) for real.
#
# WHY A STAND-IN, NOT THE REAL SIBLING REPO. nixstorage's own `checks/default.nix` pulls in the
# real nixiam flake as a `checks`-only input to compose its reconciler tests against a real
# identity registry -- a real precedent in this family for depending on a sibling repo at test
# time only. This repo deliberately does NOT follow that precedent: nixstorage and nixiam are
# independently developed and can be under concurrent edit by another agent at any time. A
# `git+file://` flake input resolves against whatever that other repo's working tree happens to
# look like at the exact moment `nix flake check` runs here -- exactly the kind of cross-session
# flakiness this repo's own tests must never depend on. A minimal stand-in matching only the
# fields this repo's own code actually reads (`categories.<name>.source`/`.home`,
# `identities.<name>.uid`/`.gid`) proves the resolution/gating logic just as faithfully,
# without caring what either sibling repo's schema looks like on any given day -- and remains
# valid regardless of how either evolves.
{ lib }:

{
  # Mirrors nixstorage's `modules/delivery.nix` `categories.<name>` shape, narrowed to the two
  # fields `modules/containers/default.nix` actually reads.
  deliveryStub = { ... }: {
    options.nixstorage.delivery.categories = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          source = lib.mkOption { type = lib.types.str; };
          home = lib.mkOption { type = lib.types.str; };
        };
      });
      default = { };
    };
  };

  # Mirrors nixiam's `modules/posix.nix` `identities.<name>` shape, narrowed to the two fields
  # `modules/containers/default.nix` actually reads.
  posixStub = { ... }: {
    options.nixiam.posix.identities = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          uid = lib.mkOption { type = lib.types.int; };
          gid = lib.mkOption { type = lib.types.nullOr lib.types.int; default = null; };
        };
      });
      default = { };
    };
  };

  # nixhost's environment envelope, reduced to the two fields this repo reads. Same reason as the
  # stubs beside it: taking the real flake as a check-time input would make these checks depend on
  # a sibling repo's mid-edit working tree.
  # Deliberately WITHOUT a default on `kind`, mirroring the real nixhost. The stub beside this one
  # gives kind a default, which is exactly why the mandatory-unset case went unexercised and a bug
  # shipped: reading a mandatory option that has no value THROWS, and `or null` does not catch it.
  hostEnvStubKindMandatory = { ... }: {
    options.nixhost.environments = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          kind = lib.mkOption { type = lib.types.str; };
          resources.ram.limitMiB = lib.mkOption { type = lib.types.nullOr lib.types.ints.positive; default = null; };
          resources.cpu.quotaCores = lib.mkOption { type = lib.types.nullOr lib.types.ints.positive; default = null; };
        };
      });
      default = { };
    };
  };

  hostEnvStub = { ... }: {
    options.nixhost.environments = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          kind = lib.mkOption { type = lib.types.str; default = "lxc"; };
          resources.ram.limitMiB = lib.mkOption { type = lib.types.nullOr lib.types.ints.positive; default = null; };
          resources.cpu.quotaCores = lib.mkOption { type = lib.types.nullOr lib.types.ints.positive; default = null; };
        };
      });
      default = { };
    };
  };
}
