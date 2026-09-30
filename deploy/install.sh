#!/bin/sh
#
# Installs wardrik, the daemon and the command that runs it, from a release.
#
#   curl -fsSL https://github.com/wardrik-dev/wardrik/releases/latest/download/install.sh | sh
#   sh install.sh wardrik-0.1.0-linux-x86_64.tar.gz     a tarball you already have
#
# As a user it installs under ~/.local: the release in ~/.local/lib/wardrik,
# and wardrik in ~/.local/bin. As root, under /opt/wardrik, and wardrik in
# /usr/local/bin. Run again, it puts the new release beside the old one, points
# wardrik at the new one, and keeps the one before it. It writes nothing else:
# the daemon makes its own directories the first time it starts.
#
#   WARDRIK_VERSION        the release to install, such as 0.1.0; the latest by default
#   WARDRIK_INSTALL_DIR    where the releases go
#   WARDRIK_BIN_DIR        where wardrik goes
#   WARDRIK_REPO           the GitHub repository the releases are in, wardrik-dev/wardrik
#   WARDRIK_DOWNLOAD_URL   where the tarball and its SHA256SUMS are, in place of the
#                          release's; file:// works, with WARDRIK_VERSION beside it
#
# A tarball is checked against the SHA256SUMS published with it before anything
# is unpacked, and the release is run once before wardrik points at it. The
# release runs on Linux on x86_64 with glibc 2.35 or later and OpenSSL 3: Ubuntu
# 22.04 or later, or Debian 12 or later. Elsewhere, the Docker image runs.
set -eu

repo=${WARDRIK_REPO:-wardrik-dev/wardrik}
image=ghcr.io/wardrik-dev/wardrik

say() { printf '==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die() { printf 'install: %s\n' "$*" >&2; exit 1; }

needs() {
  command -v "$1" > /dev/null 2>&1 || die "needs $1, which is not installed"
}

# The platform the release must have been built for, or why there is none.
platform() {
  case "$(uname -s)" in
    Linux) ;;
    Darwin) die "there is no macOS build yet; the Docker image runs there: docker run -p 127.0.0.1:4747:4747 -v wardrik:/data $image" ;;
    *) die "there is no build for $(uname -s); the Docker image runs anywhere Docker does: $image" ;;
  esac

  case "$(uname -m)" in
    x86_64 | amd64) ;;
    *) die "there is no build for Linux on $(uname -m) yet, only x86_64; the Docker image runs there: $image" ;;
  esac

  # musl, as Alpine has, answers nothing here.
  libc=$(getconf GNU_LIBC_VERSION 2> /dev/null || true)
  case "$libc" in
    "glibc "*) ;;
    *) die "the release needs glibc, and this Linux has another C library, as Alpine does; the Docker image runs here: $image" ;;
  esac

  version=${libc#glibc }
  major=${version%%.*}
  minor=${version#*.}
  minor=${minor%%.*}
  if [ "$major" -lt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -lt 35 ]; }; then
    die "the release needs glibc 2.35 or later, as Ubuntu 22.04 and Debian 12 have, and this Linux has $version; the Docker image runs here: $image"
  fi

  echo linux-x86_64
}

# The version of the latest release, from where GitHub sends a request for it.
latest() {
  url=$(curl -fsSLI --proto '=https' -o /dev/null -w '%{url_effective}' "https://github.com/$repo/releases/latest" 2> /dev/null) ||
    die "cannot find the latest release of $repo; set WARDRIK_VERSION to the one to install"

  case "$url" in
    */releases/tag/v*) echo "${url##*/releases/tag/v}" ;;
    *) die "$repo has no release yet; set WARDRIK_VERSION, or give a tarball" ;;
  esac
}

download() {
  curl -fsSL --proto '=https,file' --retry 3 -o "$2" "$1" || die "cannot download $1"
}

