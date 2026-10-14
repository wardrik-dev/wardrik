defmodule WardrikTrigger.Deliveries do
  @moduledoc """
  The `Wardrik.Triggers` a host names to take requests for its agents'
  webhook triggers: a request is handed to the trigger it names, which
  checks it against the secret `:secrets` reads, and asks the agent about it
  unless it has before; a trigger on a clock is sent no requests.

      Wardrik.Host.new(triggers: %WardrikTrigger.Deliveries{secrets: &MyApp.Secrets.read/2})

  `:secrets` reads a webhook's secret by its name for the agent, the
  environment's variable of that name by default, and `:verifiers` names
  the verifiers a webhook may name, as `WardrikTrigger.Offered` finds them.
  """

  @typedoc "Reads a webhook's secret by its name for an agent, `nil` where it is not set."
  @type secrets() :: (String.t(), Wardrik.AgentID.t() -> String.t() | nil)

  defstruct secrets: &__MODULE__.environment/2,
            verifiers: %WardrikTrigger.Offered{}.verifiers

  @type t() :: %__MODULE__{secrets: secrets(), verifiers: %{String.t() => module()}}

  @doc "The environment's variable `name`, for any agent."
  @spec environment(String.t(), Wardrik.AgentID.t()) :: String.t() | nil
  def environment(name, _agent), do: System.get_env(name)

  @doc false
  def deliver(%__MODULE__{} = deliveries, agent, name, opts) do
    case WardrikTrigger.lookup(agent, name) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, {:deliver, Keyword.fetch!(opts, :request), deliveries})
    end
  end
end

defimpl Wardrik.Triggers, for: WardrikTrigger.Deliveries do
  defdelegate deliver(triggers, id, name, opts), to: WardrikTrigger.Deliveries
end
