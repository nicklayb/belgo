# Belgo guide

Detailed documentation; see the [README](../README.md) for an overview.

## Data

The inventory lives in YAML files (`locations.yaml`, `networks.yaml`,
`devices.yaml`, `virtual_ips.yaml`, `plans.yaml`, `denylist.yaml`) in
`BELGO_DATA_PATH`, each mapping identifiers to entries. Nothing else is persisted: the same files
always give the same result. Files can be edited by hand (then use *Reload files* in *Settings*)
and versioned with git. See `examples/inventory` for the format.

## Global settings

`config.yaml`, next to the inventory files (see `examples/inventory/config.yaml`),
holds settings that are not about providers. Every key is optional:

* `theme` (`auto`): `auto` follows the system, `light` and `dark` force a theme
  (applies on the next page load).
* `ping.cache_duration` (`15m`): devices are pinged and shown with a dot (green:
  answers, red: no answer, yellow: checking) on the device page, the device list
  and Discovery. Unknown devices are pinged as soon as a provider reports them.
  Results are kept per address, in memory only, and reused this long; clicking the
  dot on a device page pings again right away.
* `ping.timeout` (`2s`): how long to wait for an answer.
* `wake_on_lan.ping_interval` (`5s`) / `wake_on_lan.timeout` (`1m`): the *Wake*
  button of an interface (with a MAC address) sends a wake-on-LAN magic packet (UDP
  broadcast on port 9, to `255.255.255.255` and to the broadcast address of the
  interface network), then pings the device this often until it answers or the
  timeout elapses; a notice tells either way, on whatever page is open. Broadcasts
  do not cross routers: Belgo must be on the device's network (host networking in a
  container) unless the router forwards directed broadcasts.
* `port_scan.cache_duration` (`1h`) / `port_scan.timeout` (`1s`): a device page
  lists the TCP ports of its addresses that accept connections, among about forty
  common ones (SSH, HTTP(S), SMB, Proxmox, Home Assistant, Plex…). Each check is a
  plain connection closed right away, nothing is sent, eight at a time: no
  privilege needed and nothing that disturbs the device (its services may log a
  closed connection). Results are kept in memory; *Refresh* checks again.
* `git` (absent: disabled, `git:` alone uses the defaults): versions the data directory. Belgo makes it a git
  repository when it is not one yet and commits changes once the files are left
  alone for `git.commit_delay` (`5m`), and before stopping. Commits are authored by
  `git.author_name` / `git.author_email` (`Belgo` / `belgo@localhost`).
  With `git.remote` (a URL or a remote name), new commits are pushed every
  `git.push_interval` (`1h`) to `git.branch` (the current branch by default).
  Belgo never pulls nor forces: when the remote moved on, the push fails and is
  logged until you reconcile it by hand. Credentials never go in the files: SSH
  remotes use your SSH setup (`GIT_SSH_COMMAND="ssh -i … -o UserKnownHostsFile=…"`
  in a container), HTTPS remotes the `BELGO_GIT_TOKEN` secret (and
  `BELGO_GIT_USERNAME`, `x-access-token` by default; both accept `_FILE`).

## Discovery

Providers are optional and configured in `providers.yaml`, next to the inventory files
(see `examples/inventory/providers.yaml`). Each has a `mode`: `disabled` (not used),
`read` (discovery only, the default) or `write` (discovery and push). Belgo pulls them at boot and on demand,
then suggests what they know and the inventory does not: claim a suggestion to save
it, or ignore it (its MAC addresses go to `denylist.yaml`). Differences with records
already in the inventory are shown as divergences, reconciled manually.

DNS names reported by a provider (Unbound host overrides) that resolve to the
address of a known device without belonging to it in Belgo are listed in *DNS
names*: claiming one preselects the interface holding that address (another device
and interface can be chosen) and adds the name to the interface.

A network can declare its DHCP range (dynamic pool). When it does not, the range
reported by OPNsense (first Kea pool of the subnet) is used, without being written.
Unknown devices whose addresses are all outside that range (static or reserved
addresses) are listed apart, in *Out of DHCP*.

