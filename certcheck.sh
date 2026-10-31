#!/bin/sh
# Reports the client certificate expiry.
# exit 0 — fine, exit 1 — less than WARN_DAYS left (default 30),
# exit 2 — file missing or unreadable.
set -u

CERT="${1:-/run/vpn/client.pem}"
WARN_DAYS="${WARN_DAYS:-30}"

[ -f "$CERT" ] || { echo "cert not found: $CERT"; exit 2; }

if ! end=$(openssl x509 -in "$CERT" -noout -enddate 2>/dev/null); then
    echo "cannot read certificate: $CERT"
    exit 2
fi
end=${end#notAfter=}

end_ts=$(date -d "$end" +%s 2>/dev/null || echo 0)
now_ts=$(date +%s)

if [ "$end_ts" -le 0 ]; then
    echo "cannot parse expiry date: $end"
    exit 2
fi

days=$(( (end_ts - now_ts) / 86400 ))

if [ "$days" -lt 0 ]; then
    echo "certificate EXPIRED $((-days)) days ago ($end)"
    exit 1
elif [ "$days" -lt "$WARN_DAYS" ]; then
    echo "certificate expires in $days days ($end) — renew now"
    exit 1
fi

echo "certificate valid for $days more days (until $end)"
exit 0
