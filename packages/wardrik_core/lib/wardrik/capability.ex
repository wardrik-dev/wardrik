defmodule Wardrik.Capability do
  @moduledoc """
  Gives an agent its tools.

      defmodule MyApp.Orders do
        @behaviour Wardrik.Capability

        @impl true
        def tools(_context, orders) do
          [
            Wardrik.Tool.new!(
              name: "order_status",
              description: "Say where an order is.",
              schema: [order_id: [type: :string, required: true]],
              run: fn %{order_id: id}, _context -> {:ok, Map.get(orders, id, "unknown")} end
            )
          ]
        end
      end

  Give it to an agent as `capabilities: [{MyApp.Orders, opts}]`. `opts` goes to `c:tools/2`.

  A tool that parks on a reason of its own lists the reason's `Wardrik.Format` in
  `c:formats/0`. See `Wardrik.Middleware`.
  """
  alias Wardrik.Context

  @doc "Returns the tools for an agent, given its context and the options it was given."
  @callback tools(Context.t(), opts :: term()) :: [Wardrik.Tool.t()]

  @doc "The `Wardrik.Format`s of what its tools park on."
  @callback formats() :: [module()]

  @optional_callbacks formats: 0
end
