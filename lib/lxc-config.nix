# lib/lxc-config.nix
#
# Pure rendering: a container's facts -- identity (name, arch, rootfsPath, initCmd), storage
# (mounts, entries), hardware (network, devices, autodev, hooks), confinement (idmap,
# capsDrop, mountAuto, seccompProfile, apparmorProfile), limits, autostart, extraConfig
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
# `lxc.mount.entry` target is container-RELATIVE.
{ lib }:

let
  # EVERY leading slash, not one. liblxc mount targets are container-relative, and it skips an
  # entry whose target is absolute -- silently. `removePrefix "/"` turns "//dev/x" into
  # "/dev/x", which is still absolute and still silently skipped, so a caller who wrote one
  # slash too many lost a mount with nothing said. Strip to a fixed point instead.
  rel = p:
    let stripped = lib.removePrefix "/" p; in
    if stripped == p then p else rel stripped;

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
  # BOTH DIRECTIONS, ALWAYS PRINTED. `0` is liblxc's own default, so omitting it would render the
  # same behaviour -- and would say something different. A config that states `lxc.start.auto = 0`
  # records that somebody decided this container does not start with the host; a config that says
  # nothing records only that nobody wrote a line. For a container deliberately kept out of
  # autostart those are not the same fact, and the second one invites a future reader to "fix" it.
  autostartLine = autostart: "lxc.start.auto = ${if autostart then "1" else "0"}";

  # ── A general mount entry ────────────────────────────────────────────────────────────────────
  # liblxc's own five-field shape: SOURCE TARGET FSTYPE OPTIONS 0 0. `mountLine` above is the
  # narrow case (a delivered category, always an rbind of a directory); this is the general one,
  # and it is a separate renderer rather than a generalisation of that one because the two have
  # genuinely different authorities. A delivered mount's source is RESOLVED from a category name
  # and its options are this module's choice; an entry here is a fact about the container's
  # hardware that the caller states outright, and this file has no opinion to add to it.
  #
  # The target is container-RELATIVE, exactly as liblxc reads it, and the leading "/" is stripped
  # rather than rejected so that a caller may write either.
  # `or` on both optional fields, for the same reason the rest of this file takes plain values:
  # it is documented as reusable by anything that wants to hand liblxc a container definition, and
  # a direct caller has no module system applying option defaults on its behalf. The defaults match
  # the option surface's own, so both callers render identically.
  entryLine = e:
    let
      target = rel e.target;
      options = e.options or [ "bind" "create=file" ];
    in
    # REFUSED, not rendered, because liblxc MISPARSES these rather than rejecting them and a
    # misparse is silent. An fstab line is delimited by whitespace RUNS, so an empty option
    # list renders "SOURCE TARGET none  0 0" and the fstype column is read as `0`; a target
    # that normalises away renders the source into the target column. Both produce a running
    # container missing a mount it was told to make.
    if target == "" then
      throw ("nixlxc: mount entry target ${toString e.target} is the container root; a "
        + "liblxc mount target is container-relative and must name a path under it.")
    else if options == [ ] then
      throw ("nixlxc: mount entry for ${target} has an empty option list; liblxc parses an "
        + "fstab line on whitespace runs, so an empty options column silently shifts every "
        + "field after it. State the options (\"bind\", \"defaults\", ...) outright.")
    else
      "lxc.mount.entry = ${e.source} ${target} ${e.fsType or "none"} "
      + "${lib.concatStringsSep "," options} 0 0";

  # ── Network ──────────────────────────────────────────────────────────────────────────────────
  # Indexed, because liblxc's own key is: several interfaces are `lxc.net.0.*`, `lxc.net.1.*`, and
  # the number is positional rather than a name. Rendered from list position so a caller never
  # writes an index, which is the one part of this key nothing can check.
  netLines = nets:
    lib.concatStringsSep "\n" (lib.imap0
      (i: n:
        let k = key: "lxc.net.${toString i}.${key}"; in
        lib.concatStringsSep "\n" (
          # `or` on every optional field, for the reason entryLine states: a direct caller has no
          # module system applying option defaults on its behalf, and the whole-attrset default at
          # the argument list only fires when the key is omitted ENTIRELY. Without these, a caller
          # passing `{ type; link; }` got `attribute 'up' missing` from inside this file.
          [ "${k "type"} = ${n.type}" ]
          ++ lib.optional ((n.link or null) != null) "${k "link"} = ${n.link}"
          ++ lib.optional (n.up or false) "${k "flags"} = up"
          ++ lib.optional ((n.name or null) != null) "${k "name"} = ${n.name}"
          ++ lib.optional ((n.hwaddr or null) != null) "${k "hwaddr"} = ${n.hwaddr}"
        ))
      nets);

  # ── Devices ──────────────────────────────────────────────────────────────────────────────────
  # DENY FIRST, THEN ALLOW, and the order is the whole mechanism rather than tidiness: the cgroup2
  # device filter is evaluated as written, so an allowlist printed before its deny is an allowlist
  # that never applies. A caller cannot get this wrong from here because the order is not theirs
  # to choose.
  deviceLines = devices:
    lib.concatStringsSep "\n" (
      lib.optional (devices.denyAll or false) "lxc.cgroup2.devices.deny = a"
      ++ map (a: "lxc.cgroup2.devices.allow = ${a}") (devices.allow or [ ])
    );

  # Confinement, both omittable and both meaning something when omitted. liblxc 7.0.0 ships a
  # seccomp profile for privileged containers in its own `common.conf`; a container that
  # includes no upstream config and sets neither of these runs with `Seccomp: 0` and no
  # AppArmor label. That is a valid choice and a bad accident, which is why it is stated.
  seccompLine = p: lib.optionalString (p != null) "lxc.seccomp.profile = ${p}";
  apparmorLine = p: lib.optionalString (p != null) "lxc.apparmor.profile = ${p}";

  capLine = caps: lib.optionalString (caps != [ ])
    "lxc.cap.drop = ${lib.concatStringsSep " " caps}";

  autodevLine = autodev: lib.optionalString autodev "lxc.autodev = 1";

  hookLines = hooks:
    lib.concatStringsSep "\n" (lib.optional ((hooks.preStart or null) != null)
      "lxc.hook.pre-start = ${hooks.preStart}");
