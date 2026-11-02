defmodule Wardrik.TriggerTarget do
  @moduledoc """
  Delivers trigger prompts to agents. Implements `WardrikTriggers.Target`.

  Wakes sleeping agents to ask them. Records each firing in the agent's log as `trigger.fired`.
  """

  @behaviour WardrikTriggers.Target

  alias Wardrik.Definition
  alias Wardrik.Operations.Running
  alias WardrikTriggers.Target.Ask
  alias WardrikTriggers.Target.Fired
  alias WardrikTriggers.Target.Secret

  @impl WardrikTriggers.Target
  def ask(%Ask{agent: agent_id} = ask, wardrik) do
    case Running.awake(wardrik, agent_id) do
      {:ok, pid} -> asked(pid, ask)
      {:error, _error} -> :no_agent
    end
  end

  @impl WardrikTriggers.Target
  def fired(%Fired{agent: agent_id, trigger: trigger, status: status}, wardrik) do
    data = %{"trigger" => %{"name" => trigger}, "status" => Atom.to_string(status)}

    WardrikEvents.append(
      Wardrik.events(wardrik),
      agent_id,
      {"trigger.fired", "triggers/" <> trigger, data}
    )
  end

  @impl WardrikTriggers.Target
  def resolve_secret(%Secret{}, %Wardrik{keys: []}), do: :error

  def resolve_secret(%Secret{agent: agent_id, name: name}, wardrik) do
    vault = Wardrik.vault(wardrik)

    case WardrikVault.fetch(vault, Definition.principal(agent_id), name, kind: :signing_secret) do
      {:ok, secret} -> {:ok, secret}
      {:error, _reason} -> :error
    end
  end

  defp asked(pid, %Ask{prompt: prompt, overlap: overlap} = ask) do
    if overlap == :skip and WardrikCore.status(pid) != :idle do
      :busy
    else
      :ok = WardrikCore.ask(pid, prompt, metadata(ask))
      :asked
    end
  end

  defp metadata(%Ask{trigger: trigger, labels: []}), do: %{trigger: trigger}
  defp metadata(%Ask{trigger: trigger, labels: labels}), do: %{trigger: trigger, labels: labels}
end
