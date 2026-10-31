#!/bin/sh
# Restores the default route to the LAN.
#
# Why: AnyConnect pushes `default -> tun0`. Left as is, the gateway would send
# all external traffic through the corporate network, while we need the
# opposite: only corporate subnets enter the tunnel, everything else goes out
# through the home router.
#
# Corporate routes installed by vpnc-script stay in tun0 and are not touched
# here.
set -u

STATE=/run/vpn
[ -f "$STATE/lan.env" ] || { echo "[fix-routes] no lan.env, skip" >&2; exit 0; }
. "$STATE/lan.env"

if [ -z "${LAN_GW:-}" ] || [ -z "${LAN_DEV:-}" ]; then
    echo "[fix-routes] LAN_GW/LAN_DEV unknown, skip" >&2
    exit 0
fi

# default route back to the home router
ip route replace default via "$LAN_GW" dev "$LAN_DEV" \
    && echo "[fix-routes] default -> $LAN_GW dev $LAN_DEV" >&2

# just in case, remove defaults that may have been left in the tunnel
for m in 0 1 100 200 202 65535; do
    ip route del default dev tun0 metric "$m" 2>/dev/null || true
done

# subnets that were reachable over the LAN before connecting (host docker
# bridges and similar)
if [ -f "$STATE/pre-via-nets.txt" ]; then
    while read -r net; do
        [ -n "$net" ] || continue
        ip route replace "$net" via "$LAN_GW" dev "$LAN_DEV" 2>/dev/null || true
    done < "$STATE/pre-via-nets.txt"
fi

# Home LAN subnets. Some servers push a range that covers the host's own LAN,
# which makes the gateway lose sight of its own LAN peers (router, NAS, other
# hosts). Route those destinations back out to the LAN, otherwise requests to
# home addresses leave for the corporate network and die.
if [ -n "${LAN_NETS:-}" ]; then
    for net in $(echo "$LAN_NETS" | tr ',' ' '); do
        [ -n "$net" ] || continue
        ip route replace "$net" via "$LAN_GW" dev "$LAN_DEV" \
            && echo "[fix-routes] $net -> $LAN_GW dev $LAN_DEV" >&2
    done
fi

exit 0
