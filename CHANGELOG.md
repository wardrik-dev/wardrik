# Changelog

## 0.1.0-rc.4 (2026-11-04)

- `WardrikStore.EKV` takes a plain write or delete over a key written with `:if_vsn`, as the other
  adapters do. EKV refused them with `:cas_managed_key`, so removing a trigger, trimming an event
  log, and deleting an OAuth grant or registration failed on it.

## 0.1.0-rc.3 (2026-11-03)

- `WardrikStore.versions/2` lists keys with their versions, reading no values. Adapters can
  implement `c:WardrikStore.Adapter.versions/2` to do it in one cheap read; the three built in do.
- `WardrikStore.Durable` lists agents without reading their state.

## 0.1.0-rc.1 (2026-10-30)

- `WardrikStore`, a durable key-value store that Wardrik packages keep their data in.
- Three adapters: `WardrikStore.ETS` in memory, `WardrikStore.EKV` on disk and on each connected
  node, and `WardrikStore.Ecto` in Postgres.
- Ecto through your app's repo, with `WardrikStore.Ecto.Migration`, or through a repo of its own
  from a URL.
- Scopes that keep each package's keys apart from the others', and your app's too.
- Conditional writes with `:if_vsn`, so two writers never overwrite each other.
- `WardrikStore.Durable`, which keeps WardrikCore's agents in the store.
- `WardrikStore.Adapter`, to write an adapter of your own.
