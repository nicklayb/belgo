# Belgo – project notes

Homelab manager, single source of truth for devices, addresses, physical placement and
virtualisation, synchronised to AdGuard Home, OPNsense and the Omada controller.
Started from https://github.com/nicklayb/live_template (Phoenix 1.8, LiveView, Box).

## Principles (decided with the owner)

- **Files are the state.** The inventory is YAML in `BELGO_DATA_PATH`; everything else
  (topology, issues, sync desired state) is recomputed. Same files → same result. No
  database. Each file maps identifiers to entries (ids unique by design, duplicates in
  hand edits are detected by `Storage.DuplicateKeys`); keys are written sorted so git
  diffs are clean.
- **Mutations are use cases** (`Box.UseCase`, the owner's pattern, see
  `~/dev/galerie/lib/galerie/albums/use_case`). There is no Repo: `Belgo.UseCase` runs
  the `Ecto.Multi` through `Belgo.Inventory.Transaction` inside `Belgo.Inventory.Store`
  (serialised, validated against the latest snapshot, files written only if every step
  succeeded). Only `Ecto.Multi.run/3` steps are supported; use the `Transaction`
  helpers (`put/4`, `put_missing/4`, `delete/4`, `delete_existing/4`).
- **Sync must never be destructive.** Create when missing, update when existing,
  never delete; entries unknown to the inventory are left untouched. Enforced by
  `Belgo.Sync.Plan`. Divergences are shown, never reconciled automatically.
- **Providers are optional**, configured in `providers.yaml` with a `mode`
  (`disabled` | `read` default | `write`) and public options only;
  secrets come from env vars or `*_FILE` files (`Belgo.Providers.Secrets`). An invalid
  `providers.yaml` is logged and shown in the UI, never fatal.
- **Sync / discovery logs:** `debug` when a run starts, `info` on success (with
  counts), `error` on failure. The owner reads them before granting write tokens.
- **Auth = Authelia forward auth** (trusted `Remote-*` headers), kept as simple as
  possible and swappable (`BelgoWeb.Authentication` modes). `static` mode for dev.
  Belgo is never exposed outside the homelab network.
- Stateless container for Kubernetes, image built by Nix (`nix build .#dockerImage`).
- UI: modern, responsive, unified, no gratuitous animation. Built to grow: new pages
  register in `BelgoWeb.Navigation`.

## Architecture

- `Belgo.Inventory` – facade (snapshot, change, create/update/delete, reload, issues).
  - `Snapshot` – the whole inventory; `Location`, `Network`, `Device` (+ embedded
    `Interface`) are embedded schemas with slug ids (`Identifier`).
  - Device placement is exclusive: `location_id` | `host_id` (+ `virtualization`) |
    `portable` | unplaced. Hosts declare `platforms` (proxmox, docker, kubernetes).
  - `Audit` – cross-record checks (dangling refs, cycles, duplicate IP/MAC/hostname,
    IP outside network). `Changes.build/4` turns blocking issues of the edited record
    into changeset errors, so forms and hand-edited files share the same rules.
  - `References` – blocks deleting referenced records.
  - `DeniedDevice` (`denylist.yaml`, keyed by MAC) – discovered devices never suggested.
  - `Storage` behaviour, `Storage.YamlDirectory` implementation; `Codec` maps <-> structs.
  - `Store` – GenServer owning the snapshot, broadcasts `{:inventory_changed, snapshot}`.
- `Belgo.Topology.Physical` (location tree, guests under hosts, portable/unplaced),
  `Belgo.Topology.Hosting` (virtualisation tree), `DeviceNode`.
- `Belgo.Sync.DesiredState` – DNS records, DHCP reservations, client names.
  `Belgo.Sync.Plan` – non destructive diff against a target's actual entries.
- Web: `BelgoWeb.Hooks.Inventory` assigns `snapshot` and calls the view's
  `assign_inventory/1` on changes. Components in `components/{core,form,inventory}.ex`,
  semantic colour tokens (light/dark via `prefers-color-scheme`) in `assets/css/app.css`.

