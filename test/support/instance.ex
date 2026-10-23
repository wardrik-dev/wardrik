defmodule Wardrik.Test.Instance do
  @moduledoc "A Wardrik made as an app makes one, with `use Wardrik`."
  use Wardrik

  @impl Wardrik
  def init(config), do: {:ok, Keyword.put_new(config, :deployment, "from-init")}
end

defmodule Wardrik.Test.Runs do
  @moduledoc "A listener that tells the test each run that completes."
  use Wardrik.Listener, types: ["wardrik.run.completed"]

  @impl Wardrik.Listener
  def handle(event, listener) do
    send(listener.options[:test], {:handled, event, listener})
    :ok
  end
end
