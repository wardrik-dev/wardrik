defmodule Wardrik.LLM.DispatchTest do
  use ExUnit.Case, async: true

  alias Wardrik.Conversation
  alias Wardrik.LLM.Config
  alias Wardrik.LLM.Dispatch
  alias Wardrik.LLM.Request
  alias Wardrik.Run

  defmodule Routing do
    defstruct [:model]
  end

  defimpl Wardrik.LLM.Dispatch, for: Routing do
    def admit(routing, request, run: run) do
      {:ok,
       request
       |> Request.put_model(routing.model)
       |> Request.put_opts(api_key: "key-for-#{Run.agent_id(run).org}")}
    end

    def settle(_routing, request, outcome: outcome, run: run) do
      send(self(), {:settled, request, outcome, Run.agent_id(run).org})
      :ok
    end
  end

  defmodule Metered do
    defstruct [:inner]
  end

  defimpl Wardrik.LLM.Dispatch, for: Metered do
    def admit(metered, request, opts), do: Dispatch.admit(metered.inner, request, opts)

    def settle(metered, request, opts) do
      send(self(), {:metered, opts[:outcome]})
      Dispatch.settle(metered.inner, request, opts)
    end
  end

  defp run, do: Run.root(Config.new(), Wardrik.AgentID.parse!("acme/assistant"))
  defp request, do: Request.new(Config.new(), Conversation.new())

  describe "Direct" do
    test "admits a request as it stands and is told nothing" do
      direct = %Dispatch.Direct{}

      assert Dispatch.admit(direct, request(), run: run()) == {:ok, request()}
      assert Dispatch.settle(direct, request(), outcome: {:error, :nope}, run: run()) == :ok
    end

    test "is a host's dispatch where it names none" do
      assert Wardrik.Host.dispatch(Wardrik.Host.new()) == %Dispatch.Direct{}
    end
  end

  describe "a host's dispatch" do
    test "reroutes the call and supplies the key it runs under, from its own settings" do
      routing = %Routing{model: {:anthropic, model: "claude-sonnet-5"}}

      assert {:ok, admitted} = Dispatch.admit(routing, request(), run: run())
      assert admitted.model_spec == {:anthropic, model: "claude-sonnet-5"}
      assert admitted.opts[:api_key] == "key-for-acme"

      assert :ok = Dispatch.settle(routing, admitted, outcome: {:error, :nope}, run: run())
      assert_received {:settled, ^admitted, {:error, :nope}, "acme"}
    end

    test "can hold another, which decides where the call goes" do
      metered = %Metered{inner: %Routing{model: {:anthropic, model: "claude-sonnet-5"}}}

      assert {:ok, admitted} = Dispatch.admit(metered, request(), run: run())
      assert admitted.model_spec == {:anthropic, model: "claude-sonnet-5"}

      assert :ok = Dispatch.settle(metered, admitted, outcome: {:error, :boom}, run: run())
      assert_received {:metered, {:error, :boom}}
      assert_received {:settled, ^admitted, {:error, :boom}, "acme"}
    end
  end
end
