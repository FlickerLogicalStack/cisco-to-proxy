# cisco-to-proxy

Cisco AnyConnect (SSL VPN) in a container, running as an **explicit-entry
gateway**: it waits for SOCKS5/HTTP proxy requests and enriches routing —
corporate addresses go through the tunnel, everything else goes straight out
through the home internet connection.

```
code (host / container / another machine)
   │  explicitly: socks5h://user:pass@<BIND_IP>:1083
   ▼
┌─ vpn-gateway ──────────────────────────────────────────┐
│  dnsmasq :53 (split DNS)                               │
│  gost :1083 socks5 │ :1082 http │ :1084 auto (auth)     │
│  openconnect → tun0 → vpn.example.com                  │
│  corp-CIDR → tun0   │  default → eth0 (LAN)            │
└────────────────────────────────────────────────────────┘
```

No global VPN on the host, host routes are left untouched, and other VPN
clients can stay connected at the same time.

## Requirements

- Linux on any supported architecture (see below), Docker + compose
- `/dev/net/tun` (check: `ls -l /dev/net/tun`)
- a client certificate as `.p12` plus its passphrase
- a static PIN for the gateway

## Architectures

The image builds for any platform Debian and gost support. The architecture is
detected at build time — nothing to pass for a native build.

| platform | hardware examples | gost binary |
|---|---|---|
| `linux/amd64` | any x86-64 PC, old laptop, NUC | `amd64` |
| `linux/arm64` | Raspberry Pi 3/4/5 with a 64-bit OS, most SBCs | `arm64` |
| `linux/arm/v7` | Raspberry Pi 2/3 with a 32-bit OS, older SBCs | `armv7` |
| `linux/arm/v6` | Raspberry Pi 1, Zero, Zero W | `armv6` |
| `linux/arm/v5` | very old ARM boards | `armv5` |
| `linux/386` | 32-bit x86 | `386` |
| `linux/riscv64` | RISC-V boards (VisionFive, Star64) | `riscv64` |
| `linux/s390x` | IBM Z | `s390x` |

Not supported: `ppc64le` — Debian builds for it, but gost publishes no binary.

How the detection works: `arch-map.sh` prefers BuildKit's `TARGETARCH` /
`TARGETVARIANT`, and falls back to `dpkg --print-architecture` when the image is
built without BuildKit. Both paths are covered by the mapping table above.

### Building for another architecture

Build on the target machine and the right binary is picked automatically.
To cross-build, you need emulation registered on the builder:

```bash
# one-off: register qemu handlers (needed only for cross-building)
docker run --privileged --rm tonistiigi/binfmt --install amd64,arm64,arm

# build for several platforms and push to a registry
docker buildx create --use --name multiarch 2>/dev/null || docker buildx use multiarch
docker buildx build \
  --platform linux/amd64,linux/arm64,linux/arm/v7 \
  -t <registry>/cisco-to-proxy:latest --push .
```

`docker compose build` uses BuildKit and therefore sets `TARGETARCH`
automatically; the composition itself needs no changes per platform.

### Exotic targets

If gost names a build differently from Docker's platform name, override it:

```bash
docker build --build-arg GOST_ARCH=mips64le_hardfloat -t cisco-to-proxy .
```

On an `armv6` host with a `armhf` userspace, `dpkg` reports `armhf`, which maps
to `armv7` — an `armv7` binary faults on an `armv6` CPU. Pass
`--build-arg GOST_ARCH=armv6` in that case.

## Install

```bash
git clone <repo> cisco-to-proxy && cd cisco-to-proxy

cp .env.example .env && chmod 600 .env
$EDITOR .env                      # see the table below

mkdir -p certs && chmod 700 certs
# put the certificate here:
#   certs/client.p12
# chmod 600 certs/client.p12

docker compose up -d --build
docker compose logs -f
```

### Required `.env` values

| variable | meaning | example |
|---|---|---|
| `VPN_SERVER` | VPN gateway address | `vpn.example.com` |
| `VPN_USER` | login in the ASA form, **not** the certificate CN | `jdoe` |
| `VPN_PIN` | static PIN from the second form field | `1234` |
| `P12_PASSPHRASE` | passphrase of the `.p12`, a different value | — |
| `PROXY_USER` / `PROXY_PASS` | proxy credentials, `[A-Za-z0-9]` only | — |
| `BIND_IP` | host LAN address to publish the ports on | `<BIND_IP>` |
| `HOME_DNS` | home network resolver | `<lan-router-ip>` |
| `CORP_DNS` | corporate resolvers, comma separated | `<corp-dns-1>,<corp-dns-2>` |
| `CORP_DOMAINS` | domains resolved through the corporate DNS | `corp.example` |
| `LAN_NETS` | home subnets to route back to the LAN | `<lan-cidr>` |

