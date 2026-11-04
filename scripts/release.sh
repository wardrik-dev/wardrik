#!/usr/bin/env bash
# Releases Wardrik: each package whose version isn't published yet is tagged and published, at its
# own version. Packages are versioned independently: bump one by PR when it changes.
#
#   scripts/release.sh          # dry run: checks everything, changes nothing
#   scripts/release.sh --go     # publishes to Hex and npm, then tags and pushes the tags
#
# The repos are checked out side by side, as for WARDRIK_LOCAL=1: ../wardrik_core and so on.
# Every wardrik or wardrik_* checkout whose mix.exs has a package() is a Hex package; the
# TypeScript SDK goes to npm. Hex packages publish in the order of their sibling deps.
#
# Each repo is tagged v<its version> on origin/main, after every package is published: a tag starts
# that repo's release build, which fetches its deps from Hex. Safe to rerun after a failure: tags
# already there, and versions already published, are skipped. To add a step, write a function and name it
# in STEPS.
set -euo pipefail

WORK=${WORK:-$(cd "$(dirname "$0")/../.." && pwd)}
GO=
for flag in "$@"; do
  case $flag in
    --go) GO=1 ;;
    *) echo "unknown flag: $flag" >&2; exit 2 ;;
  esac
done
NPM_PACKAGE=@wardrik/sdk
SDK=wardrik_typescript
STEPS=(publish_hex publish_npm tag_repos)

hex_packages() {
  local dir
  for dir in "$WORK"/wardrik "$WORK"/wardrik_*; do
    [[ $(basename "$dir") == *-* ]] && continue
    grep -q 'package: package()' "$dir/mix.exs" 2>/dev/null && basename "$dir"
  done
}

mapfile -t HEX < <(hex_packages)

problems=0
say() { printf '%s\n' "$*"; }
problem() { say "  !! $*"; problems=$((problems + 1)); }

version_of() {
  case $1 in
    "$SDK") node -p "require('$WORK/$1/package.json').version" ;;
    *) grep -m1 -oE '(@version |version: )"[^"]+"' "$WORK/$1/mix.exs" | cut -d'"' -f2 ;;
  esac
}

on_hex() { curl -fsS "https://hex.pm/api/packages/$1/releases/$(version_of "$1")" >/dev/null 2>&1; }
on_npm() { [[ $(npm view "$NPM_PACKAGE@$(version_of $SDK)" version 2>/dev/null) == "$(version_of $SDK)" ]]; }

unpublished() {
  case $1 in
    "$SDK") ! on_npm ;;
    *) ! on_hex "$1" ;;
  esac
}

untagged() { ! git -C "$WORK/$1" ls-remote --exit-code -q --tags origin "v$(version_of "$1")" >/dev/null; }

# What this run releases: each package whose version isn't published or tagged yet, as it starts.
RELEASING=()
for repo in "${HEX[@]}" "$SDK"; do
  if unpublished "$repo" || untagged "$repo"; then RELEASING+=("$repo"); fi
done
releasing() { [[ " ${RELEASING[*]} " == *" $1 "* ]]; }

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
  if releasing "$SDK" && unpublished "$SDK"; then
    user=$(npm whoami 2>/dev/null) || true
    [[ -n $user ]] && say "  npm: $user" || problem "not signed in to npm: npm login"
  fi

  say "-- repos"
  local repo dir main tag tagged
  for repo in "${HEX[@]}" "$SDK"; do
    dir="$WORK/$repo"
    [[ -d $dir/.git ]] || { problem "$repo isn't checked out at $dir"; continue; }
    git -C "$dir" fetch -q origin main || problem "$repo: fetch failed"
    main=$(git -C "$dir" rev-parse origin/main)
    [[ $(git -C "$dir" branch --show-current) == main ]] || problem "$repo isn't on main"
    [[ -z $(git -C "$dir" status --porcelain) ]] || problem "$repo has uncommitted changes"
    [[ $(git -C "$dir" rev-parse HEAD) == "$main" ]] || problem "$repo main isn't origin/main"
    tag="v$(version_of "$repo")"
    if tagged=$(git -C "$dir" rev-parse -q --verify "refs/tags/$tag^{commit}"); then
      releasing "$repo" && [[ $tagged != "$main" ]] && problem "$repo has $tag on another commit"
    fi
  done

  say "-- hex, in order"
  local pkg
  for pkg in $(hex_order); do
    if ! releasing "$pkg"; then say "  $pkg $(version_of "$pkg"): released"
    elif unpublished "$pkg"; then say "  $pkg $(version_of "$pkg"): publish, then tag"
    else say "  $pkg $(version_of "$pkg"): on Hex, tag"
    fi
  done

  say "-- npm"
  if ! releasing "$SDK"; then say "  $NPM_PACKAGE $(version_of $SDK): released"
  elif unpublished "$SDK"; then say "  $NPM_PACKAGE $(version_of $SDK): publish as next and latest, then tag"
  else say "  $NPM_PACKAGE $(version_of $SDK): on npm, tag"
  fi
}

tag_repos() {
  local repo dir tag
  for repo in "${HEX[@]}" "$SDK"; do
    releasing "$repo" || continue
    dir="$WORK/$repo"
    tag="v$(version_of "$repo")"
    git -C "$dir" rev-parse -q --verify "refs/tags/$tag" >/dev/null ||
      git -C "$dir" tag -s "$tag" -m "$tag" origin/main
    git -C "$dir" push -q origin "$tag"
    say "  $repo $tag"
  done
}

publish_hex() {
  local pkg
  for pkg in $(hex_order); do
    releasing "$pkg" && unpublished "$pkg" || continue
    say "  $pkg $(version_of "$pkg")"
    # Lockfiles pin siblings at the last release. Resolve against Hex, then restore the lock.
    (cd "$WORK/$pkg" && env -u WARDRIK_LOCAL mix deps.get >/dev/null &&
      env -u WARDRIK_LOCAL mix hex.publish --yes)
    git -C "$WORK/$pkg" checkout -q -- mix.lock
  done
}

publish_npm() {
  releasing "$SDK" && unpublished "$SDK" || return 0
  local version
  version=$(version_of $SDK)
  (cd "$WORK/$SDK" && npm ci && npm run check &&
    npm run build && npm publish --tag next &&
    npm dist-tag add "$NPM_PACKAGE@$version" latest)
}

say "== Release from $WORK"
check
if ((problems > 0)); then say "== $problems problem(s). Nothing changed."; exit 1; fi
if [[ -z $GO ]]; then say "== Dry run clean. Rerun with --go to release."; exit 0; fi
for step in "${STEPS[@]}"; do say "-- $step"; "$step"; done
say "== Released."
