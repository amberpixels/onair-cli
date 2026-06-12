#!/usr/bin/env bash
set -euo pipefail

# Show the release currently running on Heroku prod, plus any pending
# build that's about to replace it. Uses the Platform API releases/slug
# endpoints (not `heroku builds`) so rollbacks and pinned releases report
# the commit that is actually running, not just the newest build.
# "Behind" is measured against origin/main via ls-remote, so it's accurate
# even when the local checkout hasn't been pulled.

APP="${HEROKU_APP:-acme-prod}"
REPO="${GITHUB_REPO:-acme/widgets}"

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
DIM='\033[2m'
PURPLE='\033[38;5;176m'
CYAN='\033[0;36m'
RESET='\033[0m'

die() {
  printf "\n  %berror: %s%b\n" "$YELLOW" "$1" "$RESET" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || die "jq is required but not installed (brew install jq)"

TOKEN=$(heroku auth:token 2>/dev/null) || die "heroku auth:token failed — are you logged in?"

api() {
  curl -sf --max-time 15 \
    -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/vnd.heroku+json; version=3" \
    "$@"
}

# Current release: version, description, created_at, slug id.
RELEASE=$(api -H "Range: version ..; order=desc, max=1" "https://api.heroku.com/apps/$APP/releases") ||
  die "failed to fetch releases for $APP"
REL_VERSION=$(jq -r '.[0].version // empty' <<<"$RELEASE")
REL_DESC=$(jq -r '.[0].description // empty' <<<"$RELEASE")
REL_AT=$(jq -r '.[0].created_at // empty' <<<"$RELEASE")
REL_SLUG=$(jq -r '.[0].slug.id // empty' <<<"$RELEASE")

# The slug records the commit the running release was built from — the
# only reliable source after a rollback, when `heroku builds` still lists
# the newer (no-longer-running) build at the top.
DEPLOYED_SHA=""
if [ -n "$REL_SLUG" ]; then
  DEPLOYED_SHA=$(api "https://api.heroku.com/apps/$APP/slugs/$REL_SLUG" | jq -r '.commit // empty') || DEPLOYED_SHA=""
fi

# Recent builds: newest pending one (deploy in flight) and newest
# succeeded one (to detect a pinned/rolled-back state).
BUILDS=$(api -H "Range: created_at ..; order=desc, max=10" "https://api.heroku.com/apps/$APP/builds") ||
  die "failed to fetch builds for $APP"
PENDING_SHA=$(jq -r '[.[] | select(.status == "pending")][0].source_blob.version // empty' <<<"$BUILDS")
PENDING_AT=$(jq -r '[.[] | select(.status == "pending")][0].created_at // empty' <<<"$BUILDS")
LATEST_BUILD_SHA=$(jq -r '[.[] | select(.status == "succeeded")][0].source_blob.version // empty' <<<"$BUILDS")

# Tip of origin/main straight from the remote — no pull required. Falls
# back to the local origin/main ref when offline.
REMOTE_HEAD=$(git ls-remote origin refs/heads/main 2>/dev/null | cut -f1 || true)
[ -n "$REMOTE_HEAD" ] || REMOTE_HEAD=$(git rev-parse origin/main 2>/dev/null || true)

# Lazy fetch: only hit the remote if a SHA we need is missing locally.
have_locally() { git cat-file -e "${1}^{commit}" 2>/dev/null; }

FETCHED=0
# Best-effort: triggers at most one fetch if a needed SHA is missing. The
# commit may still be absent afterward (force-pushed away, untracked branch);
# callers degrade gracefully via render_row's "(commit not found)" fallback.
fetch_if_missing() {
  local sha="$1"
  [ -z "$sha" ] && return 0
  have_locally "$sha" && return 0
  if [ "$FETCHED" -eq 0 ]; then
    FETCHED=1
    git fetch --quiet origin 2>/dev/null || true
  fi
}

fetch_if_missing "$DEPLOYED_SHA"
fetch_if_missing "$PENDING_SHA"
fetch_if_missing "$REMOTE_HEAD"

fmt_age() {
  local diff="$1"
  if ((diff < 60)); then printf '%ds ago' "$diff"
  elif ((diff < 3600)); then printf '%dm ago' $((diff / 60))
  elif ((diff < 86400)); then printf '%dh ago' $((diff / 3600))
  else printf '%dd ago' $((diff / 86400)); fi
}

# "2d ago"-style age from an ISO 8601 timestamp (BSD date, GNU fallback).
rel_age() {
  local ts="$1" born
  [ -z "$ts" ] && return 0
  born=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null) ||
    born=$(date -d "$ts" +%s 2>/dev/null) || return 0
  fmt_age $(( $(date +%s) - born ))
}

