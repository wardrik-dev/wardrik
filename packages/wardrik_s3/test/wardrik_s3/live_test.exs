defmodule WardrikS3.LiveTest do
  use ExUnit.Case, async: false

  @moduletag :s3

  setup_all do
    store = WardrikStore.new([adapter: WardrikS3.Store] ++ WardrikS3.Test.Services.s3_opts())
    start_supervised!({WardrikStore, store})
    %{store: store}
  end

  use WardrikStore.Conformance
end
