---
title: A public address
description: "Give the daemon an HTTPS address, with Caddy in front, so people connect accounts from any browser and Slack reaches it."
sidebar:
  order: 3
---

When someone [connects an account](/build/accounts/), the provider sends their browser back to the
daemon. Slack and webhook senders call it too. All of them need an HTTPS address they can reach,
and many providers accept no other.

The daemon speaks plain HTTP. Something in front ends TLS, such as Caddy, and passes a few paths on
to the daemon's HTTP API.

## Set it up with Caddy

You need a domain pointing at the server, such as `agents.example.com`, with ports 80 and 443 open
so Caddy can get a certificate.

1. Point Caddy at the daemon:

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

   | Path | Reaches |
   | --- | --- |
   | `/oauth/` | the sign-in pages, and the callback providers send browsers to |
   | `/v1/hooks/` | [webhook triggers](/build/triggers/#receiving-a-webhook) |
   | `/v1/channels/` | what [Slack](/channels/slack/) sends |
   | `/v1/openapi.json` | the API's public description, which `wardrik doctor` fetches to find the daemon |

   The rest of the HTTP API stays on the machine.

2. Tell the daemon its address:

   ```yaml title="~/.config/wardrik/config.yaml"
   base_url: https://agents.example.com
   ```

3. Restart and check:

   ```sh
   systemctl --user restart wardrik
   wardrik doctor
   ```

   ```
   ok    oauth          https://agents.example.com/oauth reaches the daemon
   ```

Every provider's redirect URI is then `https://agents.example.com/oauth/callback`. The daemon gives
it to providers it registers with itself. For one you registered by hand, with a `client_id`,
enter it in the provider's settings.

## What is exposed

| Path | Who gets in |
| --- | --- |
| `/oauth/callback` | a browser finishing a sign-in this deployment started |
| `/oauth/device/ID` | anyone with the link, which shows a device sign-in's code |
| `/oauth/client` | anyone; the client's public metadata |
| `/v1/hooks/AGENT/TRIGGER` | a sender holding the trigger's secret |
| `/v1/channels/CHANNEL/...` | a request Slack signed |
| `/v1/openapi.json` | anyone; it holds no data |

Everything else is a 404 at Caddy. The rest of the [HTTP API](/build/http-api/) stays behind
loopback.

## Details

### `base_url`

`base_url` is where people and services reach the deployment. Without it, it's the HTTP API's own
address, `http://127.0.0.1:4747`, which only a browser on the same machine reaches.

### When `wardrik doctor` checks the address

The `oauth` check runs once `config.yaml` names an `oauth` provider. It fetches
`{base_url}/v1/openapi.json`. Providers that all use `flow: device` need no callback, and the check
says so.

### Keep the path

The daemon serves its pages under `/oauth`. Caddy passes the path as it came. A front that strips
the path reaches nothing.

### Where the daemon listens

The HTTP API listens on `127.0.0.1:4747` by default, which suits Caddy on the same machine. For a
front on another machine, listen on a private network address, never a public one:

```yaml title="~/.config/wardrik/config.yaml"
http:
  ip: 10.0.0.12
  port: 4747
```

In a container, listen on every interface of the container, `ip: 0.0.0.0`. Then publish the port
to the host's loopback only, `-p 127.0.0.1:4747:4747`, for Caddy on the host.

### Other fronts

Any front that ends TLS for a public name and keeps the path will do: another proxy, a cloud load
balancer, or a tunnel. Pass the paths above to `http://127.0.0.1:4747` and check with
`wardrik doctor`.

### Pages and caches

The callback and device pages are sent with `cache-control: no-store`.

### Providers that allow some domains only

Some providers refuse the daemon's client with `invalid_redirect_uri` until they allow your domain.
Ask them to, with the redirect URI above.
