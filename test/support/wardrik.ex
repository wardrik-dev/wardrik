defmodule Wardrik.Test.Wardrik do
  @moduledoc "Starts a Wardrik over an ETS store for a test, and runs its operations."

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [start_supervised!: 1]

  alias Wardrik.Statement
  alias WardrikCore.Principal

  def start_wardrik(context) do
    store = Wardrik.Test.Store.new(:"store #{context.test}")
    wardrik = Wardrik.new(name: :"wardrik #{context.test}", store: store, deployment: "test")

    start_supervised!({WardrikStore, store})
    start_supervised!({Wardrik, wardrik})

    %{wardrik: wardrik, store: store}
  end

  def maria, do: %Principal{id: "acme/@maria", attributes: %{name: "Maria"}}

  def owner(wardrik),
    do: Wardrik.as(wardrik, maria(), [Statement.new(roles: [:owner], resources: ["*"])])

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
