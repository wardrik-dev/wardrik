#!/usr/bin/env bash
#
# Builds Wardrik's Hex package from this checkout, as mix hex.build has it,
# without the TUI, and compiles it alone without its optional dependencies,
# warnings and all. Then makes new applications that depend on that package,
# and checks Wardrik inside each: a Phoenix app that keeps it in its own Repo
# and starts it in its own tree, and a bare Mix app that keeps it in an S3
# bucket. Neither depends on :ekv, and the bare one not on :ecto_sql either,
# so each shows Wardrik compiling and running without what it leaves out.
#
#   dev/services.sh && dev/hosts.sh     both
#   dev/hosts.sh phoenix                one of them: phoenix or bare
#
# In each, dev/hosts/check.exs runs against the application as it runs, in
# its dev environment: the store passes Wardrik.Store.Conformance, and an
# agent spawned in the fleet is kept where the application keeps Wardrik.
#
# The apps are made under WARDRIK_HOSTS_DIR, a new temporary directory by
# default, and left there to look at. The Phoenix app's database is
# WARDRIK_HOST_DATABASE_URL, and the bucket is reached through the
# WARDRIK_TEST_S3_* variables the suite reads, each defaulting to what
# dev/services.sh starts. The bucket is made where WARDRIK_TEST_S3_BUCKET does
# not name one already there.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd -P)
dir=${WARDRIK_HOSTS_DIR:-$(mktemp -d -t wardrik-hosts.XXXXXX)}
database_url=${WARDRIK_HOST_DATABASE_URL:-postgres://postgres:postgres@127.0.0.1:54329/wardrik_host}

export WARDRIK_TEST_S3_ENDPOINT=${WARDRIK_TEST_S3_ENDPOINT:-http://127.0.0.1:59000}
export WARDRIK_TEST_S3_REGION=${WARDRIK_TEST_S3_REGION:-us-east-1}
export WARDRIK_TEST_S3_ACCESS_KEY_ID=${WARDRIK_TEST_S3_ACCESS_KEY_ID:-wardrik}
export WARDRIK_TEST_S3_SECRET_ACCESS_KEY=${WARDRIK_TEST_S3_SECRET_ACCESS_KEY:-wardrik-secret}
named_bucket=${WARDRIK_TEST_S3_BUCKET:-}
export WARDRIK_TEST_S3_BUCKET=${WARDRIK_TEST_S3_BUCKET:-wardrik-test}

# phx_new goes in an archives directory of this run's own, not the user's.
export MIX_ARCHIVES="$dir/archives"
export MIX_ENV=dev
export WARDRIK_PACKAGE=$dir/wardrik

say() { printf '==> %s\n' "$*"; }
die() { printf 'hosts: %s\n' "$*" >&2; exit 1; }

# Runs a command, showing what it wrote only where it fails: compiling the
# dependencies writes pages of their warnings.
quietly() {
  local log
  log=$(mktemp)
  "$@" >"$log" 2>&1 || { cat "$log" >&2; rm -f "$log"; die "$* failed"; }
  rm -f "$log"
}

package() {
  say "Building Wardrik's Hex package, and compiling it without its optional dependencies"
  # Hex goes in this run's archives, as phx_new does.
  quietly mix local.hex --force
  rm -rf "$WARDRIK_PACKAGE"
  (cd "$repo" && quietly mix hex.build --unpack --output "$WARDRIK_PACKAGE")
  cd "$WARDRIK_PACKAGE"
  quietly mix deps.get
  quietly env MIX_ENV=prod mix compile --no-optional-deps --warnings-as-errors
  cd "$repo"
}

check() {
  say "Checking Wardrik in $1"
  cd "$dir/$1"
  quietly mix deps.get
  quietly mix compile
  mix run "$repo/dev/hosts/check.exs"
  cd "$repo"
}

phoenix() {
  say "Making a Phoenix app, host, that keeps Wardrik in its Repo"
  mix archive.install hex phx_new --force >/dev/null
  rm -rf "$dir/host"
  (cd "$dir" && mix phx.new host --no-assets --no-dashboard --no-gettext --no-html \
    --no-live --no-mailer --no-install >/dev/null)

  cd "$dir/host"
  perl -0pi -e 's/(\{:phoenix, )/{:wardrik, path: "$ENV{WARDRIK_PACKAGE}"},\n      $1/' mix.exs
  perl -0pi -e 's/(      Host\.Repo,\n)/$1      Wardrik,\n/' lib/host/application.ex
  grep -q '^      Wardrik,$' lib/host/application.ex || die "host's children have no Host.Repo to start Wardrik after"

  perl -0pi -e 's/(# Import environment specific config)/# Wardrik, kept in the Repo and started after it.\nconfig :wardrik, start: :host\nconfig :wardrik, Wardrik.Store, adapter: WardrikEcto.Store, repo: Host.Repo\n\n$1/' config/config.exs
  printf '\nconfig :host, Host.Repo, url: "%s"\nconfig :logger, level: :warning\n' \
    "$database_url" >>config/dev.exs

  cat >priv/repo/migrations/20260929000000_add_wardrik.exs <<'EOF'
defmodule Host.Repo.Migrations.AddWardrik do
  use Ecto.Migration

  def up, do: WardrikEcto.Migration.up(version: 1)
  def down, do: WardrikEcto.Migration.down(version: 1)
end
EOF

  quietly mix deps.get
  quietly mix ecto.drop
  quietly mix ecto.create
  quietly mix ecto.migrate
  cd "$repo"

  WARDRIK_HOST_STORE=WardrikEcto.Store WARDRIK_HOST_WITHOUT=EKV WARDRIK_HOST_REPO=Host.Repo \
    check host
}

bare() {
  say "Making a bare Mix app, bare, that keeps Wardrik in the bucket $WARDRIK_TEST_S3_BUCKET"
  if [ -z "$named_bucket" ]; then
    code=$(curl -sS -o /dev/null -w '%{http_code}' -X PUT \
      --aws-sigv4 "aws:amz:$WARDRIK_TEST_S3_REGION:s3" \
      --user "$WARDRIK_TEST_S3_ACCESS_KEY_ID:$WARDRIK_TEST_S3_SECRET_ACCESS_KEY" \
      "$WARDRIK_TEST_S3_ENDPOINT/$WARDRIK_TEST_S3_BUCKET")
    case "$code" in
      200 | 409) ;;
      *) die "$WARDRIK_TEST_S3_ENDPOINT answered $code to making $WARDRIK_TEST_S3_BUCKET; is dev/services.sh up?" ;;
    esac
  fi

  rm -rf "$dir/bare"
  (cd "$dir" && mix new bare >/dev/null)

  cd "$dir/bare"
  perl -0pi -e 's/# \{:dep_from_hexpm, "~> 0.3.0"\},/{:wardrik, path: "$ENV{WARDRIK_PACKAGE}"},/' mix.exs
  mkdir -p config
  cat >config/config.exs <<'EOF'
import Config

config :logger, level: :warning
EOF
  cat >config/runtime.exs <<'EOF'
import Config

# Wardrik, kept in a bucket under a prefix of this run's own.
config :wardrik, Wardrik.Store,
  adapter: WardrikS3.Store,
  bucket: System.fetch_env!("WARDRIK_TEST_S3_BUCKET"),
  endpoint: System.fetch_env!("WARDRIK_TEST_S3_ENDPOINT"),
  region: System.fetch_env!("WARDRIK_TEST_S3_REGION"),
  access_key_id: System.fetch_env!("WARDRIK_TEST_S3_ACCESS_KEY_ID"),
  secret_access_key: System.fetch_env!("WARDRIK_TEST_S3_SECRET_ACCESS_KEY"),
  prefix: "hosts-#{System.system_time(:millisecond)}"
EOF

  cd "$repo"

  WARDRIK_HOST_STORE=WardrikS3.Store WARDRIK_HOST_WITHOUT=EKV,Ecto,Postgrex check bare
}

package

case "${1:-all}" in
  phoenix) phoenix ;;
  bare) bare ;;
  all) phoenix && bare ;;
  *) echo "usage: dev/hosts.sh [phoenix|bare]" >&2; exit 64 ;;
esac

say "Checked; the apps are in $dir"