| Provider | Reads | Writes | Secrets |
| --- | --- | --- | --- |
| OPNsense | Kea DHCPv4 subnets and reservations, Unbound host overrides | Kea reservations, Unbound host overrides | `BELGO_OPNSENSE_API_KEY`, `BELGO_OPNSENSE_API_SECRET` |
| AdGuard Home | Persistent and automatic clients (joined by MAC / IP), DNS rewrites | Persistent clients | `BELGO_ADGUARD_USERNAME`, `BELGO_ADGUARD_PASSWORD` |
| Omada (Open API) | Devices (gateway, switches, APs and their uplink), connected clients (AP / switch port, Wi-Fi, Lock to AP) | Client names | `BELGO_OMADA_CLIENT_ID`, `BELGO_OMADA_CLIENT_SECRET` |
| Home Assistant | Floors and areas (suggested as locations) | Nothing (read only) | `BELGO_HOME_ASSISTANT_TOKEN` |

Omada uses its official Open API: create an application in client mode in the
controller (Settings > Platform Integration > Open API) and give Belgo its client ID
and secret, plus the Omada ID shown with it (`omada_id`).

Home Assistant floors become `floor` locations and areas become `room` locations
inside their floor. A claimed location keeps the link in `home_assistant_id`
(`floor/<floor_id>` or `area/<area_id>`), so a rename or a move to another floor in
Home Assistant shows as a divergence. Existing locations with the same name are
recognised without link. The token is a long-lived access token (profile > Security);
a non-administrator user is enough (registries are read over the WebSocket API).

Every provider accepts `interval` (`30s`, `5m`, `1h`…) to be pulled periodically:
new devices show up in Discovery and devices moving between access points are
followed.

Each device becomes an AdGuard Home persistent client named after it and identified
by its MAC and IP addresses. Existing clients (matched by address, else by name) are
updated without touching their other settings (filtering, blocked services,
ClientIDs…). The `device_*` tag follows the device kind and Belgo tags AdGuard
supports (`os_linux`, `user_child`…) are added. DNS rewrites are read, never written.

Every secret can also be given as a file with the `_FILE` suffix (Docker / Kubernetes
secrets). Pulls and pushes log `debug` when they start, `info` on success and `error`
on failure.

### Pushing

Saving a device (or its *Push* button) pushes its DHCP reservations and DNS names to
the providers in `write` mode: missing entries are created, differing ones updated,
**nothing is ever deleted** and other devices are left untouched. The last push of
each provider is shown in *Discovery*.

DNS names belong to an interface address: a short name gets the network domain
(`plex` → `plex.home.lan`), a name with a dot is used as is. The device hostname only
names DHCP reservations, it never creates a DNS record. Names duplicated in Unbound
are shown in *Overview* and never written until fixed in OPNsense.

## Logical ranges

A network can name parts of itself (`.1`–`.5` routing, `.10`–`.20` servers, `.70`–`.110`
IoT…) in its form. A range tied to a device kind suggests addresses: choosing that
kind for a device (or adding an interface to it) fills its interfaces without
address, or outside the range, with the first address of the range nothing uses
(inventory, virtual IPs, gateways, and every address providers report). The hint
under the field tells where it comes from; edit it freely.

A DHCP reservation on an address OPNsense already reserves for another MAC address
is refused by the device form (the push would fail).

## Virtual IPs

Addresses that are not machines (a MetalLB or kube-vip load balancer address, a
keepalived floating address) live in `virtual_ips.yaml`: name, IP, network, kind,
owner device (the cluster or host answering for it) and DNS names. Their DNS names
are pushed as Unbound host overrides like device ones; they never get a DHCP
reservation nor a client name. Discovery recognises them: the MAC address a client
table reports with a virtual IP (whichever node answers right now) never ties it to
that node, DNS names pointing to it can be claimed for it, and an unknown address
can be claimed as a virtual IP. Load balancer addresses often ignore pings: one
accepting TCP connections counts as answering.

## Routing

Network devices (`kind: network`) have a role: gateway, switch or access point. They
form the *Routing* tree, with the devices connected to each. A device is connected
where its interface's *Switch* says, or where Omada sees it right now (live, never
written to the files). Unmanaged switches are devices without interface: their
"Plugged into" field links them to the upstream switch and port. Each device page shows its network path up to the gateway. OPNsense
announces itself as the gateway of its Kea subnets.

## Home plan

*Plan* draws the home level by level (rooms made of rectangles on a centimetre grid,
doors and openings on walls, levels stacked or half a level up, each with its own
heights) and places devices in rooms: on the floor, on a wall at a height, or
floating, as a point or a box (width, depth, height). Rooms can be anchored to each
other so they follow their parent. The plan is stored in `plans.yaml`; nothing else
refers to it. The 3D view filters devices by kind, can hide the exterior walls, the
device labels and the room names, remembers the camera in the browser, and a click
on a device draws its network path. Hosted devices (VMs, containers) are where
their host is and are not placed.