epoch_age() {
  [ -z "${1:-}" ] && return 0
  fmt_age $(( $(date +%s) - $1 ))
}

# OSC 8 terminal hyperlink. Terminals that don't support it (rare these
# days) silently swallow the escape and show the plain text.
osc8_link() {
  local url="$1" text="$2"
  printf '\e]8;;%s\a%s\e]8;;\a' "$url" "$text"
}

# Append a clickable GitHub reference to a commit subject:
#  - if the subject ends in " (#1234)" (merge convention), strip it and
#    append " • ↗ #1234" linking to the PR
#  - otherwise, fall back to " • ↗ <short-sha>" linking to the commit
#  - if no SHA is provided either, return the subject unchanged
linkify_ref() {
  local subj="$1" sha="$2"
  if [[ "$subj" =~ ^(.*)\ \(#([0-9]+)\)$ ]]; then
    local base="${BASH_REMATCH[1]}"
    local pr="${BASH_REMATCH[2]}"
    local url="https://github.com/$REPO/pull/$pr"
    printf '%s • %s' "$base" "$(osc8_link "$url" "↗ #$pr")"
  elif [ -n "$sha" ]; then
    local short="${sha:0:9}"
    local url="https://github.com/$REPO/commit/$sha"
    printf '%s • %s' "$subj" "$(osc8_link "$url" "↗ $short")"
  else
    printf '%s' "$subj"
  fi
}

# "Mine" = authored by the local git identity. Squash merges keep the PR
# author's name but may carry a different email, so match on either.
MY_NAME=$(git config user.name 2>/dev/null || true)
MY_EMAIL=$(git config user.email 2>/dev/null || true)

is_mine() {
  local info an ae
  info=$(git log -1 --format='%an%x09%ae' "$1" 2>/dev/null) || return 1
  an="${info%%$'\t'*}"
  ae="${info#*$'\t'}"
  { [ -n "$MY_EMAIL" ] && [ "$ae" = "$MY_EMAIL" ]; } ||
    { [ -n "$MY_NAME" ] && [ "$an" = "$MY_NAME" ]; }
}

# Most recent commit of mine among the two commits just below the given
# head (the head itself excluded). Empty if none in the window.
my_commit_below() {
  git log --first-parent --skip=1 -2 --format='%H%x09%an%x09%ae' "$1" 2>/dev/null |
    awk -F'\t' -v n="$MY_NAME" -v e="$MY_EMAIL" \
      '(e != "" && $3 == e) || (n != "" && $2 == n) { print $1; exit }'
}

# Relationship between the deployed SHA and origin/main. Prints e.g.
# "★ current" (matches the remote tip) or "↓ 3 commits behind".
main_delta() {
  local sha="$1"
  [[ -z "$sha" || -z "$REMOTE_HEAD" ]] && return 0
  if [ "$sha" = "$REMOTE_HEAD" ]; then
    printf '%b★ current%b' "$GREEN" "$RESET"
    return 0
  fi
  have_locally "$sha" && have_locally "$REMOTE_HEAD" || return 0
  if git merge-base --is-ancestor "$sha" "$REMOTE_HEAD" 2>/dev/null; then
    local count
    count=$(git rev-list --count "${sha}..${REMOTE_HEAD}" 2>/dev/null)
    if [ -n "$count" ] && [ "$count" != "0" ]; then
      local word="commits"
      [ "$count" = "1" ] && word="commit"
      printf '%b↓ %s %s behind origin/main%b' "$YELLOW" "$count" "$word" "$RESET"
    fi
  fi
}

render_row() {
  local label="$1" color="$2" sha="$3" age="$4" extra="${5:-}"
  local short info subject author age_blurb
  short="${sha:0:9}"

  # Single git call for subject + author, tab-separated.
  info=$(git log -1 --format=$'%s\t%an' "$sha" 2>/dev/null || printf '(commit not found in local git)\t?')
  subject="${info%%$'\t'*}"
  author="${info#*$'\t'}"

  age_blurb=""
  [ -n "$age" ] && age_blurb="($age) "

  printf "  %b%s%b  %b%s%b  %b%sby %s%b%s\n" \
    "$color" "$label" "$RESET" "$BOLD" "$short" "$RESET" "$DIM" "$age_blurb" "$author" "$RESET" \
    "${extra:+  $extra}"
  printf "  %b→%b %s\n" "$DIM" "$RESET" "$(linkify_ref "$subject" "$sha")"
}

echo ""
printf "  %bHeroku %b%s%b\n" "$PURPLE" "$BOLD" "$APP" "$RESET"
echo ""

if [ -n "$PENDING_SHA" ]; then
  render_row "Pending: " "$YELLOW" "$PENDING_SHA" "$(rel_age "$PENDING_AT")"
  echo ""
fi

if [ -n "$DEPLOYED_SHA" ]; then
  render_row "Deployed:" "$GREEN" "$DEPLOYED_SHA" "$(rel_age "$REL_AT")" "$(main_delta "$DEPLOYED_SHA")"

  # Pinned / rolled back: a newer build succeeded but isn't what's running.
  if [ -n "$LATEST_BUILD_SHA" ] && [ "$LATEST_BUILD_SHA" != "$DEPLOYED_SHA" ] && [ -z "$PENDING_SHA" ]; then
    printf "  %b⏸ v%s (%s) — newer build %s succeeded but is not running%b\n" \
      "$YELLOW" "$REL_VERSION" "$REL_DESC" "${LATEST_BUILD_SHA:0:9}" "$RESET"
  fi

  # Someone else's commit is running, but mine is right below it: my merge
  # made it to prod, just absorbed by a later deploy. Say so explicitly.
  if have_locally "$DEPLOYED_SHA" && ! is_mine "$DEPLOYED_SHA"; then
    MINE_SHA=$(my_commit_below "$DEPLOYED_SHA")
    if [ -n "$MINE_SHA" ]; then
      MINE_HAD_BUILD=$(jq -r --arg sha "$MINE_SHA" \
        '[.[] | select(.source_blob.version == $sha and .status == "succeeded")] | length' <<<"$BUILDS")
      if [ "${MINE_HAD_BUILD:-0}" -gt 0 ]; then
        MINE_NOTE=$(printf '%b✓ released, then absorbed by current%b' "$CYAN" "$RESET")
      else
        MINE_NOTE=$(printf '%b✓ absorbed by current deploy%b' "$CYAN" "$RESET")
      fi
      echo ""
      render_row "Yours:   " "$CYAN" "$MINE_SHA" "$(epoch_age "$(git log -1 --format=%ct "$MINE_SHA" 2>/dev/null)")" "$MINE_NOTE"
    fi
  fi
else
  printf "  %bCould not resolve the running commit for v%s (%s).%b\n" "$YELLOW" "$REL_VERSION" "$REL_DESC" "$RESET"
fi

echo ""
