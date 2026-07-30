# lxc-host

The declarative LXC stance for one host: liblxc enabled, `lxcpath` declared, and the upstream
`lxc.service`/`lxc-autostart` boot-time pass wired up so a container's own `autostart` flag
(rendered by `modules/containers`) means something. See the module's own header comment for
the full SCOPE block (owned vs. explicitly not-owned).

## Options

| Option | Type | Default | Description |
|---|---|---|---|
| `nixlxc.host.enable` | bool | `false` | Enable the module. |
| `nixlxc.host.containersPath` | null or str | **no default** | `lxcpath` — the existing directory liblxc stores/reads containers under. Never created by this module — set it to a directory your own host storage provisioning already brings up. |

## Why `lxc.service`, not a bespoke nixlxc autostart unit

`pkgs.lxc` ships a real upstream systemd unit whose `ExecStart` runs `lxc-containers start`,
which calls `lxc-autostart` — the exact upstream mechanism for "start every container under
`lxcpath` whose own config carries `lxc.start.auto = 1`" at HOST boot. Enabling it (via
`systemd.packages` + a `systemd.services.lxc` override, mirroring how NixOS's own
`nixos/modules/virtualisation/lxc.nix` wires up `lxc-net.service` for unprivileged containers)
is all this module does — it never calls `lxc-start`/`lxc-stop` itself.

This is the identical boundary nixvm's own `modules/guests` draws around `virsh autostart`:
"autostart is the one exception worth naming explicitly — it only affects behavior at the
HOST's next boot, never a live container's current state."

## Starting and stopping a container, day to day

Neither this module nor `modules/containers` ever starts, stops, or restarts a container.
`pkgs.lxc` ships a real, per-container systemd template unit for exactly that:

```
systemctl start lxc@example-container
systemctl stop  lxc@example-container
```

(or `lxc-start -n example-container -P <containersPath>` / `lxc-stop` directly). Both are
always an operator action.

## Minimal example

```nix
{
  imports = [ nixlxc.nixosModules.lxc-host ];

  nixlxc.host = {
    enable = true;
    containersPath = "/var/lib/nixlxc/containers";
  };
}
```

## Status

First cut. Not yet re-verified against a live host with a real container running — see the
repo README's "Status" section.
