# lib/lxc-config.nix
#
# Pure rendering: (name, rootfsPath, initCmd, mounts, idmap, limits, autostart, extraConfig)
# -> a liblxc container `.config` document, as a plain string. No `config`, no NixOS module
# system, no derivations -- this file only ever sees plain Nix values, so it is testable in
# total isolation (see checks/default.nix's "config-render/*" group, which calls it directly
# with hand-built fixtures and never builds a NixOS system to do it) and reusable by anything
# that wants to hand liblxc a container definition, not only modules/containers. Same
# reasoning as nixvm's own lib/domain-xml.nix, which this file mirrors closely -- see that
# file's header for the same argument made about libvirt domain XML instead of an lxc config.
#
# modules/containers/default.nix is the one caller in this repo. It supplies:
#   - `mounts`: an ALREADY-RESOLVED list of `{ source; target; }` -- every entry already
#     looked up from `nixstorage.delivery.categories` by the caller (this file never sees a
#     category NAME, only the plain host `source` path and the `target` leaf it resolved to).
#   - `idmap`: either `null` (no unprivileged remapping -- the container's own uid 0 is the
#     HOST's uid 0, a "privileged" container in liblxc's own vocabulary) or an already-resolved
#     `{ hostUidBase; hostGidBase; count; }` -- every uid/gid this file ever prints came from
#     the caller resolving a name against `nixiam.posix.identities`, never from this file
#     looking anything up itself.
#
# WHY THE MOUNT TARGET IS THE CATEGORY'S OWN `home` LEAF, MOUNTED AT THE CONTAINER'S ROOT.
# `nixstorage.delivery.categories.<name>.home` is documented, in nixstorage's own
# `modules/delivery.nix`, as "the leaf name a consumer surfaces it at". A container has no
# single human `$HOME` the way a desktop session does, so this module surfaces each delivered
# category directly at `/<home>` under the container's own filesystem root (`/media`, `/work`,
# ...) rather than inventing a container-side notion of "whose home directory" nixstorage
# itself has no opinion on. `rel` strips the leading "/" because every liblxc
# `lxc.mount.entry` target is container-RELATIVE, exactly the convention this family's own
# (superseded) render-storage.nix used for the identical reason.
{ lib }:

let
  rel = p: lib.removePrefix "/" p;

  # A plain recursive bind (not `bind`, to match this family's OWN prior art: a category's
  # `source` may itself hide further mounts nested underneath it -- a ZFS dataset with its own
  # mounted children, say -- and `rbind` carries those along at container start instead of
  # requiring this module to know about them. `create=dir` so liblxc creates the (empty)
  # mountpoint inside the rootfs itself; this module never touches the rootfs directly.
  mountLine = m: "lxc.mount.entry = ${m.source} ${rel m.target} none rbind,create=dir 0 0";

  # A single contiguous range starting at container-side uid/gid 0 -- the common
  # "unprivileged container" shape (matches LXC/LXD's own default subordinate-id convention).
  # Multiple discontiguous ranges are real liblxc capability this first cut does not model;
  # reach for `extraConfig` if a container genuinely needs more than one range.
  idmapLines = idmap: lib.optionalString (idmap != null) ''
    lxc.idmap = u 0 ${toString idmap.hostUidBase} ${toString idmap.count}
    lxc.idmap = g 0 ${toString idmap.hostGidBase} ${toString idmap.count}
  '';

  # cgroup2 CPU bandwidth control is a quota/period pair, both in microseconds. A fixed 100ms
  # period is the kernel's own conventional choice (and what every "N cores" cgroup2 example in
  # the wild uses) -- fixing it here means `cpuCores * cpuPeriodUs` reads directly as "N cores'
  # worth of CPU time every 100ms", with no second number for a caller to have to reason about.
  cpuPeriodUs = 100000;

  memoryLine = memoryMiB: lib.optionalString (memoryMiB != null)
    "lxc.cgroup2.memory.max = ${toString (memoryMiB * 1024 * 1024)}";

  # Omittable for the same reason memoryLine is: an absent ceiling is a real, valid state (no
  # cgroup limit at all), not a missing value to be guessed. See modules/containers/default.nix
  # on where the ceiling comes from and why this file never defaults it.
  cpuLine = cpuCores: lib.optionalString (cpuCores != null)
    "lxc.cgroup2.cpu.max = ${toString (cpuCores * cpuPeriodUs)} ${toString cpuPeriodUs}";

  # `lxc.start.auto` is read by liblxc's own upstream `lxc-autostart` (via the packaged
  # `lxc.service`, see modules/lxc-host/default.nix) at HOST boot -- this module only ever
  # prints the flag; it never calls `lxc-start`/`lxc-stop` itself. See that module's header for
  # why wiring the upstream unit, rather than inventing a bespoke one, is the right call here.
  autostartLine = autostart: lib.optionalString autostart "lxc.start.auto = 1";
in
{
  mkContainerConfig = { name, rootfsPath, initCmd, mounts, idmap, limits, autostart, extraConfig }: ''
    lxc.uts.name = ${name}
    lxc.arch = linux64
    lxc.rootfs.path = dir:${rootfsPath}
    lxc.init.cmd = ${initCmd}

    # proc/sys/cgroup delegation -- fixed, not host-specific: any init system this module might
    # hand a rootfs to needs these to manage its own systemd (or equivalent) slices. Baked in
    # here rather than left to `extraConfig` because every container this module can define
    # needs it identically; see modules/containers/README.md.
    lxc.mount.auto = proc:rw sys:rw cgroup:rw:force

    ${idmapLines idmap}
    ${memoryLine limits.memoryMiB}
    ${cpuLine limits.cpuCores}
    ${autostartLine autostart}

    ${lib.concatMapStringsSep "\n" mountLine mounts}

    ${extraConfig}
  '';
}
