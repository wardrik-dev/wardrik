---
title: Host your tools
description: "Run a tool worker inside your app or on its own, on another machine or in a container, and keep its tools up through deploys."
sidebar:
  order: 3.3
---

A worker is any process that calls `wardrik.work()`. It opens no port. It needs only an outbound
connection to the daemon.

## Inside your app

Start it next to your HTTP server, so its tools can use your app's code and database:

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

Every instance of your app connects with the same token. Each call is routed to one instance.

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

- `statuspage.env` sets `WARDRIK_URL`, `WARDRIK_TOKEN` and the tool's own keys.
- On the daemon's machine, add `--network host` so `127.0.0.1:4747` resolves to the daemon.
- In Kubernetes, use a Deployment with no Service. Nothing connects to it.

## A daemon on another machine

Add `/v1/workers` to the `@daemon` paths in the daemon's [Caddyfile](/run/public-address/), then
set `WARDRIK_URL=https://agents.acme.example` for the worker.

## Deploys and restarts

- Agents see a tool only while a worker serves it. Run two instances and restart one at a time.
- The SDK reconnects after a disconnect, with backoff up to 30 seconds.
- A rejected token makes `work` throw, so the process exits and its supervisor reports it.
- Revoke the token to disconnect a worker. Its connection closes within 15 seconds.

### Calls in doubt

A call is in doubt when the worker disconnected during it, or returned too late. It's retried or
held for approval as described in [Durable runs](/concepts/agents/#durable-runs).

## Details

- Workers authenticated as the same user share a tool's calls.
- If two users' workers serve tools with the same name, the agent uses the one that connected
  first.
- `work` pings every 15 seconds. Set `keepalive` in milliseconds to change it.
- A worker's results are [content from outside](/concepts/outside-content/), unless `config.yaml`
  sets `http: {trusted_workers: true}`.
