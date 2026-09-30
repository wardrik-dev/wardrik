#!/usr/bin/env bash
#
# Installs a release tarball with deploy/install.sh as a user of its own, in a
# container that runs systemd, and checks `wardrik service`: the daemon runs
# as the user's unit and answers, is running again after the container
# restarts, as after a reboot, and is gone once uninstalled. Root is refused.
#
#   docker build --target tarball --output type=local,dest=dist .
#   dev/service.sh dist/wardrikd-0.1.0.tar.gz
#
# The container is privileged, as systemd needs, and removed at the end.
# WARDRIK_SYSTEMD_IMAGE names the image, jrei/systemd-ubuntu:24.04 by default.
set -euo pipefail

# The scripts in single quotes are expanded in the container, not here.
# shellcheck disable=SC2016

repo=$(cd "$(dirname "$0")/.." && pwd -P)
[ $# -eq 1 ] && [ -f "$1" ] || { echo "usage: dev/service.sh TARBALL" >&2; exit 1; }
version=$(sed -n 's/^ *version: "\(.*\)",$/\1/p' "$repo/mix.exs")
image=${WARDRIK_SYSTEMD_IMAGE:-jrei/systemd-ubuntu:24.04}
box=wardrik-service-$$

say() { printf '==> %s\n' "$*"; }
die() { printf 'service: %s\n' "$*" >&2; exit 1; }

served=$(mktemp -d)
trap 'docker rm -f "$box" > /dev/null 2>&1 || true; rm -rf "$served"' EXIT
cp "$1" "$served/wardrik-$version-linux-x86_64.tar.gz"
cp "$repo/deploy/install.sh" "$served/"
chmod -R a+rX "$served"

docker run -d --name "$box" --privileged --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw -v "$served:/served:ro" "$image" > /dev/null

booted_system() {
  docker exec "$box" sh -c 'until systemctl is-system-running 2> /dev/null | grep -qE "running|degraded"; do sleep 1; done'
}

# Waits for the container's systemd, and the user's, which lingering starts.
# logind is what starts a lingering user's systemd; a machine starts it as it
# boots, and this image only when something first asks it, so it is asked.
booted() {
  booted_system
  docker exec "$box" systemctl start systemd-logind

  for _ in $(seq 60); do
    docker exec "$box" test -S /run/user/1001/bus 2> /dev/null && return 0
    sleep 1
  done
  die "the user's systemd did not start"
}

# Runs $1 as the user, as a login gives them: their systemd reachable, and
# the install script's bin directory on the PATH.
as_user() {
  docker exec -u tester -w /home/tester \
    -e XDG_RUNTIME_DIR=/run/user/1001 \
    -e DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus \
    -e LANG=C.UTF-8 \
    -e PATH=/home/tester/.local/bin:/usr/local/bin:/usr/bin:/bin \
    "$box" sh -euc "$1"
}

answers() {
  as_user 'for _ in $(seq 60); do wardrik status > /dev/null 2>&1 && exit 0; sleep 1; done; exit 1' ||
    die "the daemon did not answer"
}

booted_system
docker exec "$box" useradd --create-home --uid 1001 tester
docker exec "$box" loginctl enable-linger tester
booted

say "installs, and runs as the user's service"
as_user "sh /served/install.sh /served/wardrik-$version-linux-x86_64.tar.gz > /dev/null"
as_user 'wardrik service install' | tee /dev/stderr | grep -q "wardrik runs as wardrik.service"
answers
as_user 'systemctl --user is-enabled --quiet wardrik.service'
as_user 'wardrik status | grep -q "0 agents"'

say "refuses to run as root"
if refused=$(docker exec "$box" /home/tester/.local/bin/wardrik service install 2>&1); then
  die "service install ran as root"
fi
grep -q "you are root" <<< "$refused" || die "root was refused without saying why: $refused"

say "runs again after a restart"
docker restart "$box" > /dev/null
booted
answers

say "is gone once uninstalled"
as_user 'wardrik service uninstall' | grep -q "no longer runs as wardrik.service"
as_user '! systemctl --user is-active --quiet wardrik.service && [ ! -e ~/.config/systemd/user/wardrik.service ]'
if as_user 'wardrik status > /dev/null 2>&1'; then die "the daemon still runs"; fi

say "The service did what it should"