in
{
  mkContainerConfig =
    { name
    , rootfsPath
    , initCmd
    , mounts
    , idmap
    , limits
    , autostart
    , extraConfig
      # Everything below is a hardware fact about the container rather than a policy this module
      # holds. Each has a value that renders NOTHING when it is left alone, so a caller that
      # declares none of them gets byte-for-byte what this renderer produced before they existed.
    , arch ? "linux64"
    , network ? [ ]
    , capsDrop ? [ ]
    , autodev ? false
    , hooks ? { preStart = null; }
    , devices ? { denyAll = false; allow = [ ]; }
    , entries ? [ ]
      # Confinement. The defaults are liblxc 7.0.0's own (`share/lxc/config/common.conf`)
      # for mountAuto, and "state it or you do not have it" for the other two. NOTE this is
      # the one argument whose default is deliberately NOT what this renderer emitted before
      # it existed: the previous hardcode was `proc:rw sys:rw cgroup:rw:force`, which a
      # container inherits only by asking for it now.
    , mountAuto ? "cgroup:mixed proc:mixed sys:mixed"
    , seccompProfile ? null
    , apparmorProfile ? null
    }: ''
    lxc.uts.name = ${name}
    lxc.arch = ${arch}
    lxc.rootfs.path = dir:${rootfsPath}
    lxc.init.cmd = ${initCmd}

    ${hookLines hooks}

    ${netLines network}

    ${capLine capsDrop}
    ${autodevLine autodev}

    # proc/sys/cgroup delegation. `mixed` mounts each read-only and then remounts the subtree
    # the container legitimately owns (its own cgroup, /proc/sys/net) writable; `rw` hands
    # over the HOST tree entire. On a PRIVILEGED container -- no idmap, host user namespace
    # -- `proc:rw` means /proc/sys/kernel/sysrq and /proc/sysrq-trigger are writable from
    # inside, so a dropped `sys_boot` capability no longer bounds reboot. Declared per
    # container rather than baked in here, because it is a confinement decision and the
    # honest place for one is the config a reader greps.
    lxc.mount.auto = ${mountAuto}
    ${seccompLine seccompProfile}
    ${apparmorLine apparmorProfile}

    ${deviceLines devices}

    ${idmapLines idmap}
    ${memoryLine limits.memoryMiB}
    ${cpuLine limits.cpuCores}
    ${autostartLine autostart}

    ${lib.concatMapStringsSep "\n" mountLine mounts}
    ${lib.concatMapStringsSep "\n" entryLine entries}

    ${extraConfig}
  '';
}
