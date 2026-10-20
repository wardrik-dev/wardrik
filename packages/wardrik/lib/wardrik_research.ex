defmodule WardrikResearch do
  @moduledoc """
  Research for agents, attached to the `Wardrik.Host` they run on, where a
  definition names it as `deep_research`:

      host = WardrikResearch.attach(host)

  `WardrikResearch.Deep` is the tool, and says how a sweep runs.
  """

  @behaviour Wardrik.Plugin

  @doc "`host` with `WardrikResearch.Deep` among its tools, as `deep_research`. It takes no options."
  @spec attach(Wardrik.Host.t(), keyword()) :: Wardrik.Host.t()
  @impl true
  def attach(%Wardrik.Host{} = host, opts \\ []) do
    Keyword.validate!(opts, [])
    Wardrik.Host.register(host, :tools, [{"deep_research", WardrikResearch.Deep}])
  end
end
