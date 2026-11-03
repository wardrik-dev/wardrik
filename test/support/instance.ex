defmodule Wardrik.Test.Instance do
  @moduledoc "A Wardrik made as an app makes one, with `use Wardrik`."
  use Wardrik

  @impl Wardrik
  def init(config),
    do:
      {:ok,
       config
       |> Keyword.put_new(:deployment, "from-init")
       |> Keyword.put_new(:authorizer, {Wardrik.Test.Allow, []})
       |> Keyword.put_new(:resolver, {Wardrik.Test.Owned, __MODULE__})}
end

defmodule Wardrik.Test.Sunk do
  @moduledoc "A sink that sends the test each kept event."
  @behaviour WardrikEvents.Sink

  @impl WardrikEvents.Sink
  def handle_event(event, test), do: send(test, {:sunk, event})
end