## Conventions

Follow the owner's global CLAUDE.md (full-word names, documented public functions,
constants instead of magic values, Simpsons test data). Also: `mix credo` (template
config forbids several pipes on one line), `mix compile --warnings-as-errors`,
`mix format`. Run `just check`.

## Gotchas

- Use `nix develop path:.` while files are untracked by git (a git flake only sees
  tracked/staged files). The dev shell needs `SECRET_KEY_BASE`/`LIVE_VIEW_SALT` (`.envrc`).
- After any `mix.lock` change, update `mixFodDeps.hash` in `flake.nix` (set
  `lib.fakeHash`, build, copy the `got:` hash).
- Running `mix compile` (dev env) while the owner's `just dev` runs compiles into the
  same `_build/dev`: the running server keeps the old code. Tell the owner to restart.
- `mix test` removes `tmp/test_inventory` first (alias): the app loads it at boot.
- Logger level in tests is `:warning`; tests capturing debug/info logs must raise it
  and run `async: false`.
- Elixir 1.19 everywhere (owner decision). Move to 1.20 once officially released
  everywhere; note that 1.20-rc could not assemble releases from the read-only Nix store
  (`File.cp_r/3` copies directory permissions before their content).
- YAML parsers keep only one of duplicated keys silently, hence `DuplicateKeys`.
- The dev shell `shellHook` ends with `eval "$(direnv hook bash)"`: keep it (owner).
- The release needs `RELEASE_COOKIE` (nixpkgs removes it); the image sets a dummy one
  with distribution disabled.

## Discovery and claiming

Providers are pulled into **observations** (never persisted, rebuilt on each pull).
`Belgo.Discovery.Correlation` (pure) merges device observations sharing a MAC or an IP
into `DiscoveredDevice`s and classifies them: ignored (denylisted MAC), claimed (a MAC
or IP is in the inventory → divergences) or unknown (suggested). Subnets missing from
the inventory become `DiscoveredNetwork`s. `Belgo.Discovery.Suggestion` prefills the
claim forms (`/devices/new?discovered=…`, `/networks/new?discovered=…`).

- `Belgo.Discovery.Server` – re-reads `providers.yaml` and pulls providers concurrently
  (Task.Supervisor) at boot and on demand; recorrelates on inventory changes;
  broadcasts `{:discovery_changed, state}`.
- `Belgo.Providers.Provider` behaviour; `Belgo.Providers.Opnsense` (Kea DHCPv4 subnets
  and reservations, Unbound host overrides) with HTTP isolated in `Opnsense.Client`
  (`HttpClient` with Req; `Belgo.Fixtures.OpnsenseClient` in tests, configured in
  `config/test.exs`). Row → observation translation is pure (`Opnsense.Translate`).
- OPNsense API facts (docs.opnsense.org, model XML on master): search endpoints
  `/api/kea/dhcpv4/search_subnet`, `/search_reservation`,
  `/api/unbound/settings/search_host_override`; writes `add_*`/`set_*/{uuid}` then
  `POST /api/kea/service/reconfigure` / `/api/unbound/service/reconfigure`.
  Reservation fields: `subnet`, `ip_address`, `hw_address`, `hostname`, `description`.
  Host override fields: `hostname`, `domain`, `rr`, `server` (the IP), `description`.
  Verified from the PHP sources (master): writes wrap fields in `reservation` /
  `host`, accept JSON bodies, `set_*` is a partial update (absent keys untouched),
  success is `{"result":"saved"}`, failure `{"result":"failed","validations":…}`;
  `reconfigure` answers `{"status":"ok"}`; search rows have `uuid`, raw values, and
  `%field` descriptions (reservation `subnet` is the subnet uuid). **Measured on the
  owner's instance:** host override search rows give `rr` as its label
  (`"A (IPv4 address)"`), with no `%rr`; `Translate.address_record?/1` keeps the
  first word. Before that fix every host override was ignored, so pushes created
  duplicates instead of updating (cleanup is manual, Belgo never deletes). Unbound aliases
  appear as `_children` of host rows (shape not verified, parsed defensively).
  The pull was validated against the owner's real instance (read-only token).

