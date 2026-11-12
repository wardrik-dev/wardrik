defmodule Wardrik.Operations.Changes do
  @moduledoc false

  alias Wardrik.Scope

  @doc """
  Records a change of `:type` to the `:agent`, or `{agent, conversation}`, with any `:data`.
  """
  @spec record(Scope.t(), keyword()) :: :ok
  def record(%Scope{} = scope, args) do
    {agent, conversation} = about(Keyword.fetch!(args, :agent))

    data =
      args
      |> Keyword.get(:data, %{})
      |> Map.put("agent", %{"id" => agent})
      |> Wardrik.Operations.Snapshot.conversation(conversation)

    recorded(
      scope,
      {Keyword.fetch!(args, :type), Wardrik.EventLog.CloudEvent.subject(agent), data}
    )
  end

  defp about({_agent, _conversation} = key), do: key
  defp about(agent), do: {agent, nil}

  @doc "Records a change of `:type` to the deployment's `:subject`."
  @spec record_deployment(Scope.t(), type: String.t(), subject: String.t(), data: map()) :: :ok
  def record_deployment(%Scope{} = scope, args),
    do:
      recorded(
        scope,
        {Keyword.fetch!(args, :type), Keyword.fetch!(args, :subject), Keyword.fetch!(args, :data)}
      )

  defp recorded(%Scope{wardrik: wardrik, principal: principal}, change),
    do: :ok = Wardrik.EventLog.record(Wardrik.events(wardrik), change, actor: principal)
end
