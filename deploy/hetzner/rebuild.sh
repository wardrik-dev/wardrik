#!/usr/bin/env bash
#
# The Hetzner demo on a bucket, end to end: makes the box with bootstrap.sh,
# keeping everything in WARDRIK_BOX_BUCKET, spawns an agent on it, deletes the
# box with teardown.sh, makes a new one over the same bucket, and waits for
# the agent there. Nothing of the first box carries over but what the bucket
# holds.
#
#   WARDRIK_BOX_BUCKET=wardrik \
#   WARDRIK_BOX_BUCKET_ENDPOINT=https://<account>.r2.cloudflarestorage.com \
#     deploy/hetzner/rebuild.sh
#
# It takes what bootstrap.sh takes, and leaves the new box running;
# teardown.sh deletes it.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd -P)
box=${WARDRIK_BOX:-wardrik-demo}
agent="_/_/survivor-$(date +%s)"
ssh_opts=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o LogLevel=ERROR)

say() { printf '==> %s\n' "$*"; }
die() { printf 'rebuild: %s\n' "$*" >&2; exit 1; }

[ -n "${WARDRIK_BOX_BUCKET:-}" ] || die "set WARDRIK_BOX_BUCKET to the bucket the box keeps everything in"

# Evaluates Elixir on node a of whichever box is up.
on_box() {
  ssh "${ssh_opts[@]}" "wardrik@$(hcloud server ip "$box")" \
    "WARDRIK_NODE=a wardrik/bin/wardrikd rpc $(printf %q "$1")"
}

# The node the agent runs on, or nothing while none runs it.
running_on() {
  on_box "
    case Enum.find(Wardrik.Fleet.list(), &(&1.key == \"$agent\")) do
      nil -> :ok
      member -> IO.puts(member.node)
    end
  " 2>/dev/null || true
}

"$here/bootstrap.sh"
on_box "{:ok, _pid} = Wardrik.Fleet.spawn(\"$agent\")"
[ -n "$(running_on)" ] || die "$agent did not start on the box"
say "$agent runs on $(running_on); deleting the box"

"$here/teardown.sh" -y
"$here/bootstrap.sh"

started=$SECONDS
until [ -n "$(running_on)" ]; do
  [ $((SECONDS - started)) -lt 180 ] || die "$agent did not come back on the new box within three minutes"
  sleep 5
done

say "$agent runs on $(running_on) on the new box, $((SECONDS - started))s after it came up"
on_box ":ok = Wardrik.Fleet.forget(\"$agent\")" >/dev/null
