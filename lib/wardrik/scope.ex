defmodule Wardrik.Scope do
  @moduledoc """
  Who is acting through Wardrik, and on whose behalf.

      scope = MyApp.AgentRuntime.as("user_42")

  `Wardrik.as/3` makes a scope. The host's `Wardrik.Authorizer` decides what it may do.

  As in RFC 8693, `:principal` is on whose behalf the scope acts, and `:actor` is who acts:

      # Maria herself
      MyApp.AgentRuntime.as("user_42")

      # Maria's assistant, through its own tools
      MyApp.AgentRuntime.as("user_42", actor: {:agent, "agt_01JF8X5RQ2"})

  ## Fields

    * `:server` - the `Wardrik.Server` that runs its operations.
    * `:wardrik` - which Wardrik, by name.
    * `:principal` - on whose behalf it acts.
    * `:actor` - who acts, as `{:agent, id}` or `{:channel, name}`, or `nil` when the principal
      acts directly.
    * `:context` - what the actor knows that the authorizer may read, as a channel's
      `:asked_by`. `%{}` unless set.
    * `:policy` - in an agent's scope, the policy every agent it defines is held to.
    * `:labels` - in an agent's scope, the labels of what its run has read. Messages it sends
      carry them too.
    * `:operation` - the operation running, while one runs.
  """

  alias WardrikCore.Principal

  @enforce_keys [:server, :wardrik, :principal]
  defstruct [:server, :wardrik, :principal, :actor, :operation, :policy, context: %{}, labels: []]

  @typedoc "Who acts for the principal, by kind and ID, or `nil` when the principal acts directly."
  @type actor() :: {atom(), String.t()} | nil

  @type t() :: %__MODULE__{
          server: module(),
          wardrik: atom() | struct(),
          principal: Principal.t(),
          actor: actor(),
          context: map(),
          operation: WardrikProtocol.operation() | nil,
          policy: String.t() | map() | nil,
          labels: [String.t()]
        }

  @doc """
  Returns a scope for `:principal` on `:wardrik`, run by `server`.

      Wardrik.Scope.new(Wardrik,
        wardrik: MyApp.AgentRuntime,
        principal: "user_42",
        actor: {:channel, "slack"},
        context: %{asked_by: "user_7"}
      )

  `:principal` is a `WardrikCore.Principal` or its ID. `:actor` is `nil` and `:context` `%{}`
  unless set.
  """
  @spec new(module(),
          wardrik: atom() | struct(),
          principal: Principal.t() | String.t(),
          actor: actor(),
          context: map()
        ) :: t()
  def new(server, args) do
    args = Keyword.validate!(args, [:wardrik, :principal, actor: nil, context: %{}])

    %__MODULE__{
      server: server,
      wardrik: Keyword.fetch!(args, :wardrik),
      principal: args |> Keyword.fetch!(:principal) |> principal(),
      actor: args[:actor],
      context: args[:context]
    }
  end

  @doc "Runs operation `id` with `input` through the scope's server."
  @spec run(t(), String.t(), map()) :: {:ok, term()} | {:error, Wardrik.Error.t()}
  def run(%__MODULE__{server: server} = scope, id, input),
    do: server.run(%Wardrik.Server.Request{scope: scope, operation: id, input: input})

  @doc "Streams operation `id` with `input` through the scope's server."
  @spec stream(t(), String.t(), map()) :: {:ok, Enumerable.t()} | {:error, Wardrik.Error.t()}
  def stream(%__MODULE__{server: server} = scope, id, input),
    do: server.stream(%Wardrik.Server.Request{scope: scope, operation: id, input: input})

  defp principal(%Principal{} = principal), do: principal
  defp principal(id) when is_binary(id), do: %Principal{id: id}
end
