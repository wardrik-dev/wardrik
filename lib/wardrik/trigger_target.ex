defmodule Wardrik.TriggerTarget do
  @moduledoc """
  Asks Wardrik's agents what their triggers say, waking those that sleep, and writes how each run
  went into the agent's log.
  """

  @behaviour WardrikTriggers.Target

  alias Wardrik.Definition
  alias Wardrik.Operations.Running

  @impl WardrikTriggers.Target
  def ask(wardrik, agent_id, prompt, opts) do
    case Running.awake(wardrik, agent_id) do
      {:ok, pid} -> asked(pid, prompt, opts)
      {:error, _error} -> :no_agent
    end
  end

  @impl WardrikTriggers.Target
  def fired(wardrik, agent_id, trigger, status) do
    data = %{"trigger" => %{"name" => trigger}, "status" => Atom.to_string(status)}

    WardrikEvents.append(
      Wardrik.events(wardrik),
      agent_id,
      {"trigger.fired", "triggers/" <> trigger, data}
    )
  end

  @impl WardrikTriggers.Target
  def resolve_secret(%Wardrik{keys: []}, _agent_id, _name), do: :error

  def resolve_secret(wardrik, agent_id, name) do
    case WardrikVault.fetch(Wardrik.vault(wardrik), Definition.principal(agent_id), name) do
      {:ok, secret} -> {:ok, secret}
      {:error, _reason} -> :error
    end
  end

  defp asked(pid, prompt, opts) do
    if opts[:overlap] == :skip and WardrikCore.status(pid) != :idle do
      :busy
    else
      :ok = WardrikCore.ask(pid, prompt, %{trigger: opts[:trigger]})
      :asked
    end
  end
end
