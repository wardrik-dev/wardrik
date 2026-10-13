defmodule WardrikTrigger.Delivery do
  @moduledoc """
  Asking an agent on a trigger's behalf, whichever kind of trigger it is:
  whether the agent can be asked now, as the trigger's `overlap` says, the
  asking, with what was found under the prompt and labelled as it is, and
  what came of it, announced on the agent's topic as
  `Wardrik.Event.TriggerFired`.
  """

  alias Wardrik.Agent
  alias Wardrik.AgentID
  alias Wardrik.Event
  alias Wardrik.Fleet
  alias WardrikTrigger.Item

  @doc """
  The agent `agent`'s process, woken where it sleeps, where it may be asked
  now; else why not: `:busy` where it is running or waiting and `overlap` is
  `:skip`, `:no_agent` where none runs under the ID, and `:failed` where
  looking it up exited.
  """
  @spec ready(AgentID.t(), :skip | :queue) :: {:ok, pid()} | :busy | :no_agent | :failed
  def ready(%AgentID{} = agent, overlap) do
    case Fleet.whereis(agent) do
      nil -> :no_agent
      pid -> idle(pid, overlap)
    end
  catch
    :exit, _reason -> :failed
  end

  defp idle(pid, :queue), do: {:ok, pid}

  defp idle(pid, :skip) do
    case Agent.status(pid) do
      %{state: :idle} -> {:ok, pid}
      %{state: _running_or_parked} -> :busy
      {:error, :not_found} -> :no_agent
    end
  end

  @doc "Asks the agent at `pid` `prompt`, with `items` under it and their labels."
  @spec ask(pid(), String.t(), [Item.t()]) :: :ok
  def ask(pid, prompt, items),
    do: Agent.ask(pid, Item.message(prompt, items), labels: Item.labels(items))

  @doc "Says on `agent`'s topic that its trigger `name` came to `outcome`."
  @spec announce(AgentID.t(), String.t(), WardrikTrigger.outcome()) :: :ok
  def announce(%AgentID{} = agent, name, outcome),
    do: Event.announce(agent, %Event.TriggerFired{name: name, outcome: outcome})
end
