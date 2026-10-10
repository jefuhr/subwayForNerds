#!/usr/bin/env bash
#
# Deploy Subways for Nerds to juliet.nyc/subwaysForNerds.
#
#   ~/deploy-sfn.sh                  # test, build, back up, sync, restart, verify
#   ~/deploy-sfn.sh --skip-tests     # skip the local test run
#   ~/deploy-sfn.sh --no-build       # ship the server only; leave dist/ on the box alone
#   ~/deploy-sfn.sh --branch foo     # deploy a different branch
#   ~/deploy-sfn.sh --dry-run        # show what would change, touch nothing
#   ~/deploy-sfn.sh --force          # redeploy even if the box is already on this SHA
#
# Everything shipped comes from `git archive <branch>`, i.e. committed code only
# — uncommitted work in the checkout is never deployed by accident. That applies
# to the frontend too: dist/ is gitignored, so it cannot ride along in the
# archive, and building it from the checkout would smuggle in whatever is
# half-finished in src/. Instead the branch is exported to a temp dir and built
# there, against the checkout's node_modules. Two consequences worth knowing:
# deploying the same SHA twice produces byte-identical assets (so the service
# worker's cache version holds steady and clients do not re-download the shell
# for nothing), and the checkout's own dist/ is never touched.
#
# Building locally rather than on the box is deliberate — the instance has
# ~1.9 GB of RAM and only runtime dependencies installed.
#
# Never touched on the box:
#   state/         feed caches the service writes at runtime
#   node_modules/  refreshed only when package-lock.json changes
#
# The mount point lives in three places that must agree:
#   vite.config.ts  base            (baked into the built asset URLs)
#   systemd unit    APP_BASE        (where the server mounts dist/ and the API)
#   nginx           location block  (proxied through unstripped)

set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/deploy-backup-lib.sh"

REPO="${SFN_REPO:-$HOME/subwaysForNerds}"
BRANCH="${SFN_BRANCH:-main}"
HOST="${SFN_HOST:-ubuntu@52.5.187.46}"
KEY="${SFN_KEY:-$HOME/julie.pem}"
APP_DIR="/opt/subways-for-nerds"
SERVICE="subways-for-nerds"
BASE="/subwaysForNerds/"
SITE="https://juliet.nyc"
KEEP_BACKUPS=5
BACKUP_DIR="${BACKUP_DIR:-$HOME/backups}"

SKIP_TESTS=0
NO_BUILD=0
DRY_RUN=0
FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-tests) SKIP_TESTS=1; shift ;;
    --no-build)   NO_BUILD=1; shift ;;
    --dry-run)    DRY_RUN=1; shift ;;
    --force)      FORCE=1; shift ;;
    --branch)     BRANCH="$2"; shift 2 ;;
    -h|--help)    sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

SSH=(ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=15 "$HOST")
say() { printf '\n\033[1;35m▸ %s\033[0m\n' "$*"; }
warn() { printf '  \033[1;33m! %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31m✖ %s\033[0m\n' "$*" >&2; exit 1; }

[[ -d "$REPO/.git" || -f "$REPO/.git" ]] || die "no git repo at $REPO"
git -C "$REPO" rev-parse --verify --quiet "$BRANCH" >/dev/null || die "no branch '$BRANCH' in $REPO"

LOCAL_SHA=$(git -C "$REPO" rev-parse "$BRANCH")
DEPLOYED_SHA=$("${SSH[@]}" "cat $APP_DIR/DEPLOYED_SHA 2>/dev/null" || true)

say "deploying ${BRANCH} → ${HOST}${APP_DIR}"
echo "  local:    ${LOCAL_SHA:0:7}  $(git -C "$REPO" log -1 --format=%s "$BRANCH")"
if [[ -n "$DEPLOYED_SHA" ]]; then
  echo "  deployed: ${DEPLOYED_SHA:0:7}"
  if [[ "$DEPLOYED_SHA" == "$LOCAL_SHA" && "$FORCE" == 0 ]]; then
    echo "  already up to date — nothing to do (--force to redeploy anyway)."; exit 0
  fi
  echo
  git -C "$REPO" log --oneline "${DEPLOYED_SHA}..${BRANCH}" | sed 's/^/    /'
  git -C "$REPO" diff --stat "${DEPLOYED_SHA}..${BRANCH}" | sed 's/^/    /'
  echo
