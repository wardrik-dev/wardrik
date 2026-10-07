#!/usr/bin/env bash
#
# Kills a node with kill -9 and waits for its agent to carry on, from a
# release unpacked as a person installs it, with the store in Postgres or in a
# bucket rather than on the node's disk.
#
#   dev/failover.sh postgres ROOT   two nodes of one cluster, a and b, on one database:
#                                   the node the agent runs on is killed, and the
#                                   other takes the agent
#   dev/failover.sh s3 ROOT         one node on a bucket, killed and its home thrown
#                                   away, as a lost machine is: a node started in a
#                                   new home, from nothing but the same config.yaml,
#                                   takes the agent and the API token made on the first
#
# ROOT is the unpacked release, release/_build/prod/rel/wardrikd after
# MIX_ENV=prod mix release. The agent is spawned rather than read from an agent
# file, so only the store can bring it back, and the MEMORY.md written in its
# tree before the kill is read back after it.
#
# The database is WARDRIK_FAILOVER_DATABASE_URL, and the bucket is reached
# through the WARDRIK_TEST_S3_* variables the suite reads, each by default what
# dev/services.sh starts; the bucket is made where WARDRIK_TEST_S3_BUCKET does
# not name one already there. Pointed at R2, the s3 run is the Hetzner demo's
# without the box. Everything a run writes to the bucket is under a prefix of
# its own.
set -euo pipefail

say() { printf '==> %s\n' "$*"; }
die() { printf 'failover: %s\n' "$*" >&2; exit 1; }

mode=${1:-}
root=${2:-}
case "$mode" in
  postgres | s3) ;;
  *) echo "usage: dev/failover.sh postgres|s3 ROOT" >&2; exit 64 ;;
esac
[ -x "$root/bin/wardrik" ] || die "$root is not an unpacked release; MIX_ENV=prod mix release in release/ makes release/_build/prod/rel/wardrikd"
root=$(cd "$root" && pwd -P)