sha256() {
  if command -v sha256sum > /dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# Whether the tarball $1 is the one SHA256SUMS $2 lists under its name.
verify() {
  name=$(basename "$1")
  expected=$(awk -v name="$name" '$2 == name || $2 == "*" name { print $1; exit }' "$2")
  [ -n "$expected" ] || die "$2 lists no $name"

  actual=$(sha256 "$1")
  [ "$actual" = "$expected" ] || die "$name is not the file SHA256SUMS lists: its SHA-256 is $actual, not $expected"
}

# Runs the release in $1 once, with homes of its own, so a Linux it cannot run
# on is found before wardrik points at it. What it prints is the OpenSSL it
# loaded.
check() {
  homes=$(mktemp -d)
  if ! openssl=$(HOME="$homes" WARDRIK_CONFIG_DIR="$homes/config" WARDRIK_DATA_HOME="$homes/data" \
    WARDRIK_STATE_DIR="$homes/state" WARDRIK_NODE='' WARDRIK_DIST_INTERFACE='' RELEASE_NODE='' \
    RELEASE_COOKIE=installing "$1/bin/wardrikd" eval 'IO.puts(elem(hd(:crypto.info_lib()), 2))' 2>&1); then
    rm -rf "$homes"
    printf '%s\n' "$openssl" | tail -n 5 >&2
    die "the release does not run on this machine; the Docker image does: $image"
  fi
  rm -rf "$homes"
  printf '%s\n' "$openssl" | tail -n 1
}

# Whether a node runs from the release in $1.
in_use() {
  command -v pgrep > /dev/null 2>&1 || return 0
  pgrep -f "$1/erts-[^/]*/bin/beam" > /dev/null 2>&1
}

main() {
  umask 022
  needs tar
  command -v sha256sum > /dev/null 2>&1 || needs shasum

  if [ "$(id -u)" = 0 ]; then
    install_dir=${WARDRIK_INSTALL_DIR:-/opt/wardrik}
    bin_dir=${WARDRIK_BIN_DIR:-/usr/local/bin}
  else
    install_dir=${WARDRIK_INSTALL_DIR:-$HOME/.local/lib/wardrik}
    bin_dir=${WARDRIK_BIN_DIR:-$HOME/.local/bin}
  fi

  target=$(platform)
  work=$(mktemp -d)
  staged=""
  trap 'rm -rf "$work" ${staged:+"$staged"}' EXIT

  if [ $# -gt 0 ]; then
    [ $# -eq 1 ] || die "give one tarball, or none to download the latest release"
    [ -f "$1" ] || die "there is no tarball at $1"
    tarball=$1
    name=$(basename "$tarball")
    case "$name" in
      "wardrik-"*"-$target.tar.gz") ;;
      *) die "$name is not a release for $target; its name is wardrik-VERSION-$target.tar.gz" ;;
    esac
    version=${name#wardrik-}
    version=${version%"-$target.tar.gz"}
    sums="$(dirname "$tarball")/SHA256SUMS"
    if [ -f "$sums" ]; then
      verify "$tarball" "$sums"
    else
      say "There is no SHA256SUMS beside $name, so it is installed unchecked"
    fi
  else
    needs curl
    if [ -n "${WARDRIK_VERSION:-}" ]; then
      version=${WARDRIK_VERSION#v}
    elif [ -n "${WARDRIK_DOWNLOAD_URL:-}" ]; then
      die "WARDRIK_DOWNLOAD_URL needs WARDRIK_VERSION beside it"
    else
      version=$(latest)
    fi
    name="wardrik-$version-$target.tar.gz"
    base=${WARDRIK_DOWNLOAD_URL:-https://github.com/$repo/releases/download/v$version}
    base=${base%/}

    say "Downloading wardrik $version"
    tarball="$work/$name"
    download "$base/$name" "$tarball"
    download "$base/SHA256SUMS" "$work/SHA256SUMS"
    verify "$tarball" "$work/SHA256SUMS"
  fi

  release="$install_dir/$version"
  mkdir -p "$install_dir" "$bin_dir"
  previous=$(readlink "$install_dir/current" 2> /dev/null || true)

  if [ -x "$release/bin/wardrik" ]; then
    say "wardrik $version is already in $release"
  else
    say "Unpacking it into $release"
    staged="$install_dir/.$version.$$"
    mkdir "$staged"
    tar -xzf "$tarball" -C "$staged"
    openssl=$(check "$staged")
    note "it runs here, with $openssl"
    mv "$staged" "$release"
    staged=""
  fi

  if [ -e "$bin_dir/wardrik" ] && [ ! -L "$bin_dir/wardrik" ]; then
    die "$bin_dir/wardrik is a file this script did not make; move it, or set WARDRIK_BIN_DIR"
  fi

  ln -sfn "$version" "$install_dir/current"
  ln -sf "$install_dir/current/bin/wardrik" "$bin_dir/wardrik"

  # rik is wardrik too, unless something else here is already called rik.
  ours=$install_dir/current/bin/wardrik
  found=$(command -v rik 2> /dev/null || true)
  if { [ ! -e "$bin_dir/rik" ] || [ "$(readlink "$bin_dir/rik")" = "$ours" ]; } &&
    { [ -z "$found" ] || [ "$found" = "$bin_dir/rik" ]; }; then
    ln -sf "$ours" "$bin_dir/rik"
    rik="rik is wardrik too"
  else
    rik="There is a rik here already, ${found:-$bin_dir/rik}, so rik is left to it"
  fi

  # The release before this one is kept, to go back to; any older one goes,
  # unless a node still runs from it.
  for dir in "$install_dir"/*/; do
    dir=${dir%/}
    old=$(basename "$dir")
    case "$old" in "$version" | "$previous" | current | "*") continue ;; esac
    [ -x "$dir/bin/wardrik" ] || continue
    in_use "$dir" || rm -rf "$dir"
  done

  printf '\n'
  say "wardrik $version is installed, as $bin_dir/wardrik"
  note "$rik."

  if [ -n "$previous" ] && [ "$previous" != "$version" ] && "$bin_dir/wardrik" status > /dev/null 2>&1; then
    note "The daemon runs $previous until it is started again: wardrik stop, then wardrik start."
  fi

  case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *)
      note "$bin_dir is not on your PATH. Add it in your shell's profile:"
      note ""
      note "  export PATH=\"$bin_dir:\$PATH\""
      ;;
  esac

  if [ "$(id -u)" = 0 ]; then
    note "The daemon keeps its store and keys in the home of whoever runs it, so run it as a user of its own rather than root."
  fi

  cat << EOF

    wardrik start                      the daemon, in the background
    wardrik token create dev --all --unlimited
                                       a token for the HTTP API, on 127.0.0.1:4747
    wardrik doctor                     whether config.yaml reads, and the store answers

    Agents are files in ~/.config/wardrik/agents; see the README.
EOF
}

main "$@"
