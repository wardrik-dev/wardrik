#!/usr/bin/env bash
#
# Three connected Tars nodes in one tmux session, for driving the fleet by
# hand: two agent nodes and a terminal client attached to both.
#
#   dev/cluster.sh
#
# Then, in the client:
#
#   /spawn alpha           start an agent; watch it appear in the panel
#   /connect alpha         attach this client to it, wherever it landed
#   /fleet                 list every agent in the cluster
#   /kill _/               interrupt everything under a prefix
#
# And from either iex pane, to see it from the other side:
#
#   Tars.Fleet.list()
#   Tars.Fleet.spawn("beta")
#   Tars.Fleet.kill("_/")
#
# Killing a node (Ctrl-C twice in its pane) leaves its agents to be restarted
# elsewhere with the state they had.
set -euo pipefail

host=$(hostname -s)
cookie=${TARS_COOKIE:-tars}
session=${TARS_TMUX:-tars-cluster}

export TARS_CLUSTER_SIZE=3

tmux kill-session -t "$session" 2>/dev/null || true
tmux new-session -d -s "$session"
tmux set-environment -t "$session" TARS_CLUSTER_SIZE 3

# Peers are named at the VM's own boot, through the kernel, because the fleet's
# store counts its quorum while the application starts. A node that connects
# afterwards has already missed it.
peers() {
  local list=""
  for name in "$@"; do
    list="$list, '$name@$host'"
  done
  echo "-kernel sync_nodes_optional [${list#, }] sync_nodes_timeout 20000"
}

tmux send-keys -t "$session" \
  "iex --sname tars_a --cookie $cookie --erl \"$(peers tars_b tars_c)\" -S mix" C-m

tmux split-window -h -t "$session"
tmux send-keys -t "$session" \
  "iex --sname tars_b --cookie $cookie --erl \"$(peers tars_a tars_c)\" -S mix" C-m

tmux split-window -v -t "$session"
tmux send-keys -t "$session" \
  "mix tars --sname tars_c --cookie $cookie --connect tars_a@$host --connect tars_b@$host" C-m

tmux select-layout -t "$session" main-vertical
tmux attach -t "$session"
