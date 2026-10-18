defmodule WardrikS3.DurableTest do
  use ExUnit.Case, async: false

  test "holds a DurableServer in a bucket through a restart" do
    WardrikS3.Test.S3Bucket.reset()

    opts = WardrikS3.Test.S3Bucket.store_opts(conditional_delete: false)
    store = WardrikStore.new([adapter: WardrikS3.Store] ++ opts)
    start_supervised!({WardrikStore, store})

    WardrikStore.Test.Durable.survives_a_restart(store, :durable_over_s3)
  end
end
