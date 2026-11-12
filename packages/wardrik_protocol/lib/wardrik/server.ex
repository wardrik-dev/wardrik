defmodule Wardrik.Server do
  @moduledoc """
  A behaviour for what runs Wardrik's operations. `Wardrik` implements it.

  `Wardrik.Agent` and the other operation modules call the server in their `Wardrik.Scope`. So
  packages call them without depending on `wardrik`. `WardrikTesting.Server` implements it for tests.
  """

  @doc "Runs the request's operation."
  @callback run(Wardrik.Server.Request.t()) :: {:ok, term()} | {:error, Wardrik.Error.t()}

  @doc "Runs the request's streamed operation. Streams `{event, cursor}`: kept events, then new ones."
  @callback stream(Wardrik.Server.Request.t()) ::
              {:ok, Enumerable.t()} | {:error, Wardrik.Error.t()}

  @doc """
  Sends the input to the agent and streams its answer:

    1. `{:text, chunk}`, any number of times.
    2. One of `{:done, %Wardrik.Reply{}}`, `{:waiting, interrupts}` or `{:failed, why}`.

  Raises `Wardrik.Error` if the agent can't be reached.
  """
  @callback follow(Wardrik.Server.Follow.t(), opts :: keyword()) :: Enumerable.t()

  @doc """
  Offers a worker's tools, as MCP's `tools/list` returns them. The calling process then receives:

    * `{Wardrik.Workers, :call, call, name, arguments, meta}` for each call to a tool.
    * `{Wardrik.Workers, :cancel, call}` when a call is cancelled.
  """
  @callback offer(Wardrik.Scope.t(), tools :: [map()]) :: :ok | {:error, term()}

  @doc "Answers the worker's `call` with the JSON-RPC `message`."
  @callback answer(call :: term(), message :: map()) :: :ok
end
