#!/bin/sh
# Minimal end-to-end check for a running vpn-gateway.
#
# Usage (on the gateway host):
#   ./check.sh                                     # uses BIND_IP from .env
#   BIND_IP=127.0.0.1 ./check.sh                   # check the localhost binding
#   CORP_URL=https://intranet.example.com ./check.sh
#
# Exit code: 0 — all checks passed, 1 — something failed.
set -u

cd "$(dirname "$0")" || exit 1
[ -f .env ] || { echo "FAIL: .env not found"; exit 1; }

# remember explicit overrides before .env is sourced
_BIND_IP_OVERRIDE="${BIND_IP:-}"
_CORP_URL_OVERRIDE="${CORP_URL:-}"

# shellcheck disable=SC1091
set -a; . ./.env; set +a

# an explicit BIND_IP/CORP_URL from the environment wins over .env
[ -n "${_BIND_IP_OVERRIDE:-}" ] && BIND_IP="$_BIND_IP_OVERRIDE"
[ -n "${_CORP_URL_OVERRIDE:-}" ] && CORP_URL="$_CORP_URL_OVERRIDE"

HOST="${BIND_IP:-127.0.0.1}"
SOCKS_PORT="${SOCKS_PORT:-1083}"
HTTP_PORT="${HTTP_PORT:-1082}"
AUTO_PORT="${AUTO_PORT:-1084}"
CORP_URL="${CORP_URL:-}"
AUTH="${PROXY_USER}:${PROXY_PASS}"

SOCKS="socks5h://${AUTH}@${HOST}:${SOCKS_PORT}"
HTTP="http://${AUTH}@${HOST}:${HTTP_PORT}"
AUTO="http://${AUTH}@${HOST}:${AUTO_PORT}"
AUTO_SOCKS="socks5h://${AUTH}@${HOST}:${AUTO_PORT}"

fails=0
ok()  { printf '  OK    %s\n' "$*"; }
bad() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }

echo "gateway: ${HOST}  socks5=${SOCKS_PORT} http=${HTTP_PORT} auto=${AUTO_PORT}"

# 1. tunnel and proxies are up
# NB: match "(healthy)" exactly — "healthy" is a substring of "(unhealthy)",
# so a plain grep would report a broken gateway as healthy.
if docker compose ps --format '{{.Status}}' 2>/dev/null | grep -q '(healthy)'; then
    ok "container healthy"
else
    bad "container not healthy (docker compose ps)"
fi

# 2. external traffic exits through the home connection, not the tunnel
ext_ip=$(curl -s --max-time 20 --socks5-hostname "$SOCKS" https://ifconfig.me 2>/dev/null)
[ -n "$ext_ip" ] && ok "external egress via SOCKS5 = ${ext_ip}" \
                  || bad "no external egress via SOCKS5 (${SOCKS_PORT})"

# 3. all three listeners answer
code=$(curl -s --max-time 20 --socks5-hostname "$SOCKS" -o /dev/null -w '%{http_code}' https://github.com 2>/dev/null)
[ "$code" = "200" ] && ok "socks5 :${SOCKS_PORT} -> 200" || bad "socks5 :${SOCKS_PORT} -> ${code:-timeout}"

code=$(curl -s --max-time 20 -x "$HTTP" -o /dev/null -w '%{http_code}' https://github.com 2>/dev/null)
[ "$code" = "200" ] && ok "http   :${HTTP_PORT} -> 200" || bad "http   :${HTTP_PORT} -> ${code:-timeout}"

code=$(curl -s --max-time 20 -x "$AUTO" -o /dev/null -w '%{http_code}' https://github.com 2>/dev/null)
[ "$code" = "200" ] && ok "auto   :${AUTO_PORT} http -> 200" || bad "auto   :${AUTO_PORT} http -> ${code:-timeout}"

code=$(curl -s --max-time 20 --socks5-hostname "$AUTO_SOCKS" -o /dev/null -w '%{http_code}' https://github.com 2>/dev/null)
[ "$code" = "200" ] && ok "auto   :${AUTO_PORT} socks5 -> 200" || bad "auto   :${AUTO_PORT} socks5 -> ${code:-timeout}"

# 4. corporate resource answers through the same gateway
if [ -n "$CORP_URL" ]; then
    code=$(curl -s --max-time 20 --socks5-hostname "$SOCKS" -o /dev/null -w '%{http_code}' "$CORP_URL" 2>/dev/null)
    case "$code" in
        2*|3*) ok "corp $CORP_URL -> $code" ;;
        *)     bad "corp $CORP_URL -> ${code:-timeout}" ;;
    esac
else
    echo "  SKIP  corporate check (set CORP_URL=https://your.internal.host)"
fi

# 5. the tunnel really owns corporate routes and not the default
if docker compose exec -T vpn-gateway healthcheck.sh >/dev/null 2>&1; then
    ok "internal healthcheck"
else
    bad "internal healthcheck (docker compose logs)"
fi

echo
if [ "$fails" -eq 0 ]; then echo "PASS"; exit 0; fi
echo "FAILED ($fails)"; exit 1
