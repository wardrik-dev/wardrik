#!/usr/bin/env bash
#
# Three connected Tars nodes in one tmux session, for driving the fleet by
# hand: two agent nodes and a terminal client attached to both.
#
#   dev/cluster.sh
#
# Then, in the client:
#
#   /spawn researcher      start an agent; watch it appear in the panel
#   /connect researcher    attach this client to it, wherever it landed
#   /fleet                 list every agent in the cluster
#   /kill acme/            interrupt everything under a prefix
#
# And from either iex pane, to see the same fleet from another node:
#
#   Tars.Fleet.list()
#   Tars.Fleet.spawn("analyst", org: "acme", user: "jon")
#   Tars.Fleet.kill("acme/")
#
# Killing a node, from outside the session, leaves its agents to be restarted
# on another with the state they had, which takes about twenty seconds:
#
#   kill -9 $(pgrep -f "sname tars_a")
set -euo pipefail

host=$(hostname -s)
cookie=${TARS_COOKIE:-tars}
session=${TARS_TMUX:-tars-cluster}

# Two of the three nodes are a quorum, which is what lets one be killed.
run="env TARS_CLUSTER_SIZE=3"

tmux kill-session -t "$session" 2>/dev/null || true
tmux new-session -d -s "$session"

# The two agent nodes wait for each other at the VM's own boot, through the
# kernel, because the store counts its quorum while the application starts and
# a node that connects afterwards has already missed it. Two of three is a
# quorum, so the client can join whenever it is ready.
peers() {
  echo "-kernel sync_nodes_optional ['$1@$host'] sync_nodes_timeout 60000"
}

tmux send-keys -t "$session" \
  "$run iex --sname tars_a --cookie $cookie --erl \"$(peers tars_b)\" -S mix" C-m

tmux split-window -h -t "$session"
tmux send-keys -t "$session" \
  "$run iex --sname tars_b --cookie $cookie --erl \"$(peers tars_a)\" -S mix" C-m

tmux split-window -v -t "$session"
tmux send-keys -t "$session" \
  "$run mix tars --sname tars_c --cookie $cookie --connect tars_a@$host --connect tars_b@$host" C-m

tmux select-layout -t "$session" main-vertical
tmux attach -t "$session"
