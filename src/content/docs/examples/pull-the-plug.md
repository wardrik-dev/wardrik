---
title: Pull the plug, then press stop
description: Kill -9 an agent's node mid-task and it finishes without doing a step twice. Stop it, and it stays stopped.
sidebar:
  order: 8
---

An agent sets up two new hires, each step exactly once. You `kill -9` its node halfway; it finishes
on another node with no step done twice. Then you stop it, kill its node again, and it stays
stopped.

## What it takes

- the `wardrik` command, [installed](/getting-started/install/), and a model provider's key;
- Node 22.18 or later, and a copy of the repository for the SDK's `examples/onboarding.ts`.

## Try it

### Three nodes

Run the demo apart from any daemon you have:

```sh
export XDG_CONFIG_HOME=~/plug/config XDG_DATA_HOME=~/plug/data XDG_STATE_HOME=~/plug/state
mkdir -p ~/plug/config/wardrik
cat > ~/plug/config/wardrik/config.yaml <<'EOF'
cluster:
  nodes: [a, b, c]
http:
  port: 4848
  trusted_workers: true
EOF
```

Start the nodes and make a token:

```sh
export ANTHROPIC_API_KEY=sk-ant-...
wardrik start --node a
wardrik start --node b
wardrik start --node c
wardrik status                     # cluster of 3: a, b, c up
wardrik token create it --scope default/ --role reader,messenger,definer
export TOKEN=wardrik_...
```

### The new hires

In another terminal:

```sh
git clone https://github.com/wardrik-dev/wardrik
cd wardrik/sdks/typescript
npm ci
WARDRIK_URL=http://127.0.0.1:4848 WARDRIK_TOKEN=wardrik_... node examples/onboarding.ts
```

The script plays IT, offering three `idempotent` tools, and asks the agent to set up Ana and Ben. It
says which node the agent runs on:

```
[agent] runs on wardrik_c@localhost
[it] google account for Ana...
[it] google account for Ana: done
[it] github account for Ana...
```

### Pull the plug

While a step runs, kill the node the script named, here `c`:

```sh
kill -9 "$(wardrik pid --node c)"
```

```
[it] laptop for Ana...
[it] laptop for Ana: stopped before it happened

[agent] carries on on wardrik_b@localhost
[it] laptop for Ana...
[it] laptop for Ana: done
[it] welcome email to Ana...
...
[agent] completed
[it] 10 changes made, for 11 calls:
  google account for Ana
  github account for Ana
  slack account for Ana
  laptop for Ana
  ...
```

IT dropped the call when its caller died. The agent resumed on `b` and retried under the same
idempotency key. One laptop each. Start `c` again:

```sh
wardrik start --node c
```

### Press stop

Remove the agent, run the script again, and stop it part way:

```sh
curl -X DELETE -H "authorization: Bearer $TOKEN" http://127.0.0.1:4848/v1/agents/default/onboarding
```

```sh
curl -X POST -H "authorization: Bearer $TOKEN" \
  http://127.0.0.1:4848/v1/agents/default/onboarding/cancel
```

```
[it] github account for Ana...
[it] github account for Ana: done
[agent] cancelled
[it] 2 changes made, for 2 calls:
  google account for Ana
  github account for Ana
[it] still answering calls, until Ctrl-C
```

Now kill its node:

```sh
wardrik ls onboarding               # which node
kill -9 "$(wardrik pid --node b)"
wardrik ls onboarding               # idle, on another node
```

It restarts on another node, idle. No call arrives: the stop is in the store.

## What it shows

- **Durable agents.** Each round is written down before it runs, so another node carries on from
  it. See [Durable runs](/concepts/durable-runs/).
- **The ledger.** A finished call is never run twice. See
  [The ledger](/concepts/durable-runs/#the-ledger).
- **Idempotency keys.** A retry carries the same key. See
  [Running a call twice](/build/write-tools/#running-a-call-twice).
- **Quorum.** With the store on the nodes, two of three carry on. See [Run a cluster](/run/cluster/).

## Details

### What a stop does

It ends the turn at its next step and drops waiting messages. A running call gets two seconds, then
is dropped; a tool worker sees its `signal` abort. A turn waiting on a person is abandoned.
`agent.cancel()` and `/stop` in the [terminal client](/build/tui/) do the same.

### Keeping it stopped

Remove its [triggers](/build/triggers/#changing-and-removing-triggers), revoke the
[tokens](/run/tokens/) that message it or serve its tools, deny tools in its
[policy](/concepts/policy/), set a [budget](/concepts/budgets/) with `on_exhausted: deny`, or
`/shutdown NAME` it in the terminal client.

### How it resumes

A finished call is answered from the ledger, marked `"replayed": true`. One that began but never
finished runs again only if the tool is `idempotent`; otherwise it waits for a person. Had the
laptop order gone through, IT would have answered the retry with the first result.

### Taking it further

- Kill the node while the model answers: its earlier steps replay from the ledger.
- Drop `idempotent: true` and pull the plug: the interrupted call waits for a person.
- Run three machines on Postgres, and unplug one.

### Cleaning up

Stop the script, stop the nodes, remove `~/plug`, and open a new shell:

```sh
wardrik stop --node a && wardrik stop --node b && wardrik stop --node c
rm -rf ~/plug
```
