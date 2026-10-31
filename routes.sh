#!/bin/sh
# Wrapper around vpnc-script. Called by openconnect.
# reason=connect     -> install ASA-pushed routes, then restore the LAN default
# reason=disconnect  -> let vpnc-script tear everything down
set -u

STATE=/run/vpn

VPNS=""
for p in /usr/share/vpnc-scripts/vpnc-script \
         /etc/vpnc/vpnc-script \
         /usr/lib/vpnc/vpnc-script \
         /usr/libexec/vpnc-scripts/vpnc-script; do
    if [ -x "$p" ]; then VPNS="$p"; break; fi
done

if [ -z "$VPNS" ]; then
    echo "[routes] FATAL: vpnc-script not found" >&2
    exit 1
fi

echo "[routes] reason=${reason:-unknown} script=$VPNS" >&2
"$VPNS"
rc=$?

case "${reason:-}" in
    connect|reconnect)
        /usr/local/bin/fix-routes.sh || true
        ip -4 route show > "$STATE/routes-after.txt" 2>/dev/null || true
        echo "[routes] table after connect:" >&2
        sed 's/^/[routes]   /' "$STATE/routes-after.txt" >&2 2>/dev/null || true
        ;;
esac

exit $rc
