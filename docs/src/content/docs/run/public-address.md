---
title: A public address
description: "Give the daemon an HTTPS address, with Caddy in front, so people connect accounts from any browser."
sidebar:
  order: 3
---

When someone [connects an account](/build/accounts/), the provider sends their browser back to the
daemon. Without a public address, that only works from a browser on the daemon's own machine. A
daemon on a server, with people clicking links in Slack, needs an HTTPS address their browsers
reach. Many providers accept no other.

The daemon doesn't end TLS itself. Something in front does, such as Caddy, and passes one path on to
the daemon.

## Set it up with Caddy

You need a domain pointing at the server, such as `agents.example.com`, with ports 80 and 443 open
so Caddy can get a certificate.

1. Point Caddy at the daemon:

   ```text title="/etc/caddy/Caddyfile"
   agents.example.com {
   	handle /oauth/* {
   		reverse_proxy 127.0.0.1:4599
   	}

   	handle /v1/hooks/* {
   		reverse_proxy 127.0.0.1:4747
   	}

   	handle {
   		respond 404
   	}
   }
   ```

   `/oauth/` reaches the account callback. `/v1/hooks/` reaches
   [webhook triggers](/build/triggers/#receiving-a-webhook). The rest of the HTTP API stays on the
   machine.

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
   ok    oauth       https://agents.example.com/oauth reaches the daemon's callback
   ```

Each provider's redirect URI is then `https://agents.example.com/oauth/callback/NAME`, as
`/oauth/callback/github`. The daemon gives it to providers it registers with itself. For one you
registered by hand, with a `client_id`, enter it in the provider's settings.

## What is exposed

Only the callback: `/oauth/callback/NAME` for each provider, and `/oauth/check`, which
`wardrik doctor` uses. Everything else is a 404. A code that comes back finishes only a sign-in this
deployment started, for that provider. The [HTTP API](/build/http-api/) has its own listener, behind
loopback.

## Details

### The callback's address

The callback is `{base_url}/oauth`. `oauth.redirect.url` names another, where it lives elsewhere.

### Keep the path

The daemon serves its pages under the URL's own path, `/oauth` here. Caddy passes the path as it
came. A front that strips the path reaches nothing.

### Where the daemon listens

`oauth.redirect.ip` and `oauth.redirect.port` set the callback listener, `127.0.0.1:4599` by
default, which suits Caddy on the same machine. For a front on another machine, listen on a private
network address, never a public one:

```yaml
oauth:
  redirect:
    url: https://agents.example.com/oauth
    ip: 10.0.0.12
```

In Docker, listen on every interface of the container, `ip: 0.0.0.0`, and publish the port to the
host's loopback only, `-p 127.0.0.1:4599:4599`, for Caddy on the host.

### Other fronts

Any front that ends TLS for a public name and keeps the path will do: another proxy, a cloud load
balancer, or a tunnel. Point `/oauth/` at `http://127.0.0.1:4599` and check with `wardrik doctor`.

### Pages and caches

Every callback page is kept from caches and referrers.

### Providers that allow some domains only

Some providers refuse the daemon's client with `invalid_redirect_uri` until they allow your domain.
Ask them to, with the redirect URI the daemon registers.
