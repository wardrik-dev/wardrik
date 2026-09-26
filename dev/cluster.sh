#!/usr/bin/env bash
#
# Three connected Wardrik nodes, for driving the fleet by hand: two agent nodes
# and a terminal client attached to both. Run from inside tmux and it takes a
# window in the session already open; run it outside and it makes one.
#
#   dev/cluster.sh
#
# Then, in the client:
#
#   /spawn researcher      start an agent; watch it appear in the panel
#   /spawn analyst --bg    start another without leaving this one
#   /connect researcher    attach this client to it, wherever it landed
#   /move researcher       pick a node to restart it on
#   /fleet                 move into the fleet panel
#   /stop acme/            interrupt everything under a prefix
#
# And from either iex pane, to see the same fleet from another node:
#
#   Wardrik.Fleet.list()
#   Wardrik.Fleet.spawn("analyst", org: "acme", user: "jon")
#   Wardrik.Fleet.kill("acme/")
#
# Killing a node, from outside the session, leaves its agents to be restarted
# on another with the state they had, which takes about twenty seconds:
#
#   kill -9 $(pgrep -f "sname wardrik_a")
set -euo pipefail

host=$(hostname -s)
cookie=${WARDRIK_COOKIE:-wardrik}
name=${WARDRIK_TMUX:-wardrik-cluster}

# Two of the three nodes are a quorum, which is what lets one be killed.
run="env WARDRIK_CLUSTER_SIZE=3"

# Inside tmux this takes a window in the session already open; outside it, a
# session of its own to attach to.
if [ -n "${TMUX:-}" ]; then
  window=$(tmux new-window -P -F '#{session_id}:#{window_index}' -n "$name")
  attach=""
else
  tmux kill-session -t "$name" 2>/dev/null || true
  tmux new-session -d -s "$name"
  window="$name"
  attach=yes
fi

# The two agent nodes wait for each other at the VM's own boot, through the
# kernel, because the store counts its quorum while the application starts and
# a node that connects afterwards has already missed it. Two of three is a
# quorum, so the client can join whenever it is ready.
peers() {
  echo "-kernel sync_nodes_optional ['$1@$host'] sync_nodes_timeout 60000"
}

# Pane ids rather than indexes, which depend on the user's base-index.
pane_a=$(tmux list-panes -t "$window" -F '#{pane_id}' | head -1)
pane_b=$(tmux split-window -h -P -F '#{pane_id}' -t "$pane_a")
pane_c=$(tmux split-window -v -P -F '#{pane_id}' -t "$pane_b")

tmux send-keys -t "$pane_a" \
  "$run iex --sname wardrik_a --cookie $cookie --erl \"$(peers wardrik_b)\" -S mix" C-m
tmux send-keys -t "$pane_b" \
  "$run iex --sname wardrik_b --cookie $cookie --erl \"$(peers wardrik_a)\" -S mix" C-m
tmux send-keys -t "$pane_c" \
  "$run mix wardrik --sname wardrik_c --cookie $cookie --connect wardrik_a@$host --connect wardrik_b@$host" C-m

tmux select-layout -t "$window" main-vertical
tmux select-pane -t "$pane_c"

if [ -n "$attach" ]; then
  tmux attach -t "$name"
else
  tmux select-window -t "$window"
fi