Optional: `SOCKS_PORT` / `HTTP_PORT` / `AUTO_PORT` (`1083` / `1082` / `1084` by
default), `POOL_BACKOFF`, `HEALTHCHECK_CORP_IP`.

The `.p12` passphrase and the PIN are **different** values, do not mix them up.

`VPN_USER` matters: the ASA presents a two-field form (`username` + `PIN`) and
supplies the certificate separately. Without `VPN_USER` the server answers
`401 Authentication failed` even though TLS and the certificate are fine.

`PROXY_PASS` must be letters and digits only. Special characters (`&`, `:`,
`@`, `/`) break the proxy URL.

Check that the tunnel came up:

```bash
docker compose ps                       # STATUS = healthy
docker compose exec vpn-gateway ip -4 route show
```

The table should contain `default via <your-lan-router> dev eth0` **and** the
corporate subnets your server pushes on `tun0`.

## Verify

```bash
# SOCKS5
curl --socks5-hostname user:PASS@<BIND_IP>:1083 -sI https://<corporate-host>

# HTTP CONNECT
curl -x http://user:PASS@<BIND_IP>:1082 -sI https://<corporate-host>

# auto — accepts either protocol on one port
curl -x http://user:PASS@<BIND_IP>:1084 -sI https://<corporate-host>

# an external site must go out directly, NOT through the corporate network
curl --socks5-hostname user:PASS@<BIND_IP>:1083 -s https://ifconfig.me
```

The last command must show your **home** IP, not a corporate one. If it shows
a corporate IP, `fix-routes.sh` did not restore the LAN default route.

Or run the bundled check, which covers all of the above plus the internal
healthcheck:

```bash
CORP_URL=https://<corporate-host> ./check.sh
```

## Deploy from git

The repository is the source of truth. Edit and commit on your workstation,
then roll out on the gateway host with one command:

```bash
# on the workstation
git push

# on the gateway host
cd ~/Documents/projects/cisco-to-proxy
./deploy.sh
```

`deploy.sh` fetches, prints the incoming commits and the changed files, pulls
fast-forward only, syntax-checks every script, rebuilds the image, restarts the
container and runs the checks.

```bash
./deploy.sh --dry-run      # show what would be deployed, change nothing
./deploy.sh --no-build     # config-only change, skip the image rebuild
```

Safe by design:

- `.env` and `certs/` are gitignored, so a pull never touches your secrets.
- it refuses to pull when tracked files have local edits (no silent merges);
- it verifies script syntax **before** restarting, so a typo cannot leave the
  container crash-looping.

Exit codes match `restart.sh`: `0` deployed and healthy, `1` failed, `2` code
deployed but the ASA IP pool is exhausted.

## Restart
One command to restart the container, wait until it is actually healthy, and
verify everything:

```bash
./restart.sh                    # restart, wait for healthy, run checks
./restart.sh --build            # rebuild the image first (after file changes)
./restart.sh --hard             # full recreate: down + up
./restart.sh --quiet            # one line of output, for cron/scripts
SKIP_CHECK=1 ./restart.sh       # skip the checks
HEALTHY_TIMEOUT=300 ./restart.sh
```

Exit codes: `0` — healthy and checks passed, `1` — failed (last log lines are
printed with a hint), `2` — the ASA IP pool is exhausted.

Every restart takes an address from the ASA pool and the server does not free
it instantly. Restarting several times in a row can empty the pool for a few
minutes; `restart.sh` detects that, extends its wait once, and exits with code
`2` and an explanation instead of hanging.

## Which address to use

| port | protocols | use for |
|---|---|---|
| `1083` | SOCKS5 only | curl `--socks5-hostname`, python, git, most CLI tools |
| `1082` | HTTP CONNECT only | tools that only speak HTTP proxies |
| `1084` | SOCKS5 **and** HTTP | bun, anything generic, "I don't want to think about it" |

`1084` sniffs the first bytes of each connection and dispatches to the matching
handler, so the same port works for both client types. Port numbers are
identical inside and outside the container: one number, one meaning.

## Wiring up code

Ports: SOCKS5 — `1083`, HTTP CONNECT — `1082`, auto — `1084`.

### Python (requests)

```python
import requests

proxies = {
    "http":  "socks5h://user:PASS@<BIND_IP>:1083",
    "https": "socks5h://user:PASS@<BIND_IP>:1083",
}
requests.get("https://<corporate-host>/api", proxies=proxies, timeout=15)
```

Requires `pip install requests[socks]` (PySocks). `socks5h` means the gateway
resolves names, otherwise corporate names are looked up on the client.

### Environment variables (curl, git, npm, docker, go, node)

