defmodule Wardrik.Test.Wardrik do
  @moduledoc "Starts a Wardrik over an ETS store for a test, and runs its operations."

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [start_supervised!: 1]

  alias WardrikCore.Principal

  def start_wardrik(context) do
    store = Wardrik.Test.Store.new(:"store #{context.test}")

    wardrik =
      Wardrik.new(
        authorizer: {Wardrik.Test.Allow, []},
        name: :"wardrik #{context.test}",
        store: store,
        deployment: "test"
      )

    start_supervised!({WardrikStore, store})
    start_supervised!({Wardrik, wardrik})

    %{wardrik: wardrik, store: store}
  end

  def maria, do: %Principal{id: "acme/@maria", attributes: %{name: "Maria"}}

  def owner(wardrik), do: Wardrik.as(wardrik, maria())

  @roles %{
    reader:
      ~w(agent.read agent.events connection.read mcp_server.read provider.read notify_target.read ceiling.read),
    messenger: ~w(agent.ask agent.cancel agent.clear),
    approver: ~w(agent.decide),
    worker: ~w(agent.serve),
    definer:
      ~w(agent.define agent.spawn agent.stop agent.forget connection.connect mcp_server.add provider.add notify_target.add)
  }

  @doc """
  Returns `principal`'s scope, which `Wardrik.Test.Allow` lets take the actions of `:roles` on
  what `:owners` own, or with `:agents_of`, on those owners' agents alone, as a host's authorizer
  might. It's refused anything else they own, and finds nothing of anyone else's.
  """
  def limited(wardrik, principal, opts) do
    actions = Enum.flat_map(Keyword.fetch!(opts, :roles), &Map.fetch!(@roles, &1))
    reach = Keyword.take(opts, [:owners, :agents_of])
    Wardrik.as(wardrik, principal, context: %{decide: &decide(&1, actions, reach)})
  end

  defp decide(%{action: action, resource: resource}, actions, reach) do
    cond do
      not reaches?(reach, resource) -> {:error, :not_found}
      action in actions -> :ok
      true -> {:error, :forbidden}
    end
  end

  defp reaches?([agents_of: owners], {:agent, _id} = resource),
    do: owned_by(resource) in owners

  defp reaches?([agents_of: _owners], _resource), do: false
  defp reaches?([owners: owners], resource), do: owned_by(resource) in owners

  defp owned_by({:owner, owner}), do: owner
  defp owned_by({:deployment, _name}), do: "deployment"

  defp owned_by({:agent, id}) do
    case Wardrik.AgentID.parse(id) do
      {:ok, %Wardrik.AgentID{owner: owner}} -> owner
      :error -> nil
    end
  end

  def start_agent(wardrik, id) do
    {:ok, agent} =
      Wardrik.start_agent(wardrik,
        agent_id: id,
        model: "anthropic:claude-haiku-4-5",
        capabilities: [Wardrik.Test.Tools],
        middleware: [Wardrik.Test.Approval]
      )

    agent
  end

  @doc "Runs `id`, and checks what it answers against the operation's output schema."
  def run!(scope, id, input) do
    assert {:ok, output} = Wardrik.run(scope, id, input)

    case WardrikProtocol.operation(id).output do
      nil ->
        assert output == nil

      schema ->
        assert {:ok, _output} = JSV.validate(output, JSV.build!(schema)), inspect(output)
    end

    output
  end

  def refused(scope, id, input) do
    assert {:error, %Wardrik.Error{type: type}} = Wardrik.run(scope, id, input)
    type
  end

  def until(type) do
    receive do
      {WardrikEvents, _log, %{"type" => ^type} = event} -> event
      {WardrikEvents, _log, _event} -> until(type)
    after
      1_000 -> flunk("No #{type} came.")
    end
  end
end
