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

A deployment names its adapter once, as a store value it starts and hands to
everything that keeps anything, `Wardrik.Core` on its host among them:

```elixir
store = WardrikStore.new(adapter: WardrikStore.EKV, data_dir: "/var/lib/wardrik")
children = [{WardrikStore, store}, {Wardrik.Core, host: Wardrik.Host.new(store: store)}]
```

## Writing an adapter

An adapter depends on this package alone. It implements `WardrikStore`, and
its tests pass the shared suite:

```elixir
defmodule MyStore.ConformanceTest do
  use ExUnit.Case
  use WardrikStore.Conformance

  setup_all do
    store = WardrikStore.new(adapter: MyStore)
    start_supervised!({WardrikStore, store})
    %{store: store}
  end
end
```

One whose reads are current on every node can hold the fleet through
`WardrikStore.Durable`, and `WardrikStore.Test.Durable.survives_a_restart/2`
checks that a process kept in it comes back as it was.
