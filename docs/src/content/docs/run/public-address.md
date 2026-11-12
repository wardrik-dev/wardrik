---
title: Set up public HTTPS access
description: "Put the daemon behind Caddy at an HTTPS address, for OAuth callbacks, Slack and webhooks."
sidebar:
  order: 4
---

Expose selected routes over HTTPS for OAuth callbacks, Slack events, and incoming webhooks.
The daemon serves HTTP; this example uses Caddy to terminate TLS.

You need a domain pointing to the server and ports 80 and 443 available to Caddy.

```text title="/etc/caddy/Caddyfile"
agents.example.com {
	@daemon path /oauth/* /v1/hooks/* /v1/channels/* /v1/openapi.json
	handle @daemon {
		reverse_proxy 127.0.0.1:4747
	}
	handle {
		respond 404
	}
}
```

```yaml title="~/.config/wardrik/config.yaml"
base_url: https://agents.example.com
```

```sh
systemctl --user restart wardrik
wardrik doctor
# ok    oauth          https://agents.example.com/oauth reaches the daemon
```

## Exposed paths

| Path | Access |
| --- | --- |
| `/oauth/callback` | a browser completing a sign-in this daemon started |
| `/oauth/device/ID` | anyone with the link; shows a device sign-in's code |
| `/oauth/client` | anyone; the client's public metadata |
| `/v1/hooks/AGENT/TRIGGER` | requests with the [trigger's](/build/triggers/) secret |
| `/v1/channels/CHANNEL/...` | requests signed by Slack |
| `/v1/openapi.json` | anyone; `wardrik doctor` fetches it |

This proxy configuration exposes only the listed paths. Add `/v1/workers` for [tool workers](/build/host-tools/) on other
machines, and `/web/*` for the [dashboard](/run/dashboard/#from-another-machine).

## Details

- Every provider's redirect URI is `{base_url}/oauth/callback`.
- Without `base_url`, it's `http://127.0.0.1:4747`, reachable only from the same machine.
- Don't rewrite the path. A proxy that strips it breaks every route.
- For a proxy on another machine, listen on a private address, such as `http: {ip: 10.0.0.12}`.
  Keep the daemon’s HTTP port off the public network.
- In a container, listen on `0.0.0.0`, and publish `-p 127.0.0.1:4747:4747`.
- Any proxy that terminates TLS and preserves the path works, such as a load balancer or a tunnel.
- Providers with `flow: device` need no callback.
