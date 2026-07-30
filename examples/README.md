# Examples

A minimal configuration composing `nixlxc.host` + `nixlxc.containers` into a real NixOS
system. Not a machine anyone would run: `fileSystems."/"` is `tmpfs`-on-`nodev` and the
bootloader is a stub, deliberately, so this type-checks the modules rather than describes
hardware. Nothing here names a real host, path, or identity -- every value is generic
(`/var/lib/nixlxc/...`, `"media"`, `"container-base"`), the same convention nixvm's own
`examples/` states for itself.

`deliver`/`idmap.base` reference names that only resolve to something real once a host also
imports nixstorage's delivery module / nixiam's posix module -- see the inline comments in
`host/configuration.nix` and `modules/containers/README.md`'s own "deliver vs idmap" section
for exactly what each one does when that import is, and is not, present.
