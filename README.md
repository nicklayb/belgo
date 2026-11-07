# Belgo

Homelab manager: the single source of truth for the machines of the network, where
they physically are, what runs on what, and the DNS / DHCP / client names AdGuard
Home, OPNsense and Omada must agree on. The inventory is a set of YAML files you
can edit by hand and version with git; there is no database.

## Features

* Inventory of devices, interfaces, networks (with named address ranges), locations
  and virtual IPs, with consistency checks (duplicate addresses, dangling links…).
* Discovery from OPNsense, AdGuard Home, Omada and Home Assistant: unknown devices,
  networks and locations to claim, divergences to reconcile.
* Non-destructive sync: DHCP reservations, DNS names and client names are pushed to
  the providers, never deleted.
* Physical, hosting and routing views; device reachability, open ports and
  wake-on-LAN.
* Home plan in 2D and 3D with devices placed in their rooms.
* English and French interface.

Details: [docs/guide.md](docs/guide.md).

## Deployment

```sh
just docker-build   # nix build .#dockerImage + docker load
```

Run the image with a writable volume on `/data` (the inventory files) and at least
`SECRET_KEY_BASE`, `LIVE_VIEW_SALT` and `APP_HOST`. Put it behind Authelia's forward
auth (trusted `Remote-*` headers); Belgo is meant for the internal network only.
Providers are optional (`providers.yaml`, secrets in environment variables). See the
[configuration](docs/guide.md#configuration) and
[deployment details](docs/guide.md#deployment-details).

## Development

```sh
nix develop
just seed     # copies examples/inventory to ./data
just setup
just dev      # http://localhost:4000
just check    # format, warnings, credo, tests
```

`.envrc` provides development defaults (static user, `./data`).
