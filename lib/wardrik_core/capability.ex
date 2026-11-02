defmodule WardrikCore.Capability do
  @moduledoc """
  Gives an agent its tools.

      defmodule MyApp.Orders do
        @behaviour WardrikCore.Capability

        @impl true
        def tools(_context, orders) do
          [
            WardrikCore.Tool.new!(
              name: "order_status",
              description: "Say where an order is.",
              schema: [order_id: [type: :string, required: true]],
              run: fn %{order_id: id}, _context -> {:ok, Map.get(orders, id, "unknown")} end
            )
          ]
        end
      end

  Give it to an agent as `capabilities: [{MyApp.Orders, opts}]`. `opts` goes to `c:tools/2`.
  """
  alias WardrikCore.Context

  @doc "Returns the tools for an agent, given its context and the options it was given."
  @callback tools(Context.t(), opts :: term()) :: [WardrikCore.Tool.t()]
end
