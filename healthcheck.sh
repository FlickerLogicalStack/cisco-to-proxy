#!/bin/sh
# healthcheck: the tunnel is up AND corporate routes go via tun0 AND the
# proxies are listening. Checking "process is alive" alone is meaningless: a
# container can be running while the internal network is unreachable.
set -eu

ip link show tun0 >/dev/null 2>&1 || { echo "tun0 down"; exit 1; }

# the default route must NOT point into the tunnel (otherwise external traffic
# leaves through the corporate network)
if ip -4 route show default | head -1 | grep -q "tun0"; then
    echo "default route points into tunnel"
    exit 1
fi

# the route to a corporate address must go through the tunnel
if [ -n "${HEALTHCHECK_CORP_IP:-}" ]; then
    ip route get "$HEALTHCHECK_CORP_IP" 2>/dev/null | grep -q "dev tun0" \
        || { echo "no corp route via tun0 for $HEALTHCHECK_CORP_IP"; exit 1; }
else
    # fallback: at least one non-default route through tun0
    ip -4 route show | grep -v "^default" | grep -q "dev tun0" \
        || { echo "no corp routes via tun0"; exit 1; }
fi

for port in "${SOCKS_PORT:-1083}" "${HTTP_PORT:-1082}" "${AUTO_PORT:-1084}"; do
    ss -lnt 2>/dev/null | grep -q ":${port} " || { echo "proxy not listening on ${port}"; exit 1; }
done

exit 0
