defmodule Wardrik.LLM.DispatchTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Context
  alias Wardrik.LLM.Config
  alias Wardrik.LLM.Dispatch
  alias Wardrik.LLM.Request
  alias Wardrik.Scope

  defmodule Routing do
    defstruct [:model]
  end

  defimpl Wardrik.LLM.Dispatch, for: Routing do
    def admit(routing, request, scope: scope) do
      {:ok,
       request
       |> Request.put_model(routing.model)
       |> Request.put_opts(api_key: "key-for-#{Scope.agent_id(scope).org}")}
    end

    def settle(_routing, request, outcome: outcome, scope: scope) do
      send(self(), {:settled, request, outcome, Scope.agent_id(scope).org})
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

  defp scope, do: Scope.root(Config.new(), Wardrik.AgentID.parse!("acme/assistant"))
  defp request, do: Request.new(Config.new(), Context.new())

  describe "Direct" do
    test "admits a request as it stands and is told nothing" do
      direct = %Dispatch.Direct{}

      assert Dispatch.admit(direct, request(), scope: scope()) == {:ok, request()}
      assert Dispatch.settle(direct, request(), outcome: {:error, :nope}, scope: scope()) == :ok
    end

    test "is a host's dispatch where it names none" do
      assert Wardrik.Host.dispatch(Wardrik.Host.new()) == %Dispatch.Direct{}
    end
  end

  describe "a host's dispatch" do
    test "reroutes the call and supplies the key it runs under, from its own settings" do
      routing = %Routing{model: {:anthropic, model: "claude-sonnet-5"}}

      assert {:ok, admitted} = Dispatch.admit(routing, request(), scope: scope())
      assert admitted.model_spec == {:anthropic, model: "claude-sonnet-5"}
      assert admitted.opts[:api_key] == "key-for-acme"

      assert :ok = Dispatch.settle(routing, admitted, outcome: {:error, :nope}, scope: scope())
      assert_received {:settled, ^admitted, {:error, :nope}, "acme"}
    end

    test "can hold another, which decides where the call goes" do
      metered = %Metered{inner: %Routing{model: {:anthropic, model: "claude-sonnet-5"}}}

      assert {:ok, admitted} = Dispatch.admit(metered, request(), scope: scope())
      assert admitted.model_spec == {:anthropic, model: "claude-sonnet-5"}

      assert :ok = Dispatch.settle(metered, admitted, outcome: {:error, :boom}, scope: scope())
      assert_received {:metered, {:error, :boom}}
      assert_received {:settled, ^admitted, {:error, :boom}, "acme"}
    end
  end
end
