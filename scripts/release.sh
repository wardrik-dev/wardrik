#!/usr/bin/env bash
# Releases Wardrik: each package whose version isn't published yet is published and tagged, at its
# own version. Packages are versioned independently: bump one by PR when it changes.
#
# A package that stores data keeps a corpus of it for each version, which later versions must
# read. The version's bump PR writes it; see test/*/corpus_test.exs.
#
#   scripts/release.sh          # dry run: checks everything, changes nothing
#   scripts/release.sh --go     # publishes to Hex and npm, then tags and pushes the tags
#
# Every packages/* and extensions/* directory whose mix.exs has a package() is a Hex package; the
# TypeScript SDK in sdk/typescript goes to npm. Hex packages publish in the order of their sibling
# deps, resolved from Hex with WARDRIK_HEX=1.
#
# Each package is tagged <name>-v<its version> on origin/main, after every package is published:
# wardrik_daemon-v* starts the daemon's release build, which fetches its deps from Hex. Safe to rerun
# after a failure: tags already there, and versions already published, are skipped. To add a step,
# write a function and name it in STEPS.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
GO=
for flag in "$@"; do
  case $flag in
    --go) GO=1 ;;
    *) echo "unknown flag: $flag" >&2; exit 2 ;;
  esac
done
NPM_PACKAGE=@wardrik/sdk
SDK=typescript
STEPS=(publish_hex publish_npm tag_packages)

hex_packages() {
  local dir
  for dir in "$ROOT"/packages/* "$ROOT"/extensions/*; do
    grep -q 'package: package()' "$dir/mix.exs" 2>/dev/null && basename "$dir"
  done
}

dir_of() {
  case $1 in
    "$SDK") echo "$ROOT/sdk/$SDK" ;;
    *) for dir in "$ROOT"/packages/"$1" "$ROOT"/extensions/"$1"; do [[ -d $dir ]] && echo "$dir"; done ;;
  esac
}

mapfile -t HEX < <(hex_packages)

problems=0
say() { printf '%s\n' "$*"; }
problem() { say "  !! $*"; problems=$((problems + 1)); }

version_of() {
  case $1 in
    "$SDK") node -p "require('$(dir_of "$1")/package.json').version" ;;
    *) grep -m1 -oE '(@version |version: )"[^"]+"' "$(dir_of "$1")/mix.exs" | cut -d'"' -f2 ;;
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

tag_of() { echo "$1-v$(version_of "$1")"; }
untagged() { ! git -C "$ROOT" ls-remote --exit-code -q --tags origin "$(tag_of "$1")" >/dev/null; }

# What this run releases: each package whose version isn't published or tagged yet, as it starts.
RELEASING=()
for repo in "${HEX[@]}" "$SDK"; do
  if unpublished "$repo" || untagged "$repo"; then RELEASING+=("$repo"); fi
done
releasing() { [[ " ${RELEASING[*]} " == *" $1 "* ]]; }

hex_order() {
  for pkg in "${HEX[@]}"; do
    say "$pkg $pkg"
    grep -oE 'sibling\(:wardrik[a-z_]*' "$(dir_of "$pkg")/mix.exs" | sed 's/sibling(://' |
      sort -u | while read -r dep; do say "$dep $pkg"; done
  done | tsort
}

check() {
  say "-- accounts"
  local user
  user=$(cd "$(dir_of wardrik_core)" && mix hex.user whoami 2>/dev/null | tail -1) || true
  [[ -n $user ]] && say "  hex: $user" || problem "not signed in to Hex: mix hex.user auth"
  if releasing "$SDK" && unpublished "$SDK"; then
    user=$(npm whoami 2>/dev/null) || true
    [[ -n $user ]] && say "  npm: $user" || problem "not signed in to npm: npm login"
  fi

  say "-- repo"
  local repo main tag tagged
  git -C "$ROOT" fetch -q --tags origin main || problem "fetch failed"
  main=$(git -C "$ROOT" rev-parse origin/main)
  [[ $(git -C "$ROOT" branch --show-current) == main ]] || problem "not on main"
  [[ -z $(git -C "$ROOT" status --porcelain) ]] || problem "uncommitted changes"
  [[ $(git -C "$ROOT" rev-parse HEAD) == "$main" ]] || problem "main isn't origin/main"
  for repo in "${HEX[@]}" "$SDK"; do
    tag=$(tag_of "$repo")
    if tagged=$(git -C "$ROOT" rev-parse -q --verify "refs/tags/$tag^{commit}"); then
      releasing "$repo" && [[ $tagged != "$main" ]] && problem "$tag is on another commit"
    fi
  done

  say "-- stored formats"
  local dir corpus_test
  for repo in "${HEX[@]}"; do
    dir=$(dir_of "$repo")
    corpus_test=$(compgen -G "$dir/test/*/corpus_test.exs" | head -1) || continue
    releasing "$repo" || continue
    if [[ -f $dir/test/corpus/$(version_of "$repo").json ]]; then
      say "  $repo $(version_of "$repo"): corpus kept"
    else
      problem "$repo $(version_of "$repo") has no corpus: (cd ${dir#"$ROOT"/} && mix test ${corpus_test#"$dir"/} --only corpus), then commit it"
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

tag_packages() {
  local repo tag
  for repo in "${HEX[@]}" "$SDK"; do
    releasing "$repo" || continue
    tag=$(tag_of "$repo")
    git -C "$ROOT" rev-parse -q --verify "refs/tags/$tag" >/dev/null ||
      git -C "$ROOT" tag -s "$tag" -m "$tag" origin/main
    git -C "$ROOT" push -q origin "$tag"
    say "  $tag"
  done
}

publish_hex() {
  local pkg
  for pkg in $(hex_order); do
    releasing "$pkg" && unpublished "$pkg" || continue
    say "  $pkg $(version_of "$pkg")"
    # In this repo siblings come by path, so a lockfile's Hex pins for them go stale. Unlock them,
    # if it has any, resolve against Hex, publish, then restore the lock.
    (cd "$(dir_of "$pkg")" &&
      siblings=$(grep -oE '^  "wardrik[a-z_]*"' mix.lock | tr -d ' "' || true) &&
      { [[ -z $siblings ]] || WARDRIK_HEX=1 mix deps.unlock $siblings; } &&
      WARDRIK_HEX=1 mix deps.get >/dev/null &&
      WARDRIK_HEX=1 mix hex.publish --yes)
    git -C "$ROOT" checkout -q -- "$(dir_of "$pkg")/mix.lock"
  done
}

publish_npm() {
  releasing "$SDK" && unpublished "$SDK" || return 0
  local version
  version=$(version_of $SDK)
  (cd "$(dir_of $SDK)" && npm ci && npm run check &&
    npm run build && npm publish --tag next &&
    npm dist-tag add "$NPM_PACKAGE@$version" latest)
}

say "== Release from $ROOT"
check
if ((problems > 0)); then say "== $problems problem(s). Nothing changed."; exit 1; fi
if [[ -z $GO ]]; then say "== Dry run clean. Rerun with --go to release."; exit 0; fi
for step in "${STEPS[@]}"; do say "-- $step"; "$step"; done
say "== Released."