else
  echo "  deployed: unknown (no DEPLOYED_SHA on the box — first deploy?)"
fi

DIRTY=$(git -C "$REPO" status --porcelain)
if [[ -n "$DIRTY" ]]; then
  warn "working tree is dirty — none of this is deployed:"
  echo "$DIRTY" | sed 's/^/      /'
fi

# --- the mount point must agree across vite, systemd and nginx ----------------
say "checking the mount point"
VITE_BASE=$(git -C "$REPO" show "${BRANCH}:vite.config.ts" 2>/dev/null | grep -oE "APP_BASE \|\| '[^']+'" | grep -oE "'[^']+'" | tr -d "'" || true)
UNIT_BASE=$("${SSH[@]}" "grep -oP '(?<=^Environment=APP_BASE=).*' /etc/systemd/system/${SERVICE}.service" 2>/dev/null || true)
echo "  vite base:      ${VITE_BASE:-<unreadable>}"
echo "  unit APP_BASE:  ${UNIT_BASE:-<unset>}"
[[ "${VITE_BASE:-$BASE}" == "${UNIT_BASE:-$BASE}" ]] \
  || warn "vite and the systemd unit disagree — assets will 404 until they match"

if [[ "$DRY_RUN" == 1 ]]; then say "dry run — stopping before any changes"; exit 0; fi

# --- tests --------------------------------------------------------------------
if [[ "$SKIP_TESTS" == 1 ]]; then
  say "skipping tests (--skip-tests)"
elif ! compgen -G "$REPO/test/*.test.ts" >/dev/null; then
  say "no test/*.test.ts yet — skipping tests"
else
  say "running tests"
  ( cd "$REPO" && npm test 2>&1 | tail -12 ) || die "tests failed — not deploying"
fi

# --- build --------------------------------------------------------------------
# Out of a clean export of the branch, never the checkout: see the note up top.
BUILD_DIR=""
cleanup() { if [[ -n "$BUILD_DIR" && -d "$BUILD_DIR" ]]; then rm -rf "$BUILD_DIR"; fi; }
trap cleanup EXIT

if [[ "$NO_BUILD" == 1 ]]; then
  say "skipping the frontend build (--no-build) — dist/ on the box is left as-is"
else
  say "building the frontend from a clean ${BRANCH} export"
  [[ -d "$REPO/node_modules" ]] || die "no node_modules in $REPO — run 'npm ci' there first"
  BUILD_DIR=$(mktemp -d -t sfn-build-XXXXXX)
  git -C "$REPO" archive "$BRANCH" | tar -x -C "$BUILD_DIR"
  # Borrowed, not installed — npm ci into a throwaway dir on every deploy would
  # dwarf the build itself.
  ln -s "$REPO/node_modules" "$BUILD_DIR/node_modules"
  ( cd "$BUILD_DIR" && APP_BASE="$BASE" npm run build 2>&1 | tail -12 ) || die "build failed — not deploying"
  [[ -f "$BUILD_DIR/dist/index.html" ]] || die "build produced no dist/index.html"
  du -sh "$BUILD_DIR/dist" | sed 's/^/  /'
fi

