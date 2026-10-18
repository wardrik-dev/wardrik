defmodule Wardrik.TriggersTest do
  use ExUnit.Case, async: true

  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix
  alias Wardrik.Error
  alias Wardrik.Grant
  alias Wardrik.Host
  alias Wardrik.Principal
  alias Wardrik.Session

  # Answers what the test puts in its process as :answer, and tells the test
  # what it was handed; the functions run in the test's process.
  defmodule Answering do
    @moduledoc false
    defstruct []

    def deliver(_triggers, id, name, request: request) do
      send(self(), {:deliver, id, name, request})
      Process.get(:answer)
    end
  end

  defimpl Wardrik.Triggers, for: Answering do
    defdelegate deliver(a0, a1, a2, a3), to: Answering
  end

  @agent AgentID.parse!("acme/hooked")

  defp deliver(answer, can \\ [:message], host \\ Host.new(triggers: %Answering{})) do
    Process.put(:answer, answer)
    {:ok, grant} = Grant.new(Prefix.of(@agent), can)
    principal = Principal.new(:webhook, "acme/hooked//issues")
    session = Session.new(host: host, principal: principal, grant: grant)

    Wardrik.agent_trigger_deliver(session, @agent, "issues", %{
      headers: [{"x-id", "1"}],
      body: "{}"
    })
  end

  test "hands the host the request, and says what came of it" do
    assert {:ok, :asked} = deliver({:ok, :asked})
    assert_received {:deliver, @agent, "issues", %{headers: [{"x-id", "1"}], body: "{}"}}

    assert {:ok, :seen} = deliver({:ok, :seen})
  end

  test "answers what the host refuses as an error of its kind" do
    assert {:error, %Error{type: :not_found}} = deliver({:error, :not_found})

    assert {:error, %Error{type: :not_found, message: "acme/hooked has no trigger issues" <> _}} =
             deliver({:error, :forbidden, "bad signature"})

    assert {:error, %Error{type: :unavailable}} = deliver({:error, :unavailable, "busy"})
  end

  test "needs a grant to message the agent" do
    assert {:error, %Error{type: :forbidden}} = deliver({:ok, :asked}, [:read])
    refute_received {:deliver, _id, _name, _request}
  end

  test "is unsupported where the host names no module" do
    assert {:error, %Error{type: :unsupported}} = deliver({:ok, :asked}, [:message], Host.new())
  end
end