export WARDRIK_TEST_S3_ENDPOINT=${WARDRIK_TEST_S3_ENDPOINT:-http://127.0.0.1:59000}
export WARDRIK_TEST_S3_REGION=${WARDRIK_TEST_S3_REGION:-us-east-1}
export WARDRIK_TEST_S3_ACCESS_KEY_ID=${WARDRIK_TEST_S3_ACCESS_KEY_ID:-wardrik}
export WARDRIK_TEST_S3_SECRET_ACCESS_KEY=${WARDRIK_TEST_S3_SECRET_ACCESS_KEY:-wardrik-secret}
named_bucket=${WARDRIK_TEST_S3_BUCKET:-}
export WARDRIK_TEST_S3_BUCKET=${WARDRIK_TEST_S3_BUCKET:-wardrik-test}
export WARDRIK_FAILOVER_DATABASE_URL=${WARDRIK_FAILOVER_DATABASE_URL:-postgres://postgres:postgres@127.0.0.1:54329/postgres}

stamp=$(date +%s)
agent="default/survivor-$stamp"
work=$(mktemp -d -t wardrik-failover.XXXXXX)
pids=()

# Whatever is still running when the script ends, however it ends, is killed,
# and the homes go with it, after the nodes' logs where it failed.
cleanup() {
  local status=$? log
  for pid in "${pids[@]}"; do kill -9 "$pid" 2>/dev/null || true; done
  if [ "$status" -ne 0 ]; then
    find "$work" -name '*.log' -print0 2>/dev/null | while IFS= read -r -d '' log; do
      printf '== %s\n' "$log" >&2
      tail -n 40 "$log" >&2
    done
  fi
  rm -rf "$work"
}
trap cleanup EXIT

# The release's own commands, in HOME $1, as a first install runs them.
in_home() {
  local home=$1
  shift
  env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME HOME="$home" "$@"
}

wardrik() { in_home "$1" "$root/bin/wardrik" "${@:2}"; }

# Evaluates Elixir on node $2 of HOME $1, "" for the one node a home runs.
rpc() { in_home "$1" env WARDRIK_NODE="$2" "$root/bin/wardrikd" rpc "$3"; }

start() {
  local home=$1 node=$2
  wardrik "$home" ${node:+--node "$node"} start
  pids+=("$(wardrik "$home" ${node:+--node "$node"} pid)")
}

# The node the agent runs on, as node $2 of HOME $1 sees the cluster, or
# nothing while no node runs it.
running_on() {
  rpc "$1" "$2" "
    case Enum.find(Wardrik.Fleet.list(), &(to_string(&1.id) == \"$agent\")) do
      nil -> :ok
      member -> IO.puts(member.node)
    end
  " 2>/dev/null || true
}

# Writes MEMORY.md in the agent's tree, through node $2 of HOME $1.
remember() {
  rpc "$1" "$2" "
    file = %WardrikWorkspace.File{content: \"$agent remembers\", by: \"$agent\"}
    {:ok, _version} = WardrikWorkspace.Backend.Store.write(\"agents/$agent\", \"MEMORY.md\", file, nil)
  " >/dev/null
}

# Reads MEMORY.md back through node $2 of HOME $1, and fails where it is not
# what was written.
recalled() {
  rpc "$1" "$2" "
    {:ok, %{content: \"$agent remembers\"}, _version} =
      WardrikWorkspace.Backend.Store.read(\"agents/$agent\", \"MEMORY.md\")
  " >/dev/null || die "$agent's MEMORY.md did not survive"
  say "$agent's MEMORY.md survived"
}

# Waits up to two minutes, time enough for a heartbeat to go stale and the
# next discovery to find the work it held, for the agent to run on node $3.
await_agent() {
  local home=$1 node=$2 on=$3 started=$SECONDS
  until [ "$(running_on "$home" "$node")" = "$on" ]; do
    [ $((SECONDS - started)) -lt 120 ] || die "$agent did not come back on $on within two minutes"
    sleep 1
  done
  say "$agent runs on $on, $((SECONDS - started))s later"
}

config() {
  local dir=$1/.config/wardrik
  mkdir -p "$dir"
  cat >"$dir/config.yaml"
}

postgres() {
  local home=$work/home on victim other
  config "$home" <<'EOF'
cluster:
  nodes: [a, b]

storage:
  postgres:
    url: ${WARDRIK_FAILOVER_DATABASE_URL}
EOF

  # At once, so the two migrate the table under one lock.
  say "Starting a and b on Postgres"
  start "$home" a &
  local a=$!
  start "$home" b &
  wait "$a" || die "a did not start"
  wait $! || die "b did not start"
  pids=("$(wardrik "$home" --node a pid)" "$(wardrik "$home" --node b pid)")
  wardrik "$home" status | grep -q "cluster of 2: a, b up" || die "a and b did not make a cluster"

  rpc "$home" a "{:ok, _pid} = Wardrik.Fleet.spawn(Wardrik.AgentID.parse!(\"$agent\"))"
  on=$(running_on "$home" a)
  [ -n "$on" ] || die "$agent did not start"

  case "$on" in
    wardrik_a@*) victim=a other=b ;;
    *) victim=b other=a ;;
  esac

  remember "$home" a
  say "$agent runs on $on; killing it with kill -9"
  kill -9 "$(wardrik "$home" --node "$victim" pid)"
  await_agent "$home" "$other" "wardrik_$other@localhost"
  recalled "$home" "$other"

  rpc "$home" "$other" ":ok = Wardrik.Fleet.forget(Wardrik.AgentID.parse!(\"$agent\"))" >/dev/null
}

s3() {
  local old=$work/old new=$work/new node token
  # Both homes' node, under a name of its own, so a daemon of the user's own,
  # wardrikd@localhost, can go on running beside it.
  local -x RELEASE_NODE=wardrik_failover@localhost
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

  for home in "$old" "$new"; do
    config "$home" <<EOF
storage:
  s3:
    bucket: \${WARDRIK_TEST_S3_BUCKET}
    endpoint: \${WARDRIK_TEST_S3_ENDPOINT}
    region: \${WARDRIK_TEST_S3_REGION}
    prefix: failover-$stamp
    access_key_id: \${WARDRIK_TEST_S3_ACCESS_KEY_ID}
    secret_access_key: \${WARDRIK_TEST_S3_SECRET_ACCESS_KEY}
EOF
  done

  say "Starting a node on the bucket $WARDRIK_TEST_S3_BUCKET, under failover-$stamp"
  start "$old" ""
  rpc "$old" "" "{:ok, _pid} = Wardrik.Fleet.spawn(Wardrik.AgentID.parse!(\"$agent\"))"
  node=$(running_on "$old" "")
  [ -n "$node" ] || die "$agent did not start"
  wardrik "$old" token create failover --all --unlimited >/dev/null
  remember "$old" ""

  say "$agent runs on $node; killing it with kill -9 and throwing its home away"
  kill -9 "$(wardrik "$old" pid)"
  rm -rf "$old"

  say "Starting a node in a new home, on the same bucket"
  start "$new" ""
  await_agent "$new" "" "$node"
  token=$(wardrik "$new" token list)
  grep -q failover <<<"$token" || die "the token made before the kill is not listed: $token"
  say "The token made before the kill is listed"
  recalled "$new" ""

  rpc "$new" "" ":ok = Wardrik.Fleet.forget(Wardrik.AgentID.parse!(\"$agent\"))" >/dev/null
}

"$mode"
