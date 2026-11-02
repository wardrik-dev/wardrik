# Changelog

## 0.1.0-rc.2 (2026-11-02)

### Breaking

- `WardrikTriggers.Target` callbacks take a struct, then their options: `ask/2` a
  `WardrikTriggers.Target.Ask`, `fired/2` a `WardrikTriggers.Target.Fired`, and `resolve_secret/2`
  a `WardrikTriggers.Target.Secret`.
- `deliver/2` and `remove/2` take one keyword list: `:agent_id`, `:name`, and `deliver/2`'s
  `:request`.
- `WardrikTriggers.Webhook.verify/2` takes the request, then `:verify`, `:secret` and `:now`.

## 0.1.0-rc.1 (2026-10-30)

- Triggers that ask an agent something on a cron expression read in a time zone, or on an interval,
  with jitter, and once for runs missed while nothing ran them.
- Feeds, RSS or Atom, that ask only when they hold entries not seen before.
- Webhooks, proved by a shared secret or a Standard Webhooks signature, asked about once each.
- Each trigger runs once in a cluster, claimed in a `WardrikStore`.
- What a feed's entries or a webhook's request asks is labelled `"outside"` for the target.
