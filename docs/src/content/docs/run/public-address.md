---
title: A public address
description: Serve the page a provider sends a browser back to over HTTPS, so people connect accounts from any browser, with Caddy in front of the daemon.
sidebar:
  order: 3
---

When someone [connects an account](/build/accounts/) in a browser, the provider sends that browser
back to the daemon with a code. Without a public address, the daemon takes it on its own machine's
loopback, `http://127.0.0.1:4599`, so the browser has to be on that machine too. A daemon on a
server, with people clicking a link in Slack from their own laptops, needs an address their browsers
reach, over HTTPS: many providers accept no other redirect.

The daemon does not end TLS itself. Something in front of it does, such as Caddy, and passes
requests under one path on to the daemon's callback listener, which serves nothing else.

## With Caddy

You need a domain name pointing at the server, such as `agents.example.com`, and ports 80 and 443
open to it, so Caddy can get a certificate from Let's Encrypt.

```text title="/etc/caddy/Caddyfile"
agents.example.com {
	handle /oauth/* {
		reverse_proxy 127.0.0.1:4599
	}

	handle {
		respond 404
	}
}
```

Tell the daemon the address, and restart it:

```yaml title="~/.config/wardrik/config.yaml"
oauth:
  redirect:
    url: https://agents.example.com/oauth
```

```sh
systemctl --user restart wardrik
wardrik doctor
```

`wardrik doctor` asks the address for a check page, through Caddy, and says whether the daemon
answered:

```
ok    oauth       https://agents.example.com/oauth reaches the daemon's callback
```

Each provider's redirect URI is then the URL with `/callback/` and the provider's name after it:
`https://agents.example.com/oauth/callback/github` for `github`. A provider the daemon registers
with by itself is given it; for one registered by hand, with a `client_id`, enter it in the
provider's settings.

Caddy passes requests on with their path as it came, which is what the daemon serves: its pages are
under the URL's own path, `/oauth` here. A front that strips the path before passing a request on
reaches nothing.

## What is exposed

Only the callback: `/oauth/callback/NAME` for each provider configured, and `/oauth/check`, which
answers `wardrik doctor`. Anything else is a 404, and every page is kept from caches and referrers.
A code that comes back finishes only a sign-in this deployment started, for the provider whose path
it came to. The [HTTP API](/build/http-api/) has a listener of its own, and stays behind loopback.

## Where the daemon listens

`oauth.redirect.ip` and `oauth.redirect.port` say where the callback listener listens: `127.0.0.1`
and `4599` by default, which suits Caddy on the same machine. For a front on another machine, listen
on an address of a private network between them, never a public one:

```yaml
oauth:
  redirect:
    url: https://agents.example.com/oauth
    ip: 10.0.0.12
```

The Docker image's loopback is reachable from nowhere else, so there, listen on every interface of
the container, `ip: 0.0.0.0`, and publish the port to the host's loopback alone,
`-p 127.0.0.1:4599:4599`, for Caddy on the host.

## Other fronts

Anything that ends TLS for a public name and passes requests on with their path will do: another
reverse proxy, a cloud load balancer, or a tunnel. Point the name's `/oauth/` path at
`http://127.0.0.1:4599`, keeping the path, and check it with `wardrik doctor`.

## Providers that allow some domains only

Some providers' servers take a redirect only to domains they have allowed, and refuse the client
the daemon registers with `invalid_redirect_uri` until they have. Ask the provider to allow your
domain, giving the redirect URI the daemon registers for it.
