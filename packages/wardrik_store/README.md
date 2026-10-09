# wardrik_store

Where [Wardrik](../wardrik) keeps agents and their records: the
`WardrikStore` behaviour every adapter implements, the facade core and its
packages write through, and the adapters that need nothing else.

| Adapter | Keeps it |
| --- | --- |
| `WardrikStore.EKV` | on each node's disk, replicated between nodes; the default where the application has `:ekv` |
| `WardrikStore.Memory` | in this node's memory, for tests |
| [wardrik_ecto](../wardrik_ecto) | in a Postgres table, through an Ecto repo the host owns |
| [wardrik_s3](../wardrik_s3) | in an S3 bucket |

A deployment names its adapter once, as `Wardrik`'s `:store`:

```elixir
{Wardrik, store: [adapter: WardrikStore.EKV, data_dir: "/var/lib/wardrik"]}
```

## Writing an adapter

An adapter depends on this package alone. It implements `WardrikStore`, and
its tests pass the shared suite:

```elixir
defmodule MyStore.ConformanceTest do
  use WardrikStore.Conformance, adapter: MyStore
end
```

One whose reads are current on every node can hold the fleet through
`WardrikStore.Durable`, and `WardrikStore.Test.Durable.survives_a_restart/2`
checks that a process kept in it comes back as it was.
