{
  description = "A declarative home for LXC container workloads on NixOS -- an LXC host stance plus container definitions as data, where WHAT a container receives (storage categories, a uid/gid identity) is named, never restated as a host path or a raw number. The peer of nixk3s (bare metal running k3s), nixvm (bare metal running VMs) and nixpods (bare metal running podman): nixlxc is bare metal running LXC containers, and none of the four owns another.";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  # Deliberately NO nixstorage or nixiam input, in either direction -- not even for `checks`.
  # nixlxc.containers.<name>.deliver/.idmap.base are resolved defensively
  # (`config.nixstorage.delivery.categories or { }` / `config.nixiam.posix.identities or { }`),
  # exactly as nixvault reads `config.nixstorage.disks or { }` with zero flake dependency on
  # nixstorage at all. `checks/stub-modules.nix` declares small, self-contained stand-in
  # options matching just the shape this repo actually reads, so the "declared" branch of both
  # defensive reads is exercised for real without this repo depending on either sibling
  # project's own release state -- see that file's own header for why a real flake input was
  # deliberately avoided here, even though nixstorage's own checks DO pull in nixiam that way.
  #
  # nixhost IS an input, for exactly one thing: `lib.probeFact`/`lib.collectProbes`
  # (github:julian-corbet/nixhost-corbet-ch, `lib/facts.nix`) -- the shared, plain-function fix for
  # the cross-namespace defensive-read defect class this module's own `nixstorageCategoriesProbe`/
  # `nixiamPosixProbe`/`nixhostEnvironmentsProbe` all lean on (see nixhost's own `lib/facts.nix`
  # header). One recipe, not a second copy -- the same fix nixvault/nixnas apply to their own
  # shared f2fs catalogue. `probeFact`/`collectProbes` are closed over as plain function arguments
  # (below), never `_module.args` -- the same partially-applied-before-the-module-system-sees-it
  # pattern this family already uses for `nixfsCatalogue` (see infra's own flake.nix comment on
  # `mkNixnas` for that precedent) -- so a consumer importing `nixosModules.containers` sees an
  # ordinary module function and never needs to know `nixhost` exists. This is orthogonal to the
  # paragraph above: nixstorage/nixiam/nixhost's own DATA is still read defensively, with zero
  # flake dependency -- only the `probeFact`/`collectProbes` MECHANISM itself is consumed rather
  # than vendored.
  inputs.nixhost = {
    url = "github:julian-corbet/nixhost-corbet-ch";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, nixhost }:
    let
      lib = nixpkgs.lib;
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: lib.genAttrs systems f;
    in
    {
      # The LXC host stance: liblxc enabled, `lxcpath` declared, the upstream lxc.service
      # autostart pass wired up. See modules/lxc-host/default.nix's own SCOPE block.
      nixosModules.lxc-host = ./modules/lxc-host;

      # Container definitions, as data, rendered to a real liblxc `.config` document and kept
      # materialized at its lxcpath location. See modules/containers/default.nix's own SCOPE
      # block -- and its "ALWAYS COMPOSED WITH modules/lxc-host" assertion, which is why
      # `default` below imports both together.
      #
      # `probeFact`/`collectProbes` closed over here, before the module system ever sees the
      # result -- see the input comment above. The exported value is a plain module function
      # taking the usual `{ lib, config, pkgs, ... }`; nothing about consuming it changes.
      nixosModules.containers = import ./modules/containers {
        inherit (nixhost.lib) probeFact collectProbes;
      };

      nixosModules.default = { imports = [ self.nixosModules.lxc-host self.nixosModules.containers ]; };

      # The pure config-rendering function, exposed so a consumer can inspect or unit-test it
      # without composing a full NixOS system -- same reasoning nixvm exposes `lib.mkDomainXML`.
      lib.mkContainerConfig = (import ./lib/lxc-config.nix { inherit lib; }).mkContainerConfig;

      checks = forAllSystems (system:
        import ./checks {
          pkgs = nixpkgs.legacyPackages.${system};
          inherit lib system;
          lxcHostModule = self.nixosModules.lxc-host;
          containersModule = self.nixosModules.containers;
        });

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
