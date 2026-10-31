#!/bin/sh
# vpn-gateway: keeps an AnyConnect tunnel up and serves SOCKS5/HTTP proxies.
# The proxy always listens; the tunnel connects and reconnects on its own.
set -eu

log() { printf '[vpn-gateway] %s %s\n' "$(date -u +%FT%TZ)" "$*"; }
die() { log "FATAL: $*"; exit 1; }

: "${VPN_PIN:?VPN_PIN is required}"
: "${P12_PASSPHRASE:?P12_PASSPHRASE is required}"
: "${PROXY_USER:?PROXY_USER is required}"
: "${PROXY_PASS:?PROXY_PASS is required}"

# The credentials end up in a YAML config and in proxy URLs, where a quote or
# a colon would break both. Reject them here rather than failing later with a
# confusing parse error.
case "${PROXY_USER}${PROXY_PASS}" in
    *[!A-Za-z0-9]*)
        die "PROXY_USER and PROXY_PASS must be alphanumeric only (got non-alphanumeric characters)"
        ;;
esac

VPN_SERVER="${VPN_SERVER:-vpn.example.com}"
VPN_USER="${VPN_USER:-}"
HOME_DNS="${HOME_DNS:-192.168.1.1}"
CORP_DNS="${CORP_DNS:-10.0.0.53}"
CORP_DOMAINS="${CORP_DOMAINS:-example.com}"
SOCKS_PORT="${SOCKS_PORT:-1083}"
HTTP_PORT="${HTTP_PORT:-1082}"
AUTO_PORT="${AUTO_PORT:-1084}"
LAN_NETS="${LAN_NETS-192.168.1.0/24}"
POOL_BACKOFF="${POOL_BACKOFF:-300}"
P12="/certs/client.p12"

STATE=/run/vpn
mkdir -p "$STATE"
chmod 0700 "$STATE"

# ------------------------------------------------------------------ certificate
[ -f "$P12" ] || die "$P12 not found (mount ./certs:/certs:ro)"

# Some p12 files use RC2-40-CBC (a legacy algorithm) which openssl 3 on
# Debian 13 rejects by default. Probe with -legacy first, fall back to plain
# for modern p12 files built on AES.
p12_legacy=""
if openssl pkcs12 -legacy -in "$P12" -passin "pass:${P12_PASSPHRASE}" \
        -noout >/dev/null 2>&1; then
    p12_legacy="-legacy"
    log "p12 uses legacy (RC2) encryption — enabling -legacy provider"
fi

log "decrypting $P12"
openssl pkcs12 $p12_legacy -in "$P12" -passin "pass:${P12_PASSPHRASE}" \
        -nocerts -nodes -out "$STATE/client.key" 2>/dev/null \
    || die "cannot decrypt private key — wrong P12_PASSPHRASE?"
openssl pkcs12 $p12_legacy -in "$P12" -passin "pass:${P12_PASSPHRASE}" \
        -clcerts -nokeys -out "$STATE/client.pem" 2>/dev/null \
    || die "cannot extract client certificate"
chmod 0600 "$STATE/client.pem" "$STATE/client.key"

log "certificate: $(openssl x509 -in "$STATE/client.pem" -noout -subject 2>/dev/null | sed 's/^subject=//')"
/usr/local/bin/certcheck.sh "$STATE/client.pem" || log "WARNING: certificate expires soon"

# --------------------------------------------------------------- LAN snapshot
# Snapshot routes BEFORE the tunnel: once connected the ASA pushes `default`
# into tun0 and the gateway would lose its own LAN egress. Restored later in
# fix-routes.sh.
: > "$STATE/lan.env"
ip -4 route show default | head -1 > "$STATE/pre-default.txt"
LAN_GW=$(awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}' "$STATE/pre-default.txt")
LAN_DEV=$(awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' "$STATE/pre-default.txt")

case "$LAN_DEV" in
    ""|tun*|ppp*)
        die "cannot detect LAN default route (got dev='$LAN_DEV') — refusing to start, would blackhole traffic"
        ;;
esac
log "LAN default: via $LAN_GW dev $LAN_DEV"
{
    echo "LAN_GW='$LAN_GW'"
    echo "LAN_DEV='$LAN_DEV'"
} > "$STATE/lan.env"

# Subnets reachable through the LAN gateway before connecting (not connected
# routes). Without this they could be swallowed by a broad range the server
# pushes into the tunnel.
ip -4 route show | awk '$1 != "default" && / via / {print $1}' \
    | grep -vE '^0\.0\.0\.0' > "$STATE/pre-via-nets.txt" || true

# ------------------------------------------------------------------------- DNS
# Split DNS: corporate domains go to corporate resolvers (reachable only
# through the tunnel), everything else goes to the home resolver. Otherwise
# external lookups would leak into the corporate DNS.
gen_dnsmasq_conf() {
    sed -e "s|@HOME_DNS@|${HOME_DNS}|g" \
        -e "s|@CORP_DNS@|${CORP_DNS}|g" \
        -e "s|@CORP_DOMAINS@|${CORP_DOMAINS}|g" \
        /etc/vpn/dnsmasq.conf.template > "$STATE/dnsmasq.conf"
    # server=/domain/<ip> — one line per resolver per domain
    for d in $(echo "$CORP_DOMAINS" | tr ',' ' '); do
        for ip in $(echo "$CORP_DNS" | tr ',' ' '); do
            printf 'server=/%s/%s\n' "$d" "$ip" >> "$STATE/dnsmasq.conf"
        done
    done
}
gen_dnsmasq_conf

