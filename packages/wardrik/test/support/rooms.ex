defmodule WardrikNotify.Test.Rooms do
  @moduledoc false
  # Rooms that tell `test` each notice posted in one, as
  # `{:posted, room, notice}`.

  @enforce_keys [:test]
  defstruct [:test]

  defimpl WardrikNotify.Rooms do
    def post(%{test: test}, room, notice, _opts) do
      send(test, {:posted, room, notice})
      :ok
    end
  end
end
