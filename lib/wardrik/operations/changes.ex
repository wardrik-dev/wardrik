defmodule Wardrik.Operations.Changes do
  @moduledoc """
  Records changes made through Wardrik in the audit, with who made them.

      Changes.record(scope, type: "agent.defined", agent: "agt_1")
      Changes.record(scope, type: "agent.cleared", agent: {"agt_1", "C1"})
  """

  alias Wardrik.Scope

  @doc """
  Records a change of `:type`, such as `\"agent.defined\"`, to the `:agent`, or to one of its
  conversations as `{agent, conversation}`, with any `:data`.
  """
  @spec record(Scope.t(), keyword()) :: :ok
  def record(%Scope{} = scope, args) do
    {agent, conversation} = about(Keyword.fetch!(args, :agent))

    data =
      args
      |> Keyword.get(:data, %{})
      |> Map.put("agent", %{"id" => agent})
      |> Wardrik.Operations.Snapshot.conversation(conversation)

    recorded(scope, {Keyword.fetch!(args, :type), WardrikEvents.CloudEvent.subject(agent), data})
  end

  defp about({_agent, _conversation} = key), do: key
  defp about(agent), do: {agent, nil}

  @doc "Records a change of `:type`, such as `\"agents.reloaded\"`, to the deployment's `:subject`."
  @spec record_deployment(Scope.t(), type: String.t(), subject: String.t(), data: map()) :: :ok
  def record_deployment(%Scope{} = scope, args),
    do:
      recorded(
        scope,
        {Keyword.fetch!(args, :type), Keyword.fetch!(args, :subject), Keyword.fetch!(args, :data)}
      )

  defp recorded(%Scope{wardrik: wardrik, principal: principal}, change),
    do: :ok = WardrikEvents.record(Wardrik.events(wardrik), change, actor: principal)
end
