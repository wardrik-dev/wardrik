defmodule Wardrik.Triggers.Agents do
  @moduledoc false

  @behaviour Wardrik.Triggers.Target

  alias Wardrik.Operations.Running
  alias Wardrik.Triggers.Target.Ask
  alias Wardrik.Triggers.Target.Fired
  alias Wardrik.Triggers.Target.Secret

  @impl Wardrik.Triggers.Target
  def ask(%Ask{agent: agent_id} = ask, wardrik) do
    case Running.awake(wardrik, agent_id) do
      {:ok, pid} -> overlapped(pid, ask, wardrik)
      {:error, _error} -> :no_agent
    end
  end

  @impl Wardrik.Triggers.Target
  def fired(%Fired{agent: agent_id, trigger: trigger, status: status} = fired, wardrik) do
    data = %{"trigger" => %{"name" => trigger}, "status" => Atom.to_string(status)}
    if fired.last, do: Wardrik.Operations.Triggers.ended(wardrik, agent_id, trigger)

    events = Wardrik.events(wardrik)

    Wardrik.EventLog.append(
      events,
      {agent_id, nil},
      {"trigger.fired", "triggers/" <> trigger, data}
    )
  end

  @impl Wardrik.Triggers.Target
  def resolve_secret(%Secret{}, %Wardrik{vault_keys: []}), do: :error

  # The secret is the principal's the agent's resolver gives. An agent that acts for no one has none.
  def resolve_secret(%Secret{agent: agent_id, name: name}, wardrik) do
    with {:ok, %Wardrik.Resolved{principal: %Wardrik.Principal{} = principal}} <-
           Wardrik.Resolver.defined(wardrik, agent_id),
         vault = Wardrik.vault(wardrik),
         {:ok, secret} <- Wardrik.Vault.fetch(vault, principal, name, kind: :signing_secret) do
      {:ok, secret}
    else
      _none -> :error
    end
  end

  defp overlapped(pid, %Ask{overlap: overlap} = ask, wardrik) do
    case {overlap, WardrikCore.status(pid)} do
      {:queue, _status} -> asked(pid, ask)
      {_overlap, :idle} -> asked(pid, ask)
      {:settle, :waiting} -> settled(pid, ask, wardrik)
      {_overlap, _busy} -> :busy
    end
  end

  # An answer that lands between the status read and the interrupt is cancelled too. The run that
  # waited on it is a whole period old by then.
  defp settled(pid, %Ask{} = ask, wardrik) do
    case WardrikCore.interrupt(pid) do
      :ok -> cancelled(ask, wardrik)
      {:error, :idle} -> :ok
    end

    asked(pid, ask)
  end

  defp cancelled(%Ask{agent: agent_id, trigger: trigger}, wardrik) do
    events = Wardrik.events(wardrik)

    :ok =
      Wardrik.EventLog.record(
        events,
        {"agent.cancelled", Wardrik.EventLog.CloudEvent.subject(agent_id),
         %{"agent" => %{"id" => agent_id}, "trigger" => trigger}}
      )
  end

  defp asked(pid, %Ask{prompt: prompt} = ask) do
    :ok = WardrikCore.ask(pid, prompt, metadata(ask))
    :asked
  end

  defp metadata(%Ask{trigger: trigger, labels: []}), do: %{trigger: trigger}
  defp metadata(%Ask{trigger: trigger, labels: labels}), do: %{trigger: trigger, labels: labels}
end
