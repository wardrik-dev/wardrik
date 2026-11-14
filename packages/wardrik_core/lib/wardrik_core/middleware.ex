defmodule WardrikCore.Middleware do
  @moduledoc """
  Wraps every step of a turn: the turn, each model call and each tool call.

      defmodule MyApp.NoShell do
        @behaviour WardrikCore.Middleware

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

  A park reason, or a value kept with `WardrikCore.Context.put_private/3`, survives a restart
  as JSON. Each one's module must be a `WardrikCore.Format` with a `c:WardrikCore.Format.type/0`,
  listed by `c:formats/0`. Use that module as the private key.
  """
  alias WardrikCore.Context
  @type context :: Context.t()
  @type result :: {:ok, context()} | {:error, term()} | {:park, term(), context()}
  @type next :: (context() -> result())

  @doc "Handles one step. Call `next` to carry on, or return a result to stop."
  @callback call(context, next, opts :: term()) :: result()

  @doc "The `WardrikCore.Format`s of what it parks on and keeps privately."
  @callback formats() :: [module()]

  @optional_callbacks formats: 0
end
