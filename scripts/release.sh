#!/usr/bin/env bash
# Releases Wardrik: tags every repo, publishes the Elixir packages to Hex in dependency order,
# and, with --npm, the TypeScript SDK to npm.
#
#   scripts/release.sh 0.1.0-rc.3              # dry run: checks everything, changes nothing
#   scripts/release.sh 0.1.0-rc.3 --go         # tags, pushes the tags, publishes to Hex
#   scripts/release.sh 0.1.0-rc.3 --npm --go   # and the SDK to npm
#
# The SDK is versioned on its own: it follows the protocol it's generated from, not the server.
# Pass --npm when it changed, after bumping its package.json to VERSION.
#
# The repos are checked out side by side, as for WARDRIK_LOCAL=1: ../wardrik_core and so on.
# Bump the versions in mix.exs, package.json and the sibling requirements first, by PR. A package
# whose version isn't VERSION didn't change: it isn't tagged or published.
#
# Tags go on origin/main. Safe to rerun after a failure: tags already there, and versions already
# on Hex or npm, are skipped. To add a step, write a function and name it in STEPS.
set -euo pipefail

WORK=${WORK:-$(cd "$(dirname "$0")/../.." && pwd)}
VERSION=${1:?usage: $0 VERSION [--npm] [--go]}
shift
GO=
NPM=
for flag in "$@"; do
  case $flag in
    --go) GO=1 ;;
    --npm) NPM=1 ;;
    *) echo "unknown flag: $flag" >&2; exit 2 ;;
  esac
done
TAG="v$VERSION"
NPM_PACKAGE=@wardrik/sdk
STEPS=(tag_repos publish_hex)
[[ -n $NPM ]] && STEPS+=(publish_npm)

# Every package on Hex. The publish order comes from their sibling deps, not from this list.
HEX=(wardrik wardrik_brave wardrik_channel wardrik_core wardrik_daemon wardrik_events
  wardrik_gateway wardrik_http wardrik_lua wardrik_mcp wardrik_oauth wardrik_policy
  wardrik_protocol wardrik_research wardrik_slack wardrik_store wardrik_testing wardrik_triggers
  wardrik_vault wardrik_workspace)
# Built from their checkouts, so those must be clean on main.
BUILT=("${HEX[@]}")
[[ -n $NPM ]] && BUILT+=(wardrik_typescript)
# Only tagged. Their checkouts may be on any branch.
TAGGED=(wardrik_docs)

problems=0
say() { printf '%s\n' "$*"; }
problem() { say "  !! $*"; problems=$((problems + 1)); }

version_of() {
  case $1 in
    wardrik_typescript) node -p "require('$WORK/$1/package.json').version" ;;
    wardrik_docs) say "$VERSION" ;;
    *) grep -m1 -oE '(@version |version: )"[^"]+"' "$WORK/$1/mix.exs" | cut -d'"' -f2 ;;
  esac
}

released() { [[ $(version_of "$1") == "$VERSION" ]]; }
on_hex() { curl -fsS "https://hex.pm/api/packages/$1/releases/$VERSION" >/dev/null 2>&1; }
on_npm() { [[ $(npm view "$NPM_PACKAGE@$VERSION" version 2>/dev/null) == "$VERSION" ]]; }

hex_order() {
  for pkg in "${HEX[@]}"; do
    say "$pkg $pkg"
    grep -oE 'sibling\(:wardrik[a-z_]*' "$WORK/$pkg/mix.exs" | sed 's/sibling(://' |
      sort -u | while read -r dep; do say "$dep $pkg"; done
  done | tsort
}

check() {
  say "-- accounts"
  local user
  user=$(cd "$WORK/wardrik_core" && mix hex.user whoami 2>/dev/null | tail -1) || true
  [[ -n $user ]] && say "  hex: $user" || problem "not signed in to Hex: mix hex.user auth"
  if [[ -n $NPM ]]; then
    user=$(npm whoami 2>/dev/null) || true
    [[ -n $user ]] && say "  npm: $user" || problem "not signed in to npm: npm login"
  fi

  say "-- repos"
  local repo dir main tagged
  for repo in "${BUILT[@]}" "${TAGGED[@]}"; do
    dir="$WORK/$repo"
    [[ -d $dir/.git ]] || { problem "$repo isn't checked out at $dir"; continue; }
    git -C "$dir" fetch -q origin main || problem "$repo: fetch failed"
    main=$(git -C "$dir" rev-parse origin/main)
    if [[ " ${BUILT[*]} " == *" $repo "* ]]; then
      [[ $(git -C "$dir" branch --show-current) == main ]] || problem "$repo isn't on main"
      [[ -z $(git -C "$dir" status --porcelain) ]] || problem "$repo has uncommitted changes"
      [[ $(git -C "$dir" rev-parse HEAD) == "$main" ]] || problem "$repo main isn't origin/main"
    fi
    if ! released "$repo"; then
      say "  $repo stays at $(version_of "$repo")"
    elif tagged=$(git -C "$dir" rev-parse -q --verify "refs/tags/$TAG^{commit}"); then
      [[ $tagged == "$main" ]] || problem "$repo has $TAG on another commit"
    fi
  done

  say "-- hex, in order"
  local pkg
  for pkg in $(hex_order); do
    if ! released "$pkg"; then continue
    elif on_hex "$pkg"; then say "  $pkg: already on Hex"
    else say "  $pkg: publish"
    fi
  done

  say "-- npm"
  if [[ -z $NPM ]]; then say "  $NPM_PACKAGE: skipped; --npm publishes it"
  elif ! released wardrik_typescript; then problem "package.json isn't $VERSION"
  elif on_npm; then say "  $NPM_PACKAGE@$VERSION: already on npm"
  else say "  $NPM_PACKAGE@$VERSION: publish, as next and latest"
  fi
}

tag_repos() {
  local repo dir
  for repo in "${BUILT[@]}" "${TAGGED[@]}"; do
    released "$repo" || continue
    dir="$WORK/$repo"
    git -C "$dir" rev-parse -q --verify "refs/tags/$TAG" >/dev/null ||
      git -C "$dir" tag -s "$TAG" -m "$TAG" origin/main
    git -C "$dir" push -q origin "$TAG"
    say "  $repo"
  done
}

publish_hex() {
  local pkg
  for pkg in $(hex_order); do
    released "$pkg" && ! on_hex "$pkg" || continue
    say "  $pkg"
    # Lockfiles pin siblings at the last release. Resolve against Hex, then restore the lock.
    (cd "$WORK/$pkg" && env -u WARDRIK_LOCAL mix deps.get >/dev/null &&
      env -u WARDRIK_LOCAL mix hex.publish --yes)
    git -C "$WORK/$pkg" checkout -q -- mix.lock
  done
}

publish_npm() {
  released wardrik_typescript && ! on_npm || return 0
  (cd "$WORK/wardrik_typescript" && npm ci && npm run check &&
    npm run build && npm publish --tag next &&
    npm dist-tag add "$NPM_PACKAGE@$VERSION" latest)
}

say "== $TAG from $WORK"
check
if ((problems > 0)); then say "== $problems problem(s). Nothing changed."; exit 1; fi
if [[ -z $GO ]]; then say "== Dry run clean. Rerun with --go to release."; exit 0; fi
for step in "${STEPS[@]}"; do say "-- $step"; "$step"; done
say "== Released $TAG."
