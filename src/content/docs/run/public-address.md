---
title: A public address
description: "Give the daemon an HTTPS address, with Caddy in front, so people connect accounts from any browser and Slack reaches it."
sidebar:
  order: 3
---

OAuth providers, Slack and webhook senders need an HTTPS address that reaches the daemon. The
daemon speaks plain HTTP, so put Caddy in front.

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

You need a domain pointing at the server, with ports 80 and 443 open, so Caddy gets a certificate.

## What is exposed

| Path | Who gets in |
| --- | --- |
| `/oauth/callback` | a browser finishing a sign-in this daemon started |
| `/oauth/device/ID` | anyone with the link; it shows a device sign-in's code |
| `/oauth/client` | anyone; the client's public metadata |
| `/v1/hooks/AGENT/TRIGGER` | a sender holding the [trigger's](/build/triggers/) secret |
| `/v1/channels/CHANNEL/...` | a request Slack signed |
| `/v1/openapi.json` | anyone; `wardrik doctor` fetches it |

Everything else stays on the machine. Add `/v1/workers` for [tool workers](/build/host-tools/)
elsewhere.

## Details

- Every provider's redirect URI is `{base_url}/oauth/callback`.
- Without `base_url`, it's `http://127.0.0.1:4747`, which only a browser on the same machine reaches.
- Keep the path as it came. A front that strips it reaches nothing.
- For a front on another machine, listen on a private address: `http: {ip: 10.0.0.12}`. Never a
  public one.
- In a container, listen on `0.0.0.0`, and publish `-p 127.0.0.1:4747:4747`.
- Any front that ends TLS and keeps the path will do: a load balancer or a tunnel.
- Providers with `flow: device` need no callback.