## Languages

The interface is in English and French and follows the browser language. The
*Settings* page (the user button at the bottom of the menu) forces a language for
this browser (kept in its local storage).

## Configuration

| Variable | Default | |
| --- | --- | --- |
| `BELGO_DATA_PATH` | – | Directory of the inventory files (`/data` in the image) |
| `BELGO_AUTHENTICATION` | `trusted_headers` | `trusted_headers` (Authelia) or `static` |
| `BELGO_STATIC_USERNAME` / `BELGO_STATIC_NAME` | `admin` / `Administrator` | User of the `static` mode |
| `SECRET_KEY_BASE`, `LIVE_VIEW_SALT` | – | Phoenix secrets |
| `APP_HOST`, `PORT` | `http://localhost:4000`, `4000` | Public URL and listening port |
| `BELGO_LOG_LEVEL` | `info` | `debug`, `info`, `warning` or `error` (release only) |
| `BELGO_GIT_REMOTE` / `BELGO_GIT_BRANCH` | – | Override `git.remote` / `git.branch` of `config.yaml` (one branch per instance sharing the data repository) |

### Authentication

Belgo does not handle credentials. Put it behind Authelia's forward auth: the
`Remote-User`, `Remote-Name`, `Remote-Email` and `Remote-Groups` headers are
trusted. Belgo is meant for the internal network only, reached through the proxy.
`/health` is not authenticated, for probes.

## Deployment details

The image runs as `nobody` (65534) and expects a writable volume on `/data`.

Belgo pings devices (iputils `ping`, `BELGO_PING_PATH`). As `nobody`, this
needs unprivileged ICMP: on Kubernetes, allow it with the safe sysctl
`net.ipv4.ping_group_range: "0 2147483647"` in the pod `securityContext.sysctls`
(or grant `CAP_NET_RAW`). Most systemd hosts already allow it.

## Docker

Released images are on Docker Hub as `nboisvert/belgo`, tagged with their version
(`0.1.0`) and `latest`. Generate the Phoenix secrets once and keep them (changing
them signs everyone out):

```sh
openssl rand -base64 64   # SECRET_KEY_BASE
openssl rand -base64 24   # LIVE_VIEW_SALT
```

The image runs as `nobody` (65534): the data directory must be writable by it.

```sh
mkdir -p /srv/belgo && sudo chown 65534:65534 /srv/belgo

docker run -d --name belgo --restart unless-stopped \
  -p 4000:4000 \
  -v /srv/belgo:/data \
  -e SECRET_KEY_BASE=… \
  -e LIVE_VIEW_SALT=… \
  -e APP_HOST=https://belgo.home.lan \
  --sysctl net.ipv4.ping_group_range="0 2147483647" \
  nboisvert/belgo:latest
```

* The `sysctl` lets `nobody` ping devices (unprivileged ICMP); without it, every
  device shows as not answering. Recent Docker versions (20.10+) already set it,
  stating it keeps older engines and other runtimes working.
* Wake-on-LAN broadcasts do not leave a bridged container: use `--network host`
  (then `-p` is ignored and Belgo listens on `PORT`) if you need it.
* Provider secrets are environment variables (`-e BELGO_OPNSENSE_API_KEY=…`), or
  files with the `_FILE` suffix (Docker secrets).
* `-e BELGO_AUTHENTICATION=static` skips Authelia to try Belgo out: anyone reaching
  the port is then the static user.
* An empty `/data` starts an empty inventory; `examples/inventory` shows the format.

The same with Docker Compose:

```yaml
services:
  belgo:
    image: nboisvert/belgo:latest
    restart: unless-stopped
    ports:
      - "4000:4000"
    volumes:
      - /srv/belgo:/data
    environment:
      SECRET_KEY_BASE: …
      LIVE_VIEW_SALT: …
      APP_HOST: https://belgo.home.lan
    sysctls:
      net.ipv4.ping_group_range: "0 2147483647"
```

To build the image locally instead: `just docker-build` (`nix build .#dockerImage`,
then `docker load`; the image is `belgo:<version>`).

## Kubernetes

The Helm chart lives in `charts/belgo` (its `version` and `appVersion` follow
`VERSION`; `just chart-check` lints it, runs its unit tests in `charts/belgo/tests`
and validates the examples of `charts/belgo/ci` against the Kubernetes schemas).
It does not depend on a GitOps tool: install it with `helm`, or point Flux /
Argo CD at the `charts/belgo` path of this repository.

