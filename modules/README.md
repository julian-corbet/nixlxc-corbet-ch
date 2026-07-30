# Modules

- `lxc-host/` — the LXC host stance: liblxc enabled, `lxcpath` declared (never created), the
  upstream `lxc.service`/`lxc-autostart` boot-time pass wired up. What makes a machine able to
  host LXC containers at all.
- `containers/` — container definitions, as data: per-container `rootfs`/`idmap`/`limits`/
  `autostart`, and WHICH `nixstorage.delivery.categories` each one receives (`deliver`),
  rendered to a real liblxc `.config` document and kept materialized at its `lxcpath`
  location. What runs on the host. Always composed alongside `lxc-host` — see that module's
  own "ALWAYS COMPOSED WITH" note.
