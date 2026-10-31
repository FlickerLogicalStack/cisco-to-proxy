#!/bin/sh
# Pull the latest code from git and roll it out.
#
#   ./deploy.sh            git pull, rebuild the image, restart, run checks
#   ./deploy.sh --no-build skip the image rebuild (config-only changes)
#   ./deploy.sh --dry-run  show what would change, change nothing
#
# Keeps .env and certs/ untouched: both are gitignored, so a pull never
# overwrites your secrets.
#
# Workflow: commit and push on the machine where you edit, then on the host
# that runs the gateway:  ./deploy.sh
#
# Exit codes: 0 — deployed and healthy, 1 — deploy failed, 2 — ASA IP pool
# exhausted (the code is in place, the tunnel is not up yet).
set -u

cd "$(dirname "$0")" || exit 1

DO_BUILD=1
DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --no-build) DO_BUILD=0 ;;
        --dry-run)  DRY_RUN=1 ;;
        -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $arg (try --help)" >&2; exit 1 ;;
    esac
done

git rev-parse --git-dir >/dev/null 2>&1 || { echo "FAIL: not a git repository" >&2; exit 1; }
[ -f .env ] || { echo "FAIL: .env not found (see .env.example)" >&2; exit 1; }

branch=$(git rev-parse --abbrev-ref HEAD)

echo "== fetching origin/${branch}"
if ! git fetch --prune origin 2>&1 | sed 's/^/  /'; then
    echo "FAIL: git fetch failed (auth or network)" >&2
    exit 1
fi

before=$(git rev-parse HEAD)
after=$(git rev-parse "origin/${branch}")

if [ "$before" = "$after" ]; then
    echo "already up to date at $(git rev-parse --short HEAD)"
else
    echo "== changes $(git rev-parse --short "$before")..$(git rev-parse --short "$after")"
    git log --oneline "$before..$after" | sed 's/^/  /'
    git diff --stat "$before" "$after" | sed 's/^/  /'
fi

if [ "$DRY_RUN" -eq 1 ]; then
    if [ "$before" = "$after" ]; then
        echo "dry run: nothing to deploy"
    else
        echo "dry run: would deploy the commits above, nothing changed"
    fi
    exit 0
fi

# Refuse to pull over local edits to tracked files: this script is meant to
# apply committed code, not to merge surprises.
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    echo "FAIL: tracked files have local modifications:" >&2
    git status --short --untracked-files=no | sed 's/^/  /' >&2
    echo "      commit/stash them, or 'git checkout -- .' to discard" >&2
    exit 1
fi

if ! git pull --ff-only origin "$branch" 2>&1 | sed 's/^/  /'; then
    echo "FAIL: git pull failed (not a fast-forward?)" >&2
    exit 1
fi

echo "== now at $(git rev-parse --short HEAD)"

# smoke-test the scripts before restarting anything: a syntax error in
# entrypoint.sh would otherwise leave the container crash-looping
for f in *.sh; do
    sh -n "$f" 2>/dev/null || { echo "FAIL: syntax error in $f" >&2; exit 1; }
done

if [ "$DO_BUILD" -eq 1 ]; then
    echo "== rebuilding image, restarting, checking"
    exec ./restart.sh --quiet --build
fi

echo "== restarting, checking"
exec ./restart.sh --quiet
