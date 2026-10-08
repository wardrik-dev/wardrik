defmodule WardrikS3.DurableTest do
  use ExUnit.Case, async: false

  test "holds a DurableServer in a bucket through a restart" do
    WardrikS3.Test.S3Bucket.reset()

    :ignore =
      WardrikS3.Store.start_link(WardrikS3.Test.S3Bucket.store_opts(conditional_delete: false))

    WardrikStore.Test.Durable.survives_a_restart(WardrikS3.Store, :durable_over_s3)
  end
end