## Pushing

`Belgo.Sync.after_save/2` (from the create/update use cases' `after_run`) and the
device page button call `Belgo.Discovery.push_device/1`. The server pushes
`DesiredState.for_device/2` of that device only, so divergences of other devices are
never reconciled implicitly. `Opnsense.Push` (pure) plans Kea reservations (key MAC)
and Unbound host overrides (key host + domain) with `Belgo.Sync.Plan`; entries
without Kea subnet, without domain, or existing as Unbound aliases are skipped and
reported. Every provider has a `mode` (handled by `Settings`, owner's choice):
`disabled`, `read` (default, discovery only) or `write` (discovery + push). Unknown
provider options are rejected. Kea and Unbound
are independent (owner requirement): a push only reads the services it has
something to write to, and one failing service is logged (`error`) and reported in
`PushReport.failures` / `Report.failures` without blocking the other. An applied push
triggers a pull. Every DHCP reservation and client name of a device uses the device
hostname / name, never the interface name nor a `-1` suffix (owner: same machine); the hostname DNS record points to the
first addressed interface only, other interfaces are named through their
`dns_names`. DNS names live on interfaces (`dns_names`); `DnsRecord` carries
`host` / `domain` split for Unbound.
- `Belgo.Providers.Adguard` (AdGuard Home; API verified against the OpenAPI spec and
  the Go sources on master): basic auth, base `/control`. Purpose (owner): keep
  **persistent clients** in sync with the devices Belgo knows. The owner does not use
  DNS rewrites. Reads `GET /control/clients` (persistent → `:adguard_client`, joined
  by MAC / IP; `auto_clients` → `:adguard_auto_client`, IP + rDNS name, so most
  devices of the network show up) and `GET /control/rewrite/list` (read only).
  Writes `POST /control/clients/add` / `/control/clients/update` only.
  `clients/update` **replaces the whole client** (omitted fields reset), so updates
  resend the existing object with only `name`, `ids` (MAC/IP managed, ClientIDs and
  CIDRs kept) and `tags` changed. Only 21 tags are accepted (`device_*`, `os_*`,
  `user_*`; read from `supported_tags`): the `device_*` tag follows the device kind,
  supported Belgo tags are added, other existing tags kept. Names and ids are unique
  across clients: a device matching several clients is skipped and reported. A client
  holding a device's reserved IP is that device (renamed on push).
  Bodies must be `application/json` (v0.107.14+); success is 200 with an empty body.
- Networks have an optional DHCP range (`dhcp_start` / `dhcp_end`). Without one, the
  correlation uses the range reported by OPNsense (first Kea subnet `pools` entry,
  format `a - b` parsed defensively, **not verified on a live instance**), never
  written (`Correlation.dhcp_ranges`, shown with its source on the networks page).
  A range defined in Belgo wins; a different reported one is a divergence. Unknown
  devices whose IPs are all outside the range go to *Out of DHCP*; the menu badge
  only counts the *Out of DHCP* devices (owner: reserved / static addresses are the
  ones worth claiming; devices in the dynamic pool are not in the bubble).
- Kea reservation descriptions are managed: `Device.interface_label/2`
  (`Skynet (enp4s0)`, or the device name when the interface has no name); a
  different description is a divergence, and pushes overwrite it.
- Routing (owner): network devices have a `network_role` (gateway / switch /
  access_point, forces `kind: network`); APs and switches **are** devices. Links reuse
  `Interface.switch_id` / `switch_port`; network devices without interface (unmanaged
  switches, no MAC) use the device-level `uplink_id` / `uplink_port` instead
  ("Plugged into" in the form, used when no interface is plugged). Switches (owner) have an
  optional `port_count` and a `poe` flag (cleared for any other role); Routing shows
  `used/total ports` next to switches (`Routing.used_ports/1`: wired links plugged
  into it, a port shared by several links counts once, a link without port counts
  one, the switch's own uplink is not counted; red when over capacity), and PoE
  switches get a bolt icon (`Components.Inventory.poe_indicator/1`) in Routing, the
  device list and the device page. Live uplinks from providers (`Correlation.uplinks`, `Belgo.Discovery.Uplink`)
  win over the inventory and are never persisted (roaming must not churn git).
  `Belgo.Topology.Routing` builds links, the tree and paths (cycles cut). OPNsense
  emits its Kea subnet routers as one `:opnsense_gateway` device (shared `identity`,
  a grouping key besides MAC / IP).
- `Belgo.Providers.Omada` uses the **official Open API**, verified against the 6.3.0
  documentation (public JSON behind https://omada-northbound-docs.tplinkcloud.com:
  `/api/catalog/models/software/info.json`, guides under `/api/markdowns/…`, full
  OpenAPI spec at `/api/documents/by-doc/doc_oc_software_network_6.3.0/openapi-bundle.json`).
  Token: `POST /openapi/authorize/token?grant_type=client_credentials`
  `{omadacId, client_id, client_secret}` → `result.accessToken` (2 h); header
  `Authorization: AccessToken=<token>`. `GET /openapi/v1/{omadacId}/sites`
  (`siteId`, `name`), `…/sites/{siteId}/devices` (`type` ap / gateway / switch,
  `uplinkDeviceMac`, `uplinkDeviceName`, `uplinkDevicePort`), `…/clients` (`apMac`,
  `ssid`, `switchMac`, `gatewayMac`, `port`, `clientLockToApSetting.enable`), rename
  `PATCH …/clients/{clientMac}/name` `{name}`; pages `page` / `pageSize` ≤ 1000;
  MACs `AA-BB-…`. `omada_id` option is the Omada ID shown with the application
  (fallback `GET /api/info`, not in the official docs). Only clients are renamed.
  Owner's controller: 6.3.0.111.
- Every provider accepts `interval` (Settings, common like `mode`); the server keeps
  one timer per provider, rescheduled after each pull.
- Discovery: a discovered device can be attached to an existing device
  (`UseCase.AttachToDevice`, fuzzy pre-selection by `Belgo.Discovery.Matching`).
- DNS records come **only** from interface `dns_names` (owner): the device hostname
  never creates one (it still names DHCP reservations). Claiming puts every DNS name
  a provider reports for an IP into that interface's `dns_names`.
- Unbound duplicates (several host overrides for one host + domain) are
  `Correlation.conflicts` (with `owner_id` when the name belongs to a device, then
  also a divergence of it); OPNsense pushes skip duplicated names. Overview lists
  issues, divergences and unowned conflicts; its menu badge counts them
  (`Navigation.badges/2`, recomputed by both the inventory and discovery hooks).
- Device `metadata`: embedded `MetadataEntry` list (`label`, `value`, both required,
  labels unique per device, suggested labels in `MetadataEntry.suggested_labels/0`);
  no empty predefined fields (owner).
- `Belgo.Search` (pure) powers the global search modal (`Components.SearchModal`, a
  LiveComponent rendered once in `Layouts.app`) and the *Out of DHCP* filters
  (text + provider). Known devices by default, discovery on demand. The modal is a
  native `<dialog>` opened **in the browser** by the `SearchDialog` hook
  (`assets/js/hooks/search_dialog.js`) from `[data-search-open]` or Ctrl/⌘+K:
  `showModal()` + `focus()` run in the click / key handler, because a focus
  requested after a server round trip (or `JS.focus`, deferred by
  `requestAnimationFrame`) can be ignored (Safari, owner wants the field focused).
  `JS.ignore_attributes("open")` keeps it open across patches; `app.js` still
  prevents the browser's own Ctrl+K.
- Embedded list forms (metadata, interfaces): the "Add" button sits above the entries,
  so the browser sends `*_sort[] = new` first; `Inventory.SortParams.new_last/2` puts
  new entries last (else the new row takes index 0 and fields being typed in swap).
  Changes to embedded entries must update their changesets in place (`update_change`),
  never `put_embed` rebuilt structs: that resets `_persistent_id` and mixes up inputs.
- `<main>` is `relative`: absolutely positioned children (`sr-only`) would otherwise
  extend the document and make the whole app scroll on long pages.
- DNS observations (`Observation.dns_record?/1`) are also claimed by **name**: a name
  the inventory owns pointing elsewhere is a divergence of that device, not an
  unknown device.
- Provider option helpers are shared in `Belgo.Providers.Options`.
- `Belgo.Providers.HomeAssistant` (owner: **read only**, to create locations). Reads
  the floor and area registries over the WebSocket API (`mint_web_socket`, one
  connection per pull): `auth_required` → `{"type":"auth","access_token"}` →
  `auth_ok` / `auth_invalid`; commands `config/floor_registry/list` (`floor_id`,
  `name`, `level`, …) and `config/area_registry/list` (`area_id`, `name`, `floor_id`,
  …), verified in `homeassistant/components/config/{floor,area}_registry.py` (dev):
  no `require_admin` on list. `POST /api/template` was rejected: `@require_admin`.
  Not yet validated against the owner's instance; the client is tested against a
  local Bandit WebSocket server speaking the documented protocol.
  Observations have `kind: :location`, `reference` `floor/<id>` / `area/<id>`
  (`Location.home_assistant_id` format), `parent_reference`, `level`.
  `Belgo.Discovery.Locations` (pure) matches by `home_assistant_id`, else by unique
  name among unlinked locations; new ones are `Correlation.new_locations` (floors by
  level then their areas), divergences: rename (linked only), floor not an ancestor.
  Claim suggestion: parent = the floor's location, else the only top-level
  site / building. Audit: one location per `home_assistant_id`.
  Gotcha (fixed, tested with a raw `:gen_tcp` server): HA sends `auth_required` right
  after the 101, often in the same packet; Mint returns those bytes as `:data` of the
  upgrade request, they must be decoded once the WebSocket exists (else the client
  waits and HA closes with 1000 after its 10 s auth timeout).
- Page filters use `Box.DataFilter` (box ≥ 0.19.0; owner's pattern, see
  `~/dev/ivhs_broker/lib/ivhs_broker/cards/filter.ex`): a domain filter module
  (`Inventory.DeviceFilter`, `Discovery.OutOfDhcpFilter`, `apply` on lists), the form
  built on `to_query_params/1`, `update/2` on change, then `push_patch(replace: true)`
  to `?…` and `handle_params` → `new(params)`: back navigation restores the filter.
  Defaults are left out of the URL. `box` itself emits typing warnings (`Box.Color`).
- Devices list: kind boxes (icon, label, count) replace the kind select; several
  kinds can be selected (`DeviceFilter.kinds`, `kinds=a,b` in the URL); only kinds
  with devices matching the other criteria are shown (`DeviceFilter.kind_counts/2`),
  plus selected ones.
- Bulk edit (owner): rows have checkboxes (`table` col `skip_row_click`), "Edit" opens
  `/devices/bulk-edit?ids=a,b&<list filter>`. `Inventory.BulkEdit` (pure) changes the
  kind, placement (location / portable / unplaced) and metadata; conflicts are
  overwritten (owner): same label (case insensitive) replaced, other entries kept, a
  non-network kind drops `network_role`. `UseCase.UpdateDevices` saves every device
  or none (steps `{:device, id}`), then pushes each.
- Global settings: `config.yaml` next to the inventory (`Belgo.Config`, read when
  needed, invalid → logged, defaults; `Config.current/0` uses `config :belgo,
  Belgo.Config, directory:`). `theme: auto | light | dark` (owner):
  `Plugs.Theme` assigns it, the root layout sets `<html data-theme>`; colour tokens
  are `light-dark(light, dark)` in `app.css`, driven by `color-scheme` (auto: `light
  dark`), so there is a single token list and native controls follow the theme. Durations parsed by `Belgo.Duration` (shared
  with provider `interval`).
- Reachability (owner): a dot next to device names (green up / red down / yellow
  pending) on the device page (click = ping now), the device list and Discovery
  (unknown and out of DHCP devices). Pages ping on display (connected only); the
  discovery server also pings `Correlation.discovered_addresses/1` after each pull
  (owner: see quickly which discovered devices do not answer).
  `Belgo.Reachability.Server` keeps one `AddressStatus` per **address** (shared by
  inventory and discovery), in memory, reused for `ping.cache_duration` (default
  15m); an address being pinged is never pinged twice; at most 32 pings at a time
  per check. Pending addresses are broadcast at once, results grouped every 250 ms
  (`{:reachability_changed, [AddressStatus]}` on topic `reachability`).
  `Reachability.Status.build/2` aggregates a device: up = at least one IP answers.
  Views use `BelgoWeb.Live.Reachability` (subscribe / check / changed / status).
  The overview's Devices stat (owner) pings every device on display and shows how
  many do not answer (`Status.count_states/2`; "Pinging…" / "All answer" otherwise,
  devices without address left out).
  `Reachability.Pinger` runs iputils `ping -n -c 1 -W s` (exit 0 answered, 1 not;
  measured on the owner's machine, unprivileged ICMP allowed by systemd's
  `ping_group_range`); `BELGO_PING_PATH` set in the image (busybox also has a ping).
  Tests inject `:ping` and `:clock`.
- Git versioning (owner): `git` in `config.yaml` (`Config.Git`, absent = disabled).
  `Belgo.Versioning.Server` inits the data directory as its **own** repository
  (`.git` in it; a parent repository does not count, e.g. `./data` in dev), commits
  at boot, then debounces `{:inventory_changed, _}` by `commit_delay` (5m) and
  commits on terminate (`trap_exit`). Pushes `HEAD` every `push_interval` (1h) to
  `remote` (URL or name) / `branch` in a task, skipped when unchanged since the last
  push. **Never pulls, never forces** (owner). Commands in `Versioning.Git`
  (`BELGO_GIT_PATH`, `safe.directory` = the directory, `GIT_TERMINAL_PROMPT=0`,
  identity and `commit.gpgsign=false` via `-c`). HTTPS token `BELGO_GIT_TOKEN`
  sent as a basic `http.extraHeader` through `GIT_CONFIG_*` env (never in argv).
  The image ships `gitMinimal` and `GIT_SSH` (openssh). Tests use real git in
  `tmp_dir` with a bare remote.
- Discovery *DNS names* (owner): `Belgo.Discovery.DnsNames` (pure) lists DNS
  observations whose name Belgo does not own (no `DesiredState` record, not a
  conflict) and whose IP is an inventory interface's (`Correlation.dns_names`,
  `DiscoveredDnsName` with suggested `device_id` / `interface_index`). Claim page
  `/discovery/dns-names/:id` (`Discovery.Live.ClaimDnsName`, back to Discovery with
  a flash linking the device, `BelgoWeb.FlashMessage`): device + addressed
  interface selects, warning when the interface IP differs; `UseCase.ClaimDnsName`
  appends the name (short when its domain is the interface network's,
  `DnsNames.stored_name/2`) then pushes. The name also stays a divergence of the
  device until claimed.
- Wake-on-LAN (owner): *Wake* button per interface with MAC on the device page.
  `Belgo.WakeOnLan.wake/3`: `MagicPacket` (pure), `Sender` (`:gen_udp` broadcast
  port 9 to `255.255.255.255` + the network's last address), then a `Watch`
  (GenServer under `Belgo.WakeOnLan.Supervisor`, one per device via
  `Belgo.WakeOnLan.Registry`) pings every `wake_on_lan.ping_interval` (5s) until up
  or `wake_on_lan.timeout` (1m, a last ping at the timeout), broadcasts
  `{:wake_on_lan, Outcome}` on `wake_on_lan`. `BelgoWeb.Hooks.Notifications`
  (on_mount of every page) turns it into a flash wherever the owner is. Tests
  inject `send` / `ping` (`config :belgo, Belgo.WakeOnLan`, fixtures never touch the
  network).
- Open ports (owner: never disturb the device): `Belgo.PortScan.Server` (like
  Reachability: per address, in memory, `port_scan.cache_duration` 1h, pending
  broadcast then result, `{:port_scan_changed, [AddressScan]}` on `port_scan`).
  `Scanner` = TCP connect + immediate close, nothing sent, 8 concurrent,
  `port_scan.timeout` 1s, only `PortScan.Ports` (~40 common ports with service
  names); no SYN scan (needs raw sockets). Device page card with *Refresh*
  (force). Tests inject `:scan` (`Belgo.Fixtures.PortScanner`).
- Search dialog keyboard: arrows move a `data-active` highlight over
  `[data-search-result]` links while the focus stays in the field (wraps), Enter
  follows it (the first result by default); typing resets it, `updated()` puts it
  back after patches.
- Collapsible cards (owner): `card` with `collapse_key` (and `collapsed` for a closed
  default) renders a `<details>` with the `Collapsible` hook, which stores the
  choice in `localStorage` (`belgo:collapsible:<key>`), so it survives page changes
  and reloads; `JS.ignore_attributes("open")` keeps it across patches. Used by every
  Discovery card, *Unknown devices* collapsed by default (owner). The stored state is
  applied when the hook mounts (a closed default may show open for an instant).
- Linked flashes render segments on one line (`flash_segment`): the message `<p>`
  is `whitespace-pre-line` for plain strings, multi-line HEEx made a huge block.
- Virtual IPs (owner): collection `virtual_ips` (`Inventory.VirtualIp`: name, ip,
  network_id, kind metallb | kube_vip | keepalived | other, owner_id device,
  dns_names, notes). `DesiredState` adds their DNS records (`DnsRecord.virtual_ip_id`,
  `DnsRecord.owner/1`), never DHCP / clients; `for_owner/2` filters by
  `{:devices | :virtual_ips, id}`; pushes go through `Discovery.push_virtual_ip/1`
  (`Sync.after_save(:virtual_ips, …)`). Audit: unknown network / owner, outside the
  network, in the DHCP range (warning), address shared with an interface or another
  virtual IP (error on every user), DNS names shared between devices and virtual IPs.
  References: owner device and network cannot be deleted. Correlation:
  `release_floating_mac` drops the MAC of AdGuard / Omada client observations on a
  virtual IP (MetalLB L2 answers ARP with the leader node MAC), virtual IPs claim
  observations by IP and DNS name, divergences use collection `:virtual_ips`;
  `DnsNames` can suggest a virtual IP (`virtual_ip_id`), the claim page target is
  `devices:<id>` or `virtual_ips:<id>`. Pages `/virtual-ips` (list, show with DNS
  names / ports / divergences, form; `?discovered=` from an unknown address,
  `?owner_id=` from the owner's page). Measured on the owner's network: the MetalLB
  address 192.168.1.110 ignores pings but serves 80 / 443, hence
  `Reachability.Status.with_open_ports/2` (virtual IP pages count open ports as up).
  `BelgoWeb.Live.PortScans` and `Components.Inventory.open_ports/1` are shared with
  the device page.
- Devices list sorting (owner): `Inventory.DeviceSorting` (pure: name, placement
  label, first IP; missing values last) through `DeviceFilter` `sort` / `direction`
  (in the URL, defaults left out), sortable headers of `table`.
- Reserved address check (owner): `Discovery.ReservedAddresses.conflicts/2`: a
  reserved interface on an address a Kea reservation holds for another MAC (from
  `Discovery.State.observations/1`). Device form only (validate + refused save):
  inventory duplicates were already Audit errors. Not enforced in use cases (the
  discovery state is not part of the inventory).
- Logical ranges (owner): `Network.ranges` (embedded `AddressRange`: name, start,
  end, optional device kind; inside the network, no overlap; sort / drop params
  `ranges_sort` / `ranges_drop`). `Inventory.AddressAllocation` (pure):
  `used_addresses/3` (inventory but the edited device, virtual IPs, gateways, every
  observation IP), `suggest/4` (first free, never network / broadcast address),
  `suggest_params/4` for the device form `validate` event: on a kind change, fills
  interfaces without IP or outside the kind's ranges (network set, dynamic becomes
  reserved / static); an added interface (`"new"` sort entry, materialised as an
  index) is filled too. The form shows the range under the IP while it holds the
  suggestion (`address_suggestions`). Editing never changes an address by itself
  (owner: a Media TV outside the Media range): `suggest_interfaces/4` offers the
  next free address under the IP (`range_suggestions`, `#range-suggestion-<i>`), the
  button fills the field through `JS.dispatch("belgo:set-value")` (listener in
  `app.js`), which then sends the change like typing.
- Stale address divergence (owner): an Omada client (live source, `@live_address_sources`)
  whose MAC belongs to a reserved / static interface but seen at another IP is a
  device divergence ("… is seen at X, Belgo assigns Y: restart it (or renew its DHCP
  lease)…"), in Overview and on the device page. AdGuard persistent clients are
  configuration Belgo pushes (not live), auto clients have no MAC: not used.
  Measured on the owner's network: Sony Bravia seen at .158, assigned .37.
- Hosting page grouped by platform (owner): `Hosting.groups/1` – Proxmox (VM, LXC
  guests), Docker and Kubernetes (container guests), each host with its direct guests
  of that platform and the hosts it runs on; a VM running Docker is a guest under
  Proxmox and a host under Docker. Unmatched guests / platformless hosts: "Other".
  `Hosting.build/1` (nested tree) is still used by the dashboard count.
- HA WebSocket: a close frame decoded with earlier messages (`auth_invalid` + close
  in one packet) keeps those messages.
- Location page (`/locations/:id`): `Physical.devices_within/2` lists every device
  inside, sub-locations and guests (via their hosts) included.
- Discovery: a failed provider (error or partial failures) has its own Refresh
  (`Discovery.refresh_provider/2`). *Out of DHCP* sorts by device or address
  (`Discovery.Sorting`, pure; sortable headers through `table`'s `sort_event`/`sort`).
- Metadata labels are indexed (`Inventory.MetadataLabels`): labels used by devices
  (most used spelling wins) then suggested ones, fed to the form's `<datalist>`
  (browser filtering, case insensitive). `Changes.build` rewrites a typed label to the
  indexed spelling (`brand` → `Brand`).
  Values are indexed per label too (`MetadataLabels.values/1`): each value input
  points to the datalist of its label's values (every value when the label is blank
  or new), see `Components.Inventory.metadata_datalists/1`. A just added entry
  (blank label) focuses its label with `phx-mounted={JS.focus()}` (`Form.blank?/1`),
  so loading a page never steals the focus.
- Sources (owner's plan): networks ← OPNsense; locations ← Home Assistant floors/areas;
  devices ← OPNsense, AdGuard Home (rewrites join by IP, clients by MAC), Omada
  (software controller in Docker, latest version, Open API; joins by MAC).

## Roadmap

1. Validate Omada and Home Assistant against the owner's instances; maybe rename
   Omada network devices too (the Open API has device endpoints, see the spec).
2. Watch the data directory (file_system) to reload automatically after git pulls.
3. Switch ports view (who is plugged where), rack / physical map visuals.
4. Kubernetes manifests.
5. French translation (gettext).
