defmodule Wardrik.Test.Model do
  @moduledoc """
  Starts a `Wardrik.Testing.Model` for a test, and returns endpoints that send the models the
  tests name to it.
  """

  import ExUnit.Callbacks, only: [start_supervised!: 1]

  @models ["anthropic:claude-haiku-4-5", "test"]

  @doc "Starts the model with no answers yet. Returns it, and the endpoints for `Wardrik.new/1`."
  def start do
    fake = start_supervised!({Wardrik.Testing.Model, []})
    endpoint = Wardrik.Testing.Model.endpoint(fake)
    {fake, Map.new(@models, &{&1, endpoint})}
  end
end