```bash
export ALL_PROXY=socks5h://user:PASS@<BIND_IP>:1083
export HTTPS_PROXY=http://user:PASS@<BIND_IP>:1082
export HTTP_PROXY=http://user:PASS@<BIND_IP>:1082
export NO_PROXY=localhost,127.0.0.1,<lan-cidr>
```

Applies to the current shell/process only — no system-wide changes.

### Node.js

```js
const { SocksProxyAgent } = require('socks-proxy-agent');
const agent = new SocksProxyAgent('socks5h://user:PASS@<BIND_IP>:1083');
fetch('https://<corporate-host>/api', { agent });
```

### Go

```go
proxyURL, _ := url.Parse("socks5://user:PASS@<BIND_IP>:1083")
client := &http.Client{Transport: &http.Transport{Proxy: http.ProxyURL(proxyURL)}}
```

Go resolves names on the client side. Use `socks5` together with a
`DialContext` built on `socks5.NewDialer` if the gateway must do the resolving.

### Bun

Bun supports **HTTP proxies only** — `socks5://` fails with
`UnsupportedProxyProtocol`. Use port `1082` (or `1084`), never `1083`:

```bash
HTTPS_PROXY=http://user:PASS@<BIND_IP>:1082 bun run start
```

Three gotchas, each verified against bun 1.4:

- `ALL_PROXY` is ignored. Set `HTTPS_PROXY` / `HTTP_PROXY`.
- Proxy env vars are read **at process start**. Assigning
  `process.env.HTTPS_PROXY` at runtime has no effect on later `fetch` calls.
- `node:https` / `node:http` bypass the proxy entirely. If the tooling uses
  them instead of `fetch`, you need an explicit agent — or use `fetch`.

Per-request proxying, if only some calls must reach the corporate network:

```ts
const CORP = process.env.CORP_PROXY; // http://user:pass@<BIND_IP>:1082
const internal = (url: string) =>
  url.includes('<corp-domain>') && CORP ? { proxy: CORP } : {};

await fetch('https://<corporate-host>/api', internal(url)); // via tunnel
await fetch('https://api.telegram.org/bot...');                 // direct
```

### Code on the gateway host itself

If the code runs on the same machine as the gateway, localhost is cheaper:

```bash
export ALL_PROXY=socks5h://user:PASS@127.0.0.1:1083
```

### Code inside another container

```yaml
services:
  my-app:
    environment:
      ALL_PROXY: socks5h://user:PASS@<BIND_IP>:1083
```

Or attach both containers to a shared network and use the service name:

```yaml
    networks: [shared]
# and in the gateway's docker-compose.yml uncomment networks: [default, shared]
# then the address is: socks5h://user:PASS@vpn-gateway:1083
```

## How it works

**Routes.** The route set is dictated by the server's group policy, not by the
client:

| server policy | what is pushed | what `fix-routes.sh` does |
|---|---|---|
| full tunnel | `default` into the tunnel, often plus broad ranges | restores `default` to the LAN router |
| split tunnel (include) | only the corporate subnets | `default` is already correct, no-op |
| split tunnel (exclude) | `default` plus an exclusion list | restores `default` to the LAN router |

Either way the outcome is the same: corporate destinations stay in `tun0`,
everything else leaves through the local network. `fix-routes.sh` does not
depend on a particular shape — it snapshots the routes before connecting and
restores the local ones afterwards, so no subnet list is hardcoded.

