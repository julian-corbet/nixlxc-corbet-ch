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
  outputs = { self, nixpkgs }:
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
      nixosModules.containers = ./modules/containers;

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
