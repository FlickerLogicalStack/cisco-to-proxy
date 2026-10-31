#!/bin/sh
# One-command restart for the vpn-gateway stack.
#
#   ./restart.sh            restart the container, wait for healthy, run checks
#   ./restart.sh --build    rebuild the image first (after file changes)
#   ./restart.sh --hard     full recreate: down + up (fresh netns, new VPN session)
#   ./restart.sh --quiet    no progress output, just the final result
#
# Environment:
#   HEALTHY_TIMEOUT  how long to wait for healthy, seconds (default 180)
#   POOL_WAIT        extra wait when the ASA IP pool is exhausted (default 330)
#   CORP_URL         passed through to check.sh for the corporate probe
#   SKIP_CHECK=1     skip the post-restart checks
#
# Exit codes: 0 — healthy and checks passed, 1 — failed, 2 — ASA pool exhausted.
#
# Note: every restart burns an address from the ASA pool and the server does not
# release it immediately. Restarting several times in a row can leave the pool
# empty for a few minutes; this script detects that and says so instead of
# waiting silently.
set -u

cd "$(dirname "$0")" || exit 1

MODE=soft
QUIET=0
for arg in "$@"; do
    case "$arg" in
        --build) MODE=build ;;
        --hard)  MODE=hard ;;
        --quiet) QUIET=1 ;;
        -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $arg (try --help)" >&2; exit 1 ;;
    esac
done

[ -f .env ] || { echo "FAIL: .env not found in $(pwd)" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "FAIL: docker not found" >&2; exit 1; }

HEALTHY_TIMEOUT="${HEALTHY_TIMEOUT:-180}"
POOL_WAIT="${POOL_WAIT:-330}"   # entrypoint's POOL_BACKOFF (300) plus room to connect
say() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }

say "== restart ($MODE)"

case "$MODE" in
    build)
        say "building image..."
        if ! docker compose build 2>&1 | tail -3; then
            echo "FAIL: build failed (run 'docker compose build' for details)" >&2
            exit 1
        fi
        docker compose up -d --force-recreate >/dev/null 2>&1
        ;;
    hard)
        say "recreating container (down + up)..."
        docker compose down >/dev/null 2>&1
        docker compose up -d >/dev/null 2>&1
        ;;
    soft)
        # exactly one restart: `up -d` as well would restart it twice and burn
        # two pool addresses
        if [ -n "$(docker compose ps -q vpn-gateway 2>/dev/null)" ]; then
            docker compose restart vpn-gateway >/dev/null 2>&1
        else
            say "container not running, starting it"
            docker compose up -d >/dev/null 2>&1
        fi
        ;;
esac

# ---------------------------------------------------------------- wait healthy
say "waiting for healthy (timeout ${HEALTHY_TIMEOUT}s)..."
waited=0
pool_hint=0
deadline="$HEALTHY_TIMEOUT"
status=""
while [ "$waited" -lt "$deadline" ]; do
    sleep 5
    waited=$((waited + 5))
    status=$(docker compose ps --format '{{.Status}}' 2>/dev/null | head -1)
    # NB: match "(healthy)" exactly — the substring "healthy" also occurs in
    # "(unhealthy)", which would make this loop report false success.
    case "$status" in
        *"(healthy)"*)
            say "healthy after ${waited}s"
            break
            ;;
    esac

    # The ASA pool is the one failure that resolves itself with time: the
    # entrypoint retries after POOL_BACKOFF, so extend the deadline once.
    if [ "$pool_hint" -eq 0 ] && \
       docker compose logs --tail=60 vpn-gateway 2>&1 | grep -q "IP Pool is over"; then
        pool_hint=1
        deadline=$((deadline + POOL_WAIT))
        say ""
        say "ASA reports an exhausted IP pool (stale sessions from earlier restarts)."
        say "The gateway retries automatically; extending wait to ${deadline}s."
    fi
    [ "$QUIET" -eq 1 ] || printf '.'
done
[ "$QUIET" -eq 1 ] || printf '\n'

case "$status" in
    *"(healthy)"*) ;;
    *)
        if [ "$pool_hint" -eq 1 ]; then
            echo "FAIL: still no tunnel — ASA IP pool exhausted for more than ${deadline}s." >&2
            echo "      Wait a few more minutes, or disconnect other sessions of the same user" >&2
            echo "      (including the VPN on your laptop)." >&2
            exit 2
        fi
        echo "FAIL: not healthy after ${deadline}s (status: ${status:-none})" >&2
        echo "--- last log lines ---" >&2
        docker compose logs --tail=25 vpn-gateway 2>&1 | sed 's/^/  /' >&2
        logs=$(docker compose logs --tail=200 vpn-gateway 2>&1)
        case "$logs" in
            *"401 Authentication failed"*)
                echo "HINT: check VPN_USER / VPN_PIN in .env" >&2 ;;
        esac
        case "$logs" in
            *"cannot decrypt private key"*)
                echo "HINT: check P12_PASSPHRASE in .env" >&2 ;;
        esac
        case "$logs" in
            *"cannot detect LAN default route"*)
                echo "HINT: the container started without a LAN default route" >&2 ;;
        esac
        exit 1
        ;;
esac

# ------------------------------------------------------------------- summary
if [ "$QUIET" -eq 0 ]; then
    say "== state"
    docker compose exec -T vpn-gateway sh -c '
        ip -4 addr show tun0 2>/dev/null | awk "/inet /{print \"  tunnel: \" \$2}"
        ip -4 route show default | sed "s/^/  default: /"
        printf "  corp routes: "; ip -4 route show | grep -c "dev tun0"
        certcheck.sh 2>/dev/null | sed "s/^/  /"
        printf "  proxies: "; for p in $SOCKS_PORT $HTTP_PORT $AUTO_PORT; do
            ss -lnt 2>/dev/null | grep -q ":$p " && printf "%s " "$p"
        done; echo
    ' 2>/dev/null
fi

# --------------------------------------------------------------------- checks
if [ "${SKIP_CHECK:-0}" = "1" ]; then
    say "checks skipped (SKIP_CHECK=1)"
    exit 0
fi

say "== checks"
if [ "$QUIET" -eq 1 ]; then
    ./check.sh >/dev/null 2>&1 || { echo "FAILED: checks did not pass"; exit 1; }
    echo "OK: gateway restarted and healthy"
    exit 0
fi

./check.sh
