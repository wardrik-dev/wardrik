#!/usr/bin/env bash
# shellcheck disable=SC2016 # the scripts in single quotes are expanded in the containers
#
# Installs a release tarball with deploy/install.sh on fresh Linux distributions,
# each a Docker container, and checks what it does on each: on those the
# release runs on, it installs and the daemon starts, answers and stops; on
# those it does not, the script refuses before installing anything, and says
# why.
#
#   docker build --target tarball --output type=local,dest=dist .
#   dev/distros.sh dist/wardrikd-0.1.0.tar.gz
#
# The tarball is renamed as a release names it, and served to the script over
# file:// with a SHA256SUMS beside it, so each install is the one curl | sh
# makes, and rik is asked as well as wardrik. On one distribution it also
# installs as root beside a rik of the machine's own, which it leaves alone,
# installs again, moves up through two more versions, and refuses a tarball
# that is not the one SHA256SUMS lists.
set -euo pipefail


repo=$(cd "$(dirname "$0")/.." && pwd -P)
[ $# -eq 1 ] && [ -f "$1" ] || { echo "usage: dev/distros.sh TARBALL" >&2; exit 1; }
built=$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")
version=$(sed -n 's/^ *@version "\(.*\)"$/\1/p' "$repo/packages/wardrik_daemon/mix.exs")

say() { printf '==> %s\n' "$*"; }
die() { printf 'distros: %s\n' "$*" >&2; exit 1; }

served=$(mktemp -d)
trap 'rm -rf "$served"' EXIT
arch=$(uname -m)
cp "$built" "$served/wardrik-$version-linux-$arch.tar.gz"
cp "$repo/deploy/install.sh" "$served/"
(cd "$served" && sha256sum wardrik-*.tar.gz > SHA256SUMS)

# Read by a user of its own in each container, whatever its uid.
chmod -R a+rX "$served"

# Runs the script $2 in a fresh container of the image $1, with the tarball
# served at /served, and curl installed where the image's package manager can
# still install it. The script refuses a distribution before it needs curl, so
# an old one whose archive has moved is checked all the same.
run() {
  docker run --rm -e LANG=C.UTF-8 -e VERSION="$version" -e ARCH="$arch" -v "$served:/served:ro" "$1" sh -euc "
    if command -v apt-get > /dev/null; then
      { apt-get update -qq && apt-get install -y -qq curl ca-certificates; } > /dev/null 2>&1 || true
    elif command -v apk > /dev/null; then
      apk add -q curl > /dev/null 2>&1 || true
    fi
    $2
  "
}

# As a user of its own, as a person installs it: then the daemon is started,
# asked, given a token, and stopped.
installs() {
  say "$1: installs and runs"
  run "$1" '
    useradd --create-home tester
    su tester -c "
      set -eu
      WARDRIK_DOWNLOAD_URL=file:///served WARDRIK_VERSION=$VERSION sh /served/install.sh
      export PATH=\$HOME/.local/bin:\$PATH
      wardrik version
      wardrik start
      rik status | grep -q \"0 agents\"
      wardrik token create dev --resource \"*\" --role owner | grep -q \"This is the only time it is shown\"
      wardrik stop
    "
  '
}

refuses() {
  say "$1: refuses, saying $2"
  out=$(run "$1" 'WARDRIK_DOWNLOAD_URL=file:///served WARDRIK_VERSION=$VERSION sh /served/install.sh' 2>&1) &&
    die "$1 installed a release that does not run there"
  grep -q "$2" <<< "$out" || die "$1 refused without saying $2: $out"
}

installs ubuntu:22.04
installs ubuntu:24.04
installs debian:12
installs debian:13

refuses debian:11 "needs glibc 2.35 or later"
refuses alpine:3.22 "needs glibc"

say "ubuntu:24.04: as root, beside a rik of its own, again, through two more versions, and not over a changed tarball"
run ubuntu:24.04 '
  printf "#!/bin/sh\necho theirs\n" > /usr/bin/rik && chmod +x /usr/bin/rik
  cp -r /served /versions
  cd /versions
  for next in 9.0.1 9.0.2; do cp wardrik-$VERSION-linux-$ARCH.tar.gz wardrik-$next-linux-$ARCH.tar.gz; done
  sha256sum wardrik-*.tar.gz > SHA256SUMS

  sh install.sh wardrik-$VERSION-linux-$ARCH.tar.gz > installed.txt
  grep -q "installed, as /usr/local/bin/wardrik" installed.txt
  grep -q "There is a rik here already, /usr/bin/rik" installed.txt
  [ ! -e /usr/local/bin/rik ] && [ "$(rik)" = theirs ]
  sh install.sh wardrik-$VERSION-linux-$ARCH.tar.gz | grep -q "already in /opt/wardrik/$VERSION"
  sh install.sh wardrik-9.0.1-linux-$ARCH.tar.gz > /dev/null
  sh install.sh wardrik-9.0.2-linux-$ARCH.tar.gz > /dev/null
  [ "$(readlink /opt/wardrik/current)" = 9.0.2 ]
  [ -d /opt/wardrik/9.0.1 ] && [ ! -e /opt/wardrik/$VERSION ]
  /usr/local/bin/wardrik version

  echo tampered >> wardrik-9.0.1-linux-$ARCH.tar.gz
  if sh install.sh wardrik-9.0.1-linux-$ARCH.tar.gz 2> refused.txt; then exit 1; fi
  grep -q "is not the file SHA256SUMS lists" refused.txt
'

say "Every distribution did what it should"
