---
title: Host your tools
description: "Run a tool worker inside your app or on its own, on the daemon's machine, another machine or a container, and keep its tools up through deploys."
sidebar:
  order: 3.3
---

A worker is any process that calls `wardrik.work()`. It holds one connection to the daemon, and
answers calls over it. Host it wherever your code runs: it opens no port, so it needs only a way out
to the daemon.

| Where | When |
| --- | --- |
| [Inside your app](#inside-your-app) | the tools use your app's code, database and settings |
| [On its own](#on-its-own) | a few tools around an outside API, like `post_status` |

## Inside your app

Start the worker beside your HTTP server, from the same process. Its tools call your services
directly, with your database pool and config:

```ts title="server.ts"
import express from "express";
import { Wardrik } from "@wardrik/sdk";
import { routes } from "./routes.ts";
import { addTools } from "./tools.ts"; // your wardrik.tool(...) calls

const app = express().use(routes);
const server = app.listen(3000);

const wardrik = new Wardrik({ name: "shop" });
addTools(wardrik);

const stop = new AbortController();
process.on("SIGTERM", () => {
  stop.abort();
  server.close();
});

await wardrik.work({ signal: stop.signal });
```

Each copy of your app connects, and each call goes to one of them. They share one token.

## On its own

A worker of its own is a small Node app, run like any service. [Your first
tool](/build/first-tool/#7-run-it-as-a-service) runs one with systemd on the daemon's machine. In a
container:

```dockerfile title="Dockerfile"
FROM node:24-slim
WORKDIR /app
COPY package.json package-lock.json wardrik-sdk-0.0.0.tgz ./
RUN npm ci --omit=dev
COPY statuspage.ts ./
USER node
CMD ["node", "statuspage.ts"]
```

```sh
docker build -t statuspage .
docker run -d --restart unless-stopped --env-file statuspage.env statuspage
```

`statuspage.env` holds `WARDRIK_URL`, `WARDRIK_TOKEN` and the tool's own keys. On the daemon's own
machine, add `--network host`, so `127.0.0.1:4747` is the daemon's and not the container's.

In Kubernetes it's a Deployment, with no Service or Ingress, since nothing connects to it:

```yaml title="statuspage.yaml"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: statuspage
spec:
  replicas: 2
  selector:
    matchLabels: { app: statuspage }
  template:
    metadata:
      labels: { app: statuspage }
    spec:
      containers:
        - name: statuspage
          image: registry.acme.example/statuspage:1
          envFrom:
            - secretRef: { name: statuspage }
```

## Reach a daemon on another machine

The daemon's HTTP API listens on loopback, `127.0.0.1:4747`. For a worker elsewhere, pass
`/v1/workers` through the same Caddy that gives the daemon its
[public address](/run/public-address/):

```text title="/etc/caddy/Caddyfile"
agents.acme.example {
	handle /oauth/* {
		reverse_proxy 127.0.0.1:4599
	}

	handle /v1/hooks/* {
		reverse_proxy 127.0.0.1:4747
	}

	handle /v1/workers {
		reverse_proxy 127.0.0.1:4747
	}

	handle {
		respond 404
	}
}
```

Then point the worker at it:

```sh
WARDRIK_URL=https://agents.acme.example
```

The SDK opens a WebSocket to `wss://agents.acme.example/v1/workers`, and Caddy passes it on. Only
that path is open, and it takes only tokens that can `serve`.

## Tokens and keys

- Make one token per app, with `--can serve`, scoped to the agents that may use its tools. See
  [Tokens](/run/tokens/).
- The tools' own keys, such as Statuspage's, stay in the app's environment. The daemon never sees
  them.
- Revoke the token to cut the app off at once: its connection closes.

| Scope | Agents that get the tools |
| --- | --- |
| `acme/` | acme's own agents, none that work for a user |
| `'acme/*'` | acme's and its users' agents, as per-user agents need |
| `default/` | agents whose file names no `org`, unless `config.yaml` names another |

## Deploys and restarts

While no worker offers a tool, agents don't see it. Run two copies, and restart them one at a time,
so one is always connected.

The SDK reconnects after a drop, waiting longer each time, up to 30 seconds. A refused token makes
`work` throw instead, so the process ends and its supervisor shows it.

### Calls in doubt

A call is in doubt when the daemon can't tell whether it finished: the worker went away during it,
or answered late, or the agent's node was lost.

- Where every worker offering the tool marks it `idempotent` or `readOnly`, it runs again under the
  same key, on a worker connected then.
- Otherwise, or where it's in doubt again, it waits on a person, who can check and decide.

The model is never told it failed, so it never retries under a new key. See
[Running a call twice](/build/write-tools/#running-a-call-twice).

## Details

### Several workers

- Workers under one token offering a tool of the same name share its calls; each call goes to one.
- A tool is bound to the token that offers it. Where a second token's workers offer the same name to
  the same agent, the first to connect keeps it, the second is refused, and the daemon logs it.
- A call's events name the token that served it.
- `*` in an agent file includes `workers/*`. A file can't list one worker tool; a policy decides.

### The connection

- `new Wardrik()` reads `WARDRIK_URL`, `http://127.0.0.1:4747` unless set, and `WARDRIK_TOKEN`.
- `work` opens a WebSocket to `/v1/workers` and answers calls as an MCP server.
- A refused token throws a `WardrikError`. Revoking the token closes the connection.

### On a private network

`http.ip` in `config.yaml` makes the HTTP API listen on another address, such as the machine's
address on a private network. It's plain HTTP, so use it only on a network you trust. See
[config.yaml](/reference/config/#http).

### Outside content

A worker's answers are content from outside unless `config.yaml` says otherwise:

```yaml
http:
  trusted_workers: true
```

Without it, a turn that called a worker waits on a person before a gated call runs. See
[Content from outside](/concepts/outside-content/).
