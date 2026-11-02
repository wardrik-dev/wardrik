defmodule Wardrik.Operations.Changes do
  @moduledoc """
  Records changes made through Wardrik in the audit, with who made them.

      Changes.record(scope, type: "agent.defined", agent: "acme/triage")
  """

  alias Wardrik.Scope

  @doc """
  Records a change of `:type`, such as `\"agent.defined\"`, to the `:agent`, with any `:data`.
  """
  @spec record(Scope.t(), keyword()) :: :ok
  def record(%Scope{} = scope, args) do
    id = Keyword.fetch!(args, :agent)
    data = Keyword.get(args, :data, %{})

    recorded(
      scope,
      {Keyword.fetch!(args, :type), "agents/" <> id, Map.put(data, "agent", %{"id" => id})}
    )
  end

  @doc "Records a change of `:type`, such as `\"server.added\"`, to the `:subject` `:owner` holds."
  @spec record_owned(Scope.t(),
          type: String.t(),
          owner: String.t(),
          subject: String.t(),
          data: map()
        ) ::
          :ok
  def record_owned(%Scope{} = scope, args) do
    data = Map.put(Keyword.fetch!(args, :data), "owner", Keyword.fetch!(args, :owner))
    recorded(scope, {Keyword.fetch!(args, :type), Keyword.fetch!(args, :subject), data})
  end

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