# --- backup -------------------------------------------------------------------
STAMP=$(date +%Y%m%d-%H%M%S-%N)
BACKUP="$BACKUP_DIR/${SERVICE}-backup-${STAMP}.tgz"
ROLLBACK=$(local_backup_rollback "$BACKUP" "cd /opt && sudo tar xzf - && sudo systemctl restart $SERVICE")
if [[ -n "$DEPLOYED_SHA" ]]; then
  say "backing up to $BACKUP on this machine"
  # Pause the writer so SQLite and its WAL are captured consistently. Always
  # restart, including when tar fails, before continuing with the release.
  backup_local "$BACKUP" "set -e; cd /opt; sudo systemctl stop $SERVICE >&2; trap 'sudo systemctl start $SERVICE >&2' EXIT; sudo tar --exclude=${SERVICE}/node_modules -czf - ${SERVICE}"
else
  say "no previous deploy to back up"
  ROLLBACK="(nothing to roll back to — this was the first deploy)"
fi

# --- sync source --------------------------------------------------------------
say "syncing committed files from ${BRANCH}"
git -C "$REPO" archive "$BRANCH" \
  | "${SSH[@]}" "cd $APP_DIR && tar -xf - && echo '  source extracted'"

# --- sync the built frontend --------------------------------------------------
# Swapped in whole rather than merged, so hashed assets from old builds do not
# pile up in dist/ forever.
if [[ "$NO_BUILD" == 0 ]]; then
  say "syncing dist/"
  # -m on extract: the box's clock and this machine's drift by a few seconds, and
  # without it tar warns about every single file having a future timestamp. Build
  # outputs have no meaningful mtime anyway.
  tar -C "$BUILD_DIR/dist" -czf - . \
    | "${SSH[@]}" "cd $APP_DIR && rm -rf dist.incoming && mkdir dist.incoming \
        && tar -xzmf - -C dist.incoming \
        && rm -rf dist.old && { [ -d dist ] && mv dist dist.old || true; } \
        && mv dist.incoming dist && rm -rf dist.old && echo '  dist swapped'"
fi

# --- dependencies -------------------------------------------------------------
NEED_DEPS=0
"${SSH[@]}" "test -d $APP_DIR/node_modules" || NEED_DEPS=1
if [[ "$NEED_DEPS" == 0 && -n "$DEPLOYED_SHA" ]] \
   && ! git -C "$REPO" diff --quiet "${DEPLOYED_SHA}..${BRANCH}" -- package.json package-lock.json 2>/dev/null; then
  NEED_DEPS=1
fi
if [[ "$NEED_DEPS" == 1 ]]; then
  say "installing runtime dependencies (npm ci --omit=dev)"
  "${SSH[@]}" "cd $APP_DIR && npm ci --omit=dev" 2>&1 | tail -4
else
  say "dependencies unchanged"
fi

# --- restart ------------------------------------------------------------------
say "restarting $SERVICE"
"${SSH[@]}" "sudo systemctl restart $SERVICE"
sleep 5
STATE=$("${SSH[@]}" "systemctl is-active $SERVICE" || true)
if [[ "$STATE" != "active" ]]; then
  "${SSH[@]}" "sudo journalctl -u $SERVICE -n 40 --no-pager"
  die "service is '$STATE' — rollback: $ROLLBACK"
fi
"${SSH[@]}" "sudo journalctl -u $SERVICE -n 4 --no-pager | sed 's/^/  /'"

# --- verify from the outside --------------------------------------------------
say "verifying from the outside"
FAILED=0
check() {
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$2" || echo 000)
  printf '  %-40s %s\n' "$1" "$code"
  [[ "$code" == "200" ]] || FAILED=1
}

check "${BASE}api/v1/health"   "${SITE}${BASE}api/v1/health"
check "${BASE}api/v1/stations" "${SITE}${BASE}api/v1/stations"