Broad corporate ranges can overlap addresses the container needs for itself
(docker's own bridge networks, for instance). Those keep working because a
`connected` route is more specific than a pushed range and therefore wins.

**Local network access.** Some servers push a range that covers the host's own
LAN. In that case the gateway would stop seeing its router and neighbours, so
`LAN_NETS` routes those destinations back out of the container. This mirrors
what the vendor client calls "local LAN access"; `openconnect` does not
implement that profile setting, so it has to be declared explicitly. Leave
`LAN_NETS` empty when the server does not push a conflicting range.

**DNS.** `dnsmasq` inside the container: domains from `CORP_DOMAINS` go to
`CORP_DNS` (reachable only through the tunnel), everything else goes to
`HOME_DNS`. The docker resolver `127.0.0.11` is disabled via `dns: 127.0.0.1`,
otherwise corporate names would not resolve at all.

**Liveness.** `entrypoint.sh` runs a loop: `openconnect` exits → clean up
`tun0` → backoff 5→60 s → retry. The proxy is not restarted in the process.
`restart: unless-stopped` survives a host reboot.

A watchdog inside the container checks `gost` and `dnsmasq` every 10 seconds.
If either dies, the entrypoint exits non-zero so the container's restart
policy rebuilds it — otherwise the tunnel would stay up with dead proxies and
the container would never restart on its own.

**Credentials.** The proxy password is written to a `0600` YAML config inside
the container and passed to `gost -C`. It is deliberately **not** passed with
`-L socks5://user:pass@:port`: the host can see container processes, so that
form would expose the password to any local user through `ps`. For the same
reason `PROXY_USER` and `PROXY_PASS` are validated as alphanumeric.

`VPN_PIN`, `P12_PASSPHRASE` and `PROXY_PASS` still live in `.env` and are
visible through `docker inspect` to anyone with docker access — that is
equivalent to root on the host.

**Kill switch.** Tunnel down → no corporate routes → a request to an internal
address simply fails. There is no leak towards the outside: external traffic
already goes out directly.

## Host firewall

If the host isolates containers from host services (a common pattern is
`-i br-+ -j DROP`), such a rule also drops the **replies** to connections
initiated by the host, and published ports stop working: the request reaches
the container, the reply is dropped.

Allow established traffic **before** the DROP:

```bash
iptables -I INPUT 2 -i 'br-+' -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -I INPUT 3 -i 'br-+' -j DROP
```

Isolation is preserved: containers still cannot initiate connections to the
host on their own.

Symptom: a connection to `127.0.0.1:<port>` hangs, `docker compose ps` says
healthy, and gost logs show no incoming request at all.

## Client machine with its own VPN client

If the client machine runs a VPN client that installs a full tunnel, it can
push a range covering your LAN into its own tunnel and then **stops seeing the
gateway over IPv4**. This is not a bug in this project.

Workarounds: disconnect that VPN on the client, or add a host route to the
gateway

```bash
sudo route add -host <BIND_IP> -interface <lan-interface>   # macOS, until reboot
```

## Maintenance

The certificate lives for a year. Check the expiry:

```bash
docker compose exec vpn-gateway certcheck.sh
```

A warning is logged at startup when less than 30 days remain. To renew:

```bash
cp new.p12 certs/client.p12
docker compose restart vpn-gateway
```

## Limitations

- **TCP only.** SOCKS5 UDP ASSOCIATE is not enabled: half the clients do not
  support it and HTTP proxies never do. If you need UDP, add `tun2socks` on
  the consumer side.
- `--socks5-hostname` / `socks5h` is mandatory, otherwise DNS resolves on the
  client.
- The PIN is stored in `.env` in plain text: it is effectively a second
  password. `.env` is in `.gitignore` with mode `600`. Anyone with docker
  access can read it via `docker inspect`, so treat docker access as root.
- `check.sh` passes the proxy credentials on the `curl` command line, so they
  are briefly visible in `ps` on the host while it runs. Not a concern on a
  single-user box; on a shared one prefer `curl -K` with a `0600` config.
- ICMP does not go through the proxy.
- **Every connect consumes an address from the ASA pool.** Restarting the
  gateway often can leave stale sessions that exhaust the pool, after which the
  server answers `IP Pool is over`. They are released by an idle timeout. In
  that case `entrypoint.sh` waits `POOL_BACKOFF` seconds (300 by default)
  instead of hammering the server every minute.
- Usage policy: a corporate VPN is usually tied to a device and a user. Make
  sure such a setup does not violate your company's rules before deploying it.

## Troubleshooting

| symptom | cause | fix |
|---|---|---|
| `cannot decrypt private key` | wrong `P12_PASSPHRASE` | check the .p12 passphrase |
| `unrecognized option` | unsupported openconnect flag | compare with `openconnect --help` |
| `401 Authentication failed`, certificate accepted | `VPN_USER` not passed | set `VPN_USER` in `.env` |
| `certificate ... EXPIRED` | certificate expired | obtain a new one, replace `certs/client.p12` |
| `cannot detect LAN default route` | container started without LAN | check the host network |
| `no corp route via tun0` while healthy | tunnel up but pushes were not applied | `docker compose exec vpn-gateway ip route` |
| internal name does not resolve | domain missing from `CORP_DOMAINS` | add the domain to `.env` |
| external site returns a corporate IP | `fix-routes.sh` did not restore the default | `docker compose logs vpn-gateway \| grep fix-routes` |
| `socks5 not listening` | gost did not start | `docker compose logs` |
| port hangs, no gost logs | firewall drops the replies | see "Host firewall" |
| `IP Pool is over` | the ASA pool is exhausted | wait for the idle timeout (20–60 min), drop extra sessions; the gateway retries after `POOL_BACKOFF` |
| gateway cannot reach the host LAN | the server pushes a range covering it | set `LAN_NETS` to your local subnets |
| docker `pull`/`build` go through the tunnel | a global proxy is set on the host | do not export `*_PROXY` on the host; pass it per command |
| container up, all proxy ports refuse | `gost` died (OOM, manual kill) | fixed by the watchdog: the container exits and restarts; check `docker inspect --format '{{.RestartCount}}'` |
| `PROXY_USER and PROXY_PASS must be alphanumeric` | special characters in the credentials | use letters and digits only |
