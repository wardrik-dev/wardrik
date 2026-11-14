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

  A tool that parks on a reason of its own lists the reason's `WardrikCore.Format` in
  `c:formats/0`. See `WardrikCore.Middleware`.
  """
  alias WardrikCore.Context

  @doc "Returns the tools for an agent, given its context and the options it was given."
  @callback tools(Context.t(), opts :: term()) :: [WardrikCore.Tool.t()]

  @doc "The `WardrikCore.Format`s of what its tools park on."
  @callback formats() :: [module()]

  @optional_callbacks formats: 0
end
