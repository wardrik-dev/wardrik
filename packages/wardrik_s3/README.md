# wardrik_s3

A [Wardrik store](../wardrik_store) in an S3 bucket, on AWS, R2, MinIO or anything
else that speaks S3.

```elixir
def deps do
  [{:wardrik_s3, "~> 0.1.0"}]
end
```

Start Wardrik in your own tree, and name the bucket as its store:

```elixir
# config/config.exs
config :wardrik, start: :host

# lib/my_app/application.ex
{Wardrik,
 store: [
   adapter: WardrikS3.Store,
   bucket: "wardrik",
   endpoint: "https://<account>.r2.cloudflarestorage.com",
   region: "auto",
   access_key_id: System.fetch_env!("R2_ACCESS_KEY_ID"),
   secret_access_key: System.fetch_env!("R2_SECRET_ACCESS_KEY")
 ]}
```

Everything is kept under `wardrik/`, or the `:prefix` you name, one prefix to
a namespace: an agent is `wardrik/durable/agents/<org>/<user>/<name>`, and its
events are under `wardrik/events/`.

Writes are conditional, so the bucket must refuse a write whose condition
fails. The store checks this as it starts, and keeps nothing in a bucket that
does not.