log "starting dnsmasq (split: $CORP_DOMAINS -> $CORP_DNS, default -> $HOME_DNS)"
dnsmasq --conf-file="$STATE/dnsmasq.conf" --pid-file="$STATE/dnsmasq.pid" \
    || die "dnsmasq failed to start"
DNS_PID=$(cat "$STATE/dnsmasq.pid" 2>/dev/null || true)

# ---------------------------------------------------------------------- proxy
# gost listens from the start, even without a tunnel. A request to a corporate
# address simply fails in that moment, while external traffic goes out over
# the LAN as usual.
#
# Three listeners on the same credentials:
#   SOCKS_PORT — SOCKS5 only (curl --socks5-hostname, python, git)
#   HTTP_PORT  — HTTP CONNECT only (old tooling, HTTP_PROXY)
#   AUTO_PORT  — protocol sniffing, accepts both (bun, anything generic)
#
# Credentials go into a config file, never onto the command line: with
# `gost -L socks5://user:pass@:port` the password is readable by every local
# user through `ps`, because the host sees container processes.
gen_gost_conf() {
    cat > "$STATE/gost.yaml" <<EOF
authers:
- name: auth-0
  auths:
  - username: "$PROXY_USER"
    password: "$PROXY_PASS"
services:
- name: socks5
  addr: ":${SOCKS_PORT}"
  handler:
    type: socks5
    auther: auth-0
  listener:
    type: tcp
- name: http
  addr: ":${HTTP_PORT}"
  handler:
    type: http
    auther: auth-0
  listener:
    type: tcp
- name: auto
  addr: ":${AUTO_PORT}"
  handler:
    type: auto
    auther: auth-0
  listener:
    type: tcp
EOF
    chmod 0600 "$STATE/gost.yaml"
}
gen_gost_conf

log "starting gost: socks5 :$SOCKS_PORT, http :$HTTP_PORT, auto :$AUTO_PORT (auth: $PROXY_USER)"
gost -C "$STATE/gost.yaml" &
GOST_PID=$!

CRASHED="$STATE/crashed"
rm -f "$CRASHED"

cleanup() {
    log "shutting down"
    [ -n "${WATCHDOG_PID:-}" ] && kill "$WATCHDOG_PID" 2>/dev/null || true
    [ -n "${TAIL_PID:-}" ] && kill "$TAIL_PID" 2>/dev/null || true
    [ -n "${OC_PID:-}" ] && kill "$OC_PID" 2>/dev/null || true
    kill "$GOST_PID" 2>/dev/null || true
    [ -n "${DNS_PID:-}" ] && kill "$DNS_PID" 2>/dev/null || true
    # a crashed child is not a clean shutdown: exit non-zero so that the
    # container's restart policy actually restarts it
    [ -f "$CRASHED" ] && exit 1
    exit 0
}
trap cleanup TERM INT

# Supervise the helper processes. Without this, a dead gost or dnsmasq leaves
# the tunnel running while the proxies are gone, and the container never exits,
# so `restart: unless-stopped` never fires — it looks healthy-ish and is
# unusable.
watch_children() {
    while :; do
        sleep 10
        if ! kill -0 "$GOST_PID" 2>/dev/null; then
            log "WATCHDOG: gost died, restarting the container"
            : > "$CRASHED"
            kill -TERM $$ 2>/dev/null
            return
        fi
        if [ -n "${DNS_PID:-}" ] && ! kill -0 "$DNS_PID" 2>/dev/null; then
            log "WATCHDOG: dnsmasq died, restarting the container"
            : > "$CRASHED"
            kill -TERM $$ 2>/dev/null
            return
        fi
    done
}
watch_children &
WATCHDOG_PID=$!

# ------------------------------------------------------------------ VPN tunnel
set -- openconnect \
    --protocol=anyconnect \
    --non-inter \
    --passwd-on-stdin \
    --no-dtls \
    --certificate="$STATE/client.pem" \
    --sslkey="$STATE/client.key" \
    --script=/usr/local/bin/routes.sh
if [ -n "$VPN_USER" ]; then
    set -- "$@" "--user=$VPN_USER"
fi
set -- "$@" "$VPN_SERVER"

backoff=5
while :; do
    log "connecting to $VPN_SERVER"

    # openconnect runs in the background and we `wait` for it. A shell blocked
    # in a foreground pipeline postpones signal traps until the child exits,
    # which would leave the watchdog and `docker stop` unable to interrupt a
    # long-lived tunnel.
    : > "$STATE/connect.log"
    tail -n +1 -F "$STATE/connect.log" &
    TAIL_PID=$!
    printf '%s\n' "$VPN_PIN" | "$@" >> "$STATE/connect.log" 2>&1 &
    OC_PID=$!
    set +e
    wait "$OC_PID"
    rc=$?
    set -e
    kill "$TAIL_PID" 2>/dev/null || true
    log "openconnect exited rc=$rc"

    ip link del tun0 2>/dev/null || true
    # restore LAN routes in case vpnc-script did not get that far
    /usr/local/bin/fix-routes.sh || true

    # The ASA ran out of addresses in its pool. Usually these are stale
    # sessions that an idle timeout will release. Hammering the server once a
    # minute is pointless and harmful, so wait much longer and reset backoff.
    if grep -q "IP Pool is over" "$STATE/connect.log" 2>/dev/null; then
        log "server reports IP pool exhausted (stale sessions?) — waiting ${POOL_BACKOFF}s"
        sleep "$POOL_BACKOFF"
        backoff=5
        continue
    fi

    log "reconnecting in ${backoff}s"
    sleep "$backoff"
    backoff=$((backoff * 2))
    [ "$backoff" -gt 60 ] && backoff=60
done
