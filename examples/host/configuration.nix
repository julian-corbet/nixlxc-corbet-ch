# The smallest NixOS configuration that lets `nixlxc.host` + `nixlxc.containers` be evaluated
# as part of a real system. Nothing here names a real host, path, or identity -- every value is
# generic (`examplebr0`-style placeholders throughout), the same convention nixvm's own
# examples/host/configuration.nix states for itself.
#
# `deliver`/`idmap.base` below reference names ("media", "container-base") that only resolve
# to something real once a host ALSO imports nixstorage's delivery module / nixiam's posix
# module and declares matching entries -- see the comments inline. Neither is imported here:
# this file demonstrates nixlxc composing on its own, which is exactly the point of reading
# both defensively (see modules/containers/default.nix's own header) rather than as a flake
# input.
{ ... }:
{
  nixlxc.host = {
    enable = true;
    containersPath = "/var/lib/nixlxc/containers";
  };

  nixlxc.containers.example-container = {
    rootfs.path = "/var/lib/nixlxc/roots/example-container";
    # NOTE: no resource ceiling is declared here. The envelope lives in nixhost --
    #   nixhost.environments.example-container.resources.ram.limitMiB = 2048;
    #   nixhost.environments.example-container.resources.cpu.quotaCores = 2;
    # matched by name. nixhost owns the arithmetic that sums every environment's claim against
    # the host, and a second ceiling here would disarm it rather than duplicate it.

    # Names into nixstorage.delivery.categories -- inert here (rendered as NO extra mount
    # lines at all) because this example does not import nixstorage's delivery module. On a
    # real host that does, and that declares
    # `nixstorage.delivery.categories.media = { source = "/tank/media"; home = "media"; ...  };`,
    # this same line resolves to a real bind mount -- or fails the build BY NAME if "media"
    # is a typo once that module IS imported. See modules/containers/README.md.
    deliver = [ "media" ];

    # Name into nixiam.posix.identities -- would fail the build the moment nixiam's posix
    # module is imported without a matching identity declared (unlike `deliver` above, this
    # is NEVER silent -- see modules/containers/README.md's "deliver vs idmap" section).
    # Left commented out here so this example evaluates standalone, with no nixiam import at
    # all, as a genuinely privileged (no idmap) container:
    #
    #   idmap.base = "container-base";

    autostart = false;
  };

  # ── Stubs NixOS demands of any bootable system ───────────────────────────
  fileSystems."/" = {
    device = "nodev";
    fsType = "tmpfs";
  };

  boot.loader.grub = {
    enable = true;
    devices = [ "nodev" ];
  };

  networking.hostName = "example-lxc-host";
  system.stateVersion = "25.05";
}
