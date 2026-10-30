defmodule Wardrik.TriggerTarget do
  @moduledoc """
  Delivers trigger prompts to agents. Implements `WardrikTriggers.Target`.

  Wakes sleeping agents to ask them. Records each firing in the agent's log as `trigger.fired`.
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
      :ok = WardrikCore.ask(pid, prompt, metadata(opts))
      :asked
    end
  end

  defp metadata(opts) do
    case Keyword.get(opts, :labels, []) do
      [] -> %{trigger: opts[:trigger]}
      labels -> %{trigger: opts[:trigger], labels: labels}
    end
  end
end
