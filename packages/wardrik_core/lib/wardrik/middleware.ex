defmodule Wardrik.Middleware do
  @moduledoc """
  Wraps every step of a turn: the turn, each model call and each tool call.

      defmodule MyApp.NoShell do
        @behaviour Wardrik.Middleware

        @impl true
        def call(%{step: {:tool_call, %{name: "shell"}}} = context, _next, _opts),
          do: {:ok, %{context | response: {:error, "No shell."}}}

        def call(context, next, _opts), do: next.(context)
      end

  Give it to an agent as `middleware: [MyApp.NoShell]` or `[{MyApp.NoShell, opts}]`. The first runs
  outermost.

  ## Return values

    * `next.(context)` - carries on.
    * `{:ok, context}` - answers the step with `context.response`.
    * `{:park, reason, context}` - waits for `WardrikCore.resume/3`.
    * `{:error, reason}` - ends the step.

  ## Kept data

  A park reason, or a value kept with `Wardrik.Context.put_private/3`, survives a restart
  as JSON. Each one's module must be a `Wardrik.Format` with a `c:Wardrik.Format.type/0`,
  listed by `c:formats/0`. Use that module as the private key.
  """
  alias Wardrik.Context
  @type context :: Context.t()
  @type result :: {:ok, context()} | {:error, term()} | {:park, term(), context()}
  @type next :: (context() -> result())

  @doc "Handles one step. Call `next` to carry on, or return a result to stop."
  @callback call(context, next, opts :: term()) :: result()

  @doc "The `Wardrik.Format`s of what it parks on and keeps privately."
  @callback formats() :: [module()]

  @optional_callbacks formats: 0
end
