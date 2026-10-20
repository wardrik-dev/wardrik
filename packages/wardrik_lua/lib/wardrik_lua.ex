defmodule WardrikLua do
  @moduledoc """
  Lua for agents, attached to the `Wardrik.Host` they run on, where a
  definition names it as `run_lua`:

      host = WardrikLua.attach(host)

  `WardrikLua.Run` is the tool, and `WardrikLua.Sandbox` what it runs in.
  """

  @behaviour Wardrik.Plugin

  @doc "`host` with `WardrikLua.Run` among its tools, as `run_lua`. It takes no options."
  @spec attach(Wardrik.Host.t(), keyword()) :: Wardrik.Host.t()
  @impl true
  def attach(%Wardrik.Host{} = host, opts \\ []) do
    Keyword.validate!(opts, [])
    Wardrik.Host.register(host, :tools, [{"run_lua", WardrikLua.Run}])
  end
end
