defmodule WardrikS3.LiveTest do
  use ExUnit.Case, async: false

  @moduletag :s3

  setup_all do
    :ignore = WardrikS3.Store.start_link(WardrikS3.Test.Services.s3_opts())
    :ok
  end

  use WardrikStore.Conformance, adapter: WardrikS3.Store
end
