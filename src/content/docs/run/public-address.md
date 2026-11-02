---
title: A public address
description: "Put the daemon behind Caddy at an HTTPS address, for OAuth callbacks, Slack and webhooks."
sidebar:
  order: 3
---

OAuth providers, Slack and webhook senders need an HTTPS URL for the daemon. The daemon serves
plain HTTP, so put Caddy in front.

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

Requires a domain pointing at the server, with ports 80 and 443 open for Caddy's certificate.

## Exposed paths

| Path | Access |
| --- | --- |
| `/oauth/callback` | a browser completing a sign-in this daemon started |
| `/oauth/device/ID` | anyone with the link; shows a device sign-in's code |
| `/oauth/client` | anyone; the client's public metadata |
| `/v1/hooks/AGENT/TRIGGER` | requests with the [trigger's](/build/triggers/) secret |
| `/v1/channels/CHANNEL/...` | requests signed by Slack |
| `/v1/openapi.json` | anyone; `wardrik doctor` fetches it |

No other path is exposed. Add `/v1/workers` for [tool workers](/build/host-tools/) on other
machines.

## Details

- Every provider's redirect URI is `{base_url}/oauth/callback`.
- Without `base_url`, it's `http://127.0.0.1:4747`, reachable only from the same machine.
- Don't rewrite the path. A proxy that strips it breaks every route.
- For a proxy on another machine, listen on a private address, such as `http: {ip: 10.0.0.12}`.
  Never a public one.
- In a container, listen on `0.0.0.0`, and publish `-p 127.0.0.1:4747:4747`.
- Any proxy that terminates TLS and preserves the path works, such as a load balancer or a tunnel.
- Providers with `flow: device` need no callback.