```sh
kubectl create namespace belgo
kubectl --namespace belgo create secret generic belgo \
  --from-literal=SECRET_KEY_BASE="$(openssl rand -base64 64)" \
  --from-literal=LIVE_VIEW_SALT="$(openssl rand -base64 24)" \
  --from-literal=BELGO_GIT_TOKEN=…
helm install belgo ./charts/belgo --namespace belgo --values my-values.yaml
```

What the chart does, and why:

* **One replica, `Recreate`.** The files are the state, owned by one process: the
  chart never scales Belgo nor runs two pods on the volume.
* **`/data` on a PersistentVolumeClaim** (default StorageClass, `ReadWriteOnce`,
  kept by `helm uninstall`), or `persistence.existingClaim`.
* **Secrets never in the values:** `existingSecret` (required) is loaded as
  environment variables; it holds `SECRET_KEY_BASE`, `LIVE_VIEW_SALT`, provider
  secrets and `BELGO_GIT_TOKEN`. Create it by hand or with any secret tool (SOPS,
  Sealed Secrets, External Secrets).
* **Data repository:** `git.remote` / `git.branch` set `BELGO_GIT_REMOTE` /
  `BELGO_GIT_BRANCH` (git itself is enabled by `config.yaml`). With
  `git.clone.enabled`, an init container clones the repository into an empty
  volume on the first start, from `git.clone.sourceBranch` (e.g. `main`) onto
  `git.branch` (e.g. `cluster`); an existing repository is never touched, and
  Belgo never pulls. SSH remotes: mount a key with `extraVolumes` /
  `extraVolumeMounts` and set `GIT_SSH_COMMAND` in `extraEnv`.
* **Hardened:** runs as 65534 with `fsGroup` (writable volume), read-only root
  filesystem (an `emptyDir` on `/tmp`, also `HOME`), no capability, no service
  account token; the safe sysctl `net.ipv4.ping_group_range` lets it ping.
* **Probes** on `/health` (not authenticated).
* **Exposure is yours:** a standard `Ingress` (`ingress.className`, free
  `annotations`, templated) for any controller, or a Gateway API `HTTPRoute`
  (`httpRoute.parentRefs`), both off by default. `extraObjects` renders any other
  manifest with the release (a Traefik `Middleware`, a `NetworkPolicy`…).
  `hostNetwork: true` lets Wake-on-LAN broadcasts reach the LAN.
* `values.schema.json` rejects unknown keys and invalid values at install time.

Traefik with Authelia (`charts/belgo/ci/traefik-authelia-values.yaml`): the
chart's `Middleware` forwards each request to Authelia and passes its `Remote-*`
headers on, the Ingress annotation attaches it.

```yaml
existingSecret: belgo
ingress:
  enabled: true
  className: traefik
  annotations:
    traefik.ingress.kubernetes.io/router.middlewares: '{{ .Release.Namespace }}-belgo-authelia@kubernetescrd'
  hosts:
    - host: belgo.home.lan
      paths:
        - path: /
          pathType: Prefix
extraObjects:
  - apiVersion: traefik.io/v1alpha1
    kind: Middleware
    metadata:
      name: belgo-authelia
    spec:
      forwardAuth:
        address: http://authelia.authelia.svc.cluster.local/api/authz/forward-auth
        trustForwardHeader: true
        authResponseHeaders: [Remote-User, Remote-Groups, Remote-Email, Remote-Name]
```

Belgo trusts those headers from anyone who reaches it: keep the Service internal
(`ClusterIP`), and restrict it to the ingress controller with a `NetworkPolicy`
if other workloads share the cluster.

## Releasing

The version lives in `VERSION` (read by `mix.exs`, `flake.nix`, the Justfile and CI).
To release, bump it and merge into `main`:

* Pull requests to `main` run `just check` (format, warnings, Credo, tests) in the
  Nix dev shell (`.github/workflows/test.yml`).
* Every push to `main` runs the same checks, then, only when no GitHub release exists
  for `VERSION`, builds the image with Nix, pushes it to Docker Hub
  (`<version>` and `latest`) and creates the release `<version>` with generated
  notes (`.github/workflows/release.yml`). A push without version bump releases
  nothing.
* `just check` includes `just chart-check`: bump `charts/belgo/Chart.yaml`
  (`version` and `appVersion`) with `VERSION`.
* The repository needs the `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` secrets (a
  Docker Hub access token with write access to `nboisvert/belgo`).

By hand: `docker login`, then `just release-docker` builds, tags and pushes the
current version (`BELGO_DOCKER_REPOSITORY` overrides `nboisvert/belgo`).
