---
title: Host your tools
description: "Run tool workers in your app or in containers, connect to a remote daemon, and keep tools available during deployments."
sidebar:
  order: 3.3
---

A tool worker registers tools and calls `wardrik.work()` to receive requests. It needs only an
outbound connection to Wardrik; no inbound port is required.

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

## In a container

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

## Connect to a remote daemon

Add `/v1/workers` to the `@daemon` paths in the daemon's [Caddyfile](/run/public-address/), then
set `WARDRIK_URL=https://agents.acme.example` for the worker.

## Deploys and restarts

- Agents see a tool only while a worker serves it. Run two instances and restart one at a time.
- The SDK reconnects after a disconnect, with backoff up to 30 seconds.
- A rejected token makes `work` throw, so the process exits and its supervisor reports it.
- Revoke the token to disconnect a worker. Its connection closes within 15 seconds.

### Calls with uncertain results

If a tool worker disconnects during a call or returns after the timeout, Wardrik may not know
whether the call completed. It retries calls marked safe to repeat and requires approval for others. See [Durable runs](/concepts/agents/#durable-runs).

## Details

- Workers authenticated as the same user share a tool's calls.
- If two users' workers serve tools with the same name, the agent uses the one that connected
  first.
- `work` pings every 15 seconds. Set `keepalive` in milliseconds to change it.
- A worker's results are [untrusted content](/concepts/outside-content/), unless `config.yaml`
  sets `http: {trusted_workers: true}`.
