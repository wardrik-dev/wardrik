defmodule Tars.LLM.DispatchTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ReqLLM.Context
  alias Tars.LLM.Config
  alias Tars.LLM.Dispatch
  alias Tars.LLM.Request
  alias Tars.Scope

  defmodule Routing do
    @behaviour Tars.LLM.Dispatch

    @impl true
    def admit(request, scope) do
      {:ok,
       request
       |> Request.put_model({:anthropic, model: "claude-sonnet-5"})
       |> Request.put_opts(api_key: "key-for-#{scope.org}")}
    end

    @impl true
    def settle(request, outcome, scope), do: send(self(), {:settled, request, outcome, scope.org})
  end

  defmodule Refusing do
    @behaviour Tars.LLM.Dispatch
    @impl true
    def admit(_request, _scope), do: {:error, :over_budget}
  end

  defmodule Confused do
    @behaviour Tars.LLM.Dispatch
    @impl true
    def admit(_request, _scope), do: :yes_please
  end

  defmodule BrokenAdmit do
    @behaviour Tars.LLM.Dispatch
    @impl true
    def admit(_request, _scope), do: raise("gateway is down")
  end

  defmodule BrokenSettle do
    @behaviour Tars.LLM.Dispatch
    @impl true
    def admit(request, _scope), do: {:ok, request}
    @impl true
    def settle(_request, _outcome, _scope), do: raise("ledger is down")
  end

  defp scope(dispatch) do
    Scope.root(Config.new(), :assistant, dispatch: dispatch, org: "acme")
  end

  defp request, do: Request.new(Config.new(), Context.new())

  describe "admit/2" do
    test "passes the request through untouched when there is no dispatch" do
      assert Dispatch.admit(scope(nil), request()) == {:ok, request()}
    end

    test "lets a host reroute the call and supply the key it runs under" do
      assert {:ok, admitted} = Dispatch.admit(scope(Routing), request())
      assert admitted.model_spec == {:anthropic, model: "claude-sonnet-5"}
      assert admitted.opts[:api_key] == "key-for-acme"
    end

    test "a refusal is reported as it stands, so the provider is never reached" do
      assert Dispatch.admit(scope(Refusing), request()) == {:error, :over_budget}
    end

    test "an answer that is not a request is an error rather than a crash" do
      assert {:error, {:invalid_admit_result, :yes_please}} =
               Dispatch.admit(scope(Confused), request())
    end

    test "a dispatch that raises fails the call instead of the runtime" do
      assert {:error, {:dispatch_failed, message}} = Dispatch.admit(scope(BrokenAdmit), request())
      assert message =~ "gateway is down"
    end
  end

  describe "settle/3" do
    test "does nothing when there is no dispatch" do
      assert Dispatch.settle(scope(nil), request(), {:error, :nope}) == :ok
    end

    test "reports the outcome with the request that produced it" do
      assert Dispatch.settle(scope(Routing), request(), {:error, :nope}) == :ok
      assert_received {:settled, _request, {:error, :nope}, "acme"}
    end

    test "is optional, so a dispatch that only admits is complete" do
      assert Dispatch.settle(scope(Refusing), request(), {:error, :nope}) == :ok
    end

    test "a failure while booking is logged and does not lose the answer" do
      log =
        capture_log(fn ->
          assert Dispatch.settle(scope(BrokenSettle), request(), {:error, :nope}) == :ok
        end)

      assert log =~ "ledger is down"
    end
  end
end
