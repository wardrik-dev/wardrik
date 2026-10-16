# wardrik_s3

A [Wardrik store](../wardrik_store) in an S3 bucket, on AWS, R2, MinIO or anything
else that speaks S3.

```elixir
def deps do
  [{:wardrik_s3, "~> 0.1.0"}]
end
```

An application embedding [Wardrik](../wardrik) has it already, and names the
bucket as its store:

```elixir
store =
  Wardrik.store(
    bucket: "wardrik",
    endpoint: "https://<account>.r2.cloudflarestorage.com",
    region: "auto",
    access_key_id: System.fetch_env!("R2_ACCESS_KEY_ID"),
    secret_access_key: System.fetch_env!("R2_SECRET_ACCESS_KEY")
  )

children = [{Wardrik, Wardrik.new(store: store)}]
```

A host that puts its own tree together names the adapter:

```elixir
store = WardrikStore.new(adapter: WardrikS3.Store, bucket: "wardrik", ...)
children = [{WardrikStore, store}, {Wardrik.Core, host: Wardrik.Host.new(store: store)}]
```

Everything is kept under `wardrik/`, or the `:prefix` you name, one prefix to
a namespace: an agent is `wardrik/durable/agents/<org>/<user>/<name>`, and its
events are under `wardrik/events/`.

Writes are conditional, so the bucket must refuse a write whose condition
fails. The store checks this as it starts, and keeps nothing in a bucket that
does not.
