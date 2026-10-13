defmodule Wardrik.TriggersTest do
  # The host's triggers module is one for the node, which these tests set.
  use ExUnit.Case, async: false

  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix
  alias Wardrik.Caller
  alias Wardrik.Command
  alias Wardrik.Error
  alias Wardrik.Grant
  alias Wardrik.Operations.Deliver
  alias Wardrik.Principal
  alias Wardrik.Triggers

  # Answers what the test puts in its process as :answer, and tells the test
  # what it was handed; operations run in the test's process.
  defmodule Answering do
    @moduledoc false
    @behaviour Wardrik.Triggers

    @impl true
    def deliver(id, name, request) do
      send(self(), {:deliver, id, name, request})
      Process.get(:answer)
    end
  end

  setup do
    :ignore = Triggers.configure(Answering)
    on_exit(fn -> Triggers.configure(nil) end)
  end

  @agent AgentID.parse!("acme/hooked")

  defp caller(can) do
    {:ok, grant} = Grant.new(Prefix.of(@agent), can)
    Caller.new(Principal.new(:webhook, "acme/hooked//issues"), grant)
  end

  defp deliver(answer, can \\ [:message]) do
    Process.put(:answer, answer)

    Command.run(
      %Deliver{agent: @agent, trigger: "issues", headers: [{"x-id", "1"}], body: "{}"},
      caller(can)
    )
  end

  test "hands the host the request, and says what came of it" do
    assert {:ok, %{"delivery" => %{"status" => "asked"}}} = deliver({:ok, :asked})
    assert_received {:deliver, @agent, "issues", %{headers: [{"x-id", "1"}], body: "{}"}}

    assert {:ok, %{"delivery" => %{"status" => "seen"}}} = deliver({:ok, :seen})
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
    Triggers.configure(nil)
    assert {:error, %Error{type: :unsupported}} = deliver({:ok, :asked})
  end
end
