---
title: Host your tools
description: "Run a tool worker inside your app or on its own, on another machine or in a container, and keep its tools up through deploys."
sidebar:
  order: 3.3
---

A worker is any process that calls `wardrik.work()`. It opens no port: it needs only a way out to
the daemon.

## Inside your app

Start it beside your HTTP server, so its tools use your app's code and database:

```ts title="server.ts"
const server = app.listen(3000);

const wardrik = new Wardrik({ name: "shop" });
addTools(wardrik); // your wardrik.tool(...) calls

const stop = new AbortController();
process.on("SIGTERM", () => {
  stop.abort();
  server.close();
});

await wardrik.work({ signal: stop.signal });
```

Each copy of your app connects with the same token. Each call goes to one of them.

## On its own

```dockerfile title="Dockerfile"
FROM node:24-slim
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY statuspage.ts ./
USER node
CMD ["node", "statuspage.ts"]
```

```sh
docker run -d --restart unless-stopped --env-file statuspage.env statuspage
```

- `statuspage.env` holds `WARDRIK_URL`, `WARDRIK_TOKEN` and the tool's own keys.
- On the daemon's machine, add `--network host`, so `127.0.0.1:4747` is the daemon.
- In Kubernetes it's a Deployment, with no Service: nothing connects to it.

## A daemon on another machine

Pass `/v1/workers` through the Caddy that gives the daemon its
[public address](/run/public-address/):

```text title="/etc/caddy/Caddyfile"
agents.acme.example {
	@daemon path /oauth/* /v1/hooks/* /v1/channels/* /v1/workers
	handle @daemon {
		reverse_proxy 127.0.0.1:4747
	}
	handle {
		respond 404
	}
}
```

```sh
WARDRIK_URL=https://agents.acme.example
```

## Deploys and restarts

- While no worker offers a tool, agents don't see it. Run two copies, and restart one at a time.
- The SDK reconnects after a drop, waiting up to 30 seconds.
- A refused token makes `work` throw, so the process ends and its supervisor shows it.
- Revoke the token to cut a worker off. Its connection closes within 15 seconds.

### Calls in doubt

A call is in doubt when the worker went away during it, or answered late.

- If every worker marks the tool `idempotent` or `readOnly`, it runs again under the same key.
- Otherwise it waits on a person, who checks and decides.

## Details

- Workers acting as the same user share a tool's calls.
- If two users' workers offer a tool of the same name, the agent gets the one that connected
  first.
- `work` pings every 15 seconds. `keepalive` changes it, in milliseconds.
- A worker's answers are [content from outside](/concepts/outside-content/), unless `config.yaml`
  sets `http: {trusted_workers: true}`.