if "${SSH[@]}" "test -f $APP_DIR/dist/index.html"; then
  check "$BASE" "${SITE}${BASE}"
  # index.html answers 200 even when the assets beside it never arrived or were
  # built for a different base, so follow the references it actually emits —
  # that is the check that catches a half-swapped dist/ or a base mismatch.
  # macOS ships Bash 3.2, which has arrays but no mapfile builtin.
  ASSETS=()
  while IFS= read -r asset; do
    ASSETS+=("$asset")
  done < <(curl -sS --max-time 20 "${SITE}${BASE}" \
    | grep -oE '(src|href)="[^"]*assets/[^"]+"' | sed 's/.*"\(.*\)"/\1/' | sort -u)
  if [[ ${#ASSETS[@]} -eq 0 ]]; then
    warn "the served index.html references nothing under assets/ — wrong build?"
    FAILED=1
  else
    # Expanding an empty array under nounset also fails in Bash 3.2.
    for asset in "${ASSETS[@]}"; do
      [[ "$asset" == /* ]] || asset="${BASE}${asset}"
      check "  ${asset##*/}" "${SITE}${asset}"
    done
  fi
  # The offline shell; its scope is capped by its own path, so it has to be
  # served from inside the prefix rather than the domain root.
  check "  sw.js" "${SITE}${BASE}sw.js"
else
  warn "no dist/index.html on the box — the API is up but the page will 404"
fi

if [[ "$FAILED" == 1 ]]; then die "something is not answering 200 — rollback: $ROLLBACK"; fi

# --- feed health --------------------------------------------------------------
# The port opens before the first upstream fetch lands, so a freshly restarted
# service honestly reports "degraded" for a few seconds. Wait it out rather than
# printing a scary word that stops being true a moment later.
# The gate is "every feed fetched without an error", not the app's own status
# field. That field is a product judgement that moves with the app — at the time
# of writing it demands all nine feeds be under 90s old, which subway-alerts
# never is, since an alerts feed only republishes when alerts change. Deciding
# here on facts we can see keeps a deploy from being declared a failure by a
# definition that has nothing to do with the deploy. The app's status is still
# printed, just not obeyed.
say "waiting for the feeds"
for attempt in $(seq 1 12); do
  HEALTH=$(curl -sS --max-time 20 "${SITE}${BASE}api/v1/health" || echo '{}')
  READY=$(printf '%s' "$HEALTH" | python3 -c '
import json, sys
feeds = (json.load(sys.stdin).get("feeds") or [])
print("yes" if feeds and all(f.get("timestamp") and not f.get("error") for f in feeds) else "no")' 2>/dev/null || echo no)
  [[ "$READY" == "yes" ]] && break
  [[ "$attempt" == 12 ]] || sleep 3
done
printf '%s' "$HEALTH" | python3 -c '
import json, sys
h = json.load(sys.stdin); feeds = h.get("feeds") or []
bad  = [f["id"] for f in feeds if f.get("error")]
cold = [f["id"] for f in feeds if not f.get("error") and not f.get("timestamp")]
ages = [f["age"] for f in feeds if isinstance(f.get("age"), int)]
def row(label, value): print("  " + label.ljust(40) + " " + str(value))
row("feeds fetched", str(len(feeds) - len(bad) - len(cold)) + "/" + str(len(feeds)))
row("stations", h.get("stationCount", "?"))
if ages: row("feed age", str(min(ages)) + "s to " + str(max(ages)) + "s")
if bad:  row("errors", " ".join(bad))
if cold: row("never loaded", " ".join(cold))
row("app self-report", h.get("status", "?"))' 2>/dev/null || echo "  (could not read /health)"
# Upstream MTA outages are not this deploy's fault either, so report and move on.
[[ "$READY" == "yes" ]] || warn "not every feed fetched cleanly — see above"

# Record success only after dependency installation, restart, and verification.
echo "$LOCAL_SHA" | "${SSH[@]}" "cat > $APP_DIR/DEPLOYED_SHA"

# --- prune old backups --------------------------------------------------------
prune_local_backups "$BACKUP_DIR" "$SERVICE" "$KEEP_BACKUPS"

say "done — ${BRANCH} @ ${LOCAL_SHA:0:7} is live at ${SITE}${BASE}"
echo "  logs:     ssh -i $KEY $HOST 'journalctl -u $SERVICE -f'"
echo "  rollback from this machine: $ROLLBACK"
