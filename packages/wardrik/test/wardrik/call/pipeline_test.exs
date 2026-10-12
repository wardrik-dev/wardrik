defmodule Wardrik.Call.PipelineTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Context
  alias Wardrik.Call
  alias Wardrik.Call.Pipeline
  alias Wardrik.Event
  alias Wardrik.Ledger
  alias Wardrik.LLM.Config
  alias Wardrik.LLM.Request
  alias Wardrik.LLM.ToolRunner
  alias Wardrik.Scope

  # A hook that answers every call one way, and tells the test what it hears.
  defmodule Saying do
    @behaviour Wardrik.Hook

    @impl true
    def init(answer), do: answer

    @impl true
    def call(_call, answer), do: answer

    @impl true
    def settle(call, _answer), do: send(self(), {:settled, call})
  end

  defmodule Routing do
    @behaviour Wardrik.LLM.Dispatch

    @impl true
    def admit(request, _scope) do
      {:ok,
       request
       |> Request.put_model({:anthropic, model: "claude-sonnet-5"})
       |> Request.put_opts(api_key: "key")}
    end

    @impl true
    def settle(_request, outcome, _scope), do: send(self(), {:dispatch_settled, outcome})
  end

  defmodule Refusing do
    @behaviour Wardrik.LLM.Dispatch
    @impl true
    def admit(_request, _scope), do: {:error, :over_budget}
  end

  # A tool whose worker went away the first time, and that may run again
  # under the same key.
  defmodule Refund do
    @behaviour Wardrik.Tool

    @impl true
    def tool do
      Wardrik.Tool.new!(
        name: "refund",
        description: "Refunds an order, once per key.",
        parameter_schema: [],
        run: {__MODULE__, :run}
      )
    end

    @impl true
    def annotations("refund"), do: %{in_doubt: :rerun}

    def run(_input, %Wardrik.Tool.Context{in_doubt: false, idempotency_key: key}) do
      send(self(), {:ran, false, key})
      {:in_doubt, "The worker went away before it answered.", served_by: %{id: "w1"}}
    end

    def run(_input, %Wardrik.Tool.Context{in_doubt: true, idempotency_key: key}) do
      send(self(), {:ran, true, key})
      {:ok, %{"refunded" => true}, served_by: %{id: "w2", name: "refunds"}}
    end
  end

  # The same, whose worker never answers.
  defmodule Lost do
    @behaviour Wardrik.Tool

    @impl true
    def tool do
      Wardrik.Tool.new!(
        name: "refund",
        description: "Refunds an order, once per key.",
        parameter_schema: [],
        run: {__MODULE__, :run}
      )
    end

    @impl true
    def annotations("refund"), do: %{in_doubt: :rerun}

    def run(_input, %Wardrik.Tool.Context{in_doubt: in_doubt}) do
      send(self(), {:ran, in_doubt})
      {:in_doubt, "No worker answered."}
    end
  end

  setup do
    agent_id = Wardrik.Test.Fleet.id()
    :ok = Event.Bus.subscribe(agent_id)
    {:ok, agent_id: agent_id}
  end

  defp scope(agent_id, opts) do
    {tools, opts} = Keyword.pop(opts, :tools, [])
    Config.new(tools: tools) |> Scope.root(agent_id, [name: "turn"] ++ opts)
  end

  defp saying(answer), do: [Wardrik.Hook.new("saying", Saying, answer)]

  # A tool that answers its context's doubt with `answer`, and tells the test
  # it ran.
  defp tool(name, answer) do
    test = self()

    Wardrik.Tool.new!(
      name: name,
      description: "Does something with an effect.",
      parameter_schema: [],
      run: fn _input, context ->
        send(test, {:ran, name, context.in_doubt})
        answer.(context)
      end
    )
  end

  defp call(scope, id, name), do: Call.tool(%{id: id, name: name, arguments: %{}}, scope)

  defp request, do: Request.new(Config.new(), Context.new())

  defp answering(outcome) do
    fn call ->
      send(self(), {:invoked, Pipeline.request(call)})
      Call.answer(call, outcome)
    end
  end

  defp response(usage),
    do: %ReqLLM.Response{id: "r", model: "m", context: Context.new(), usage: usage}

  describe "a model call" do
    test "is decided by the hooks before the dispatch, which a call that waits never reaches",
         %{agent_id: agent_id} do
      scope = scope(agent_id, hooks: saying({:ask, "Over budget.", :day}), dispatch: Routing)

      assert %Call{state: :waiting, scope: %Scope{}, private: private} =
               waiting =
               request() |> Pipeline.model(scope) |> Pipeline.run(answering({:ok, nil}))

      assert [%Call.Ask{by: "saying", prompt: "Over budget.", memo: :day}] = waiting.asks
      assert private == %{}
      refute_received {:invoked, _request}
      refute_received {:dispatch_settled, _outcome}
    end

    test "a hook refuses before the dispatch", %{agent_id: agent_id} do
      scope = scope(agent_id, hooks: saying({:deny, "No."}), dispatch: Routing)

      assert %Call{state: :denied, denied: %Call.Denial{by: "saying", reason: "No."}} =
               request() |> Pipeline.model(scope) |> Pipeline.run(answering({:ok, nil}))

      refute_received {:invoked, _request}
    end

    test "a person approved goes ahead without the hooks, admitted by the dispatch",
         %{agent_id: agent_id} do
      scope = scope(agent_id, hooks: saying({:ask, "Spend?"}), dispatch: Routing)
      waiting = request() |> Pipeline.model(scope) |> Pipeline.decide()

      approved = Pipeline.answer(waiting, :approve)
      denying = %{scope | hooks: saying({:deny, "No."})}

      assert %Call{state: :done} =
               request()
               |> Pipeline.model(denying, approved)
               |> Pipeline.run(answering({:ok, response(%{input_tokens: 1})}))

      assert_received {:invoked, %Request{opts: opts}}
      assert opts[:api_key] == "key"
      assert Call.decided_by(approved) == %{by: :person, hooks: ["saying"]}
    end

    test "is heard by the dispatch and the hooks, with the model as it was made",
         %{agent_id: agent_id} do
      scope = scope(agent_id, hooks: saying(:pass), dispatch: Routing)
      outcome = {:ok, response(%{input_tokens: 3, output_tokens: 4})}

      request() |> Pipeline.model(scope) |> Pipeline.run(answering(outcome))

      assert_received {:dispatch_settled, ^outcome}

      assert_received {:settled,
                       %Call{
                         state: :done,
                         result: ^outcome,
                         target: %Call.Model{
                           model_spec: {:anthropic, model: "claude-sonnet-5"},
                           usage: %{input_tokens: 3, output_tokens: 4}
                         }
                       }}
    end

    test "the dispatch refuses is answered with why, and never made", %{agent_id: agent_id} do
      scope = scope(agent_id, hooks: saying(:pass), dispatch: Refusing)

      assert %Call{state: :done, result: {:error, :over_budget}} =
               request() |> Pipeline.model(scope) |> Pipeline.run(answering({:ok, nil}))

      refute_received {:invoked, _request}
      refute_received {:settled, _call}
    end

    test "that failed before it was answered is heard by the dispatch alone",
         %{agent_id: agent_id} do
      scope = scope(agent_id, hooks: saying(:pass), dispatch: Routing)

      request() |> Pipeline.model(scope) |> Pipeline.run(answering({:error, :closed}))

      assert_received {:dispatch_settled, {:error, :closed}}
      refute_received {:settled, _call}
    end
  end

  describe "a tool call" do
    test "is heard by every hook once its tool answers it", %{agent_id: agent_id} do
      scope =
        scope(agent_id, hooks: saying(:pass), tools: [tool("echo", fn _ -> {:ok, "hi"} end)])

      assert %Call{state: :done} = scope |> call("call_1", "echo") |> Pipeline.run()

      assert_received {:settled,
                       %Call{state: :done, result: {:ok, "hi"}, target: %Call.Tool{name: "echo"}}}
    end

    test "refused, or answered from the ledger, is heard by no hook", %{agent_id: agent_id} do
      echo = tool("echo", fn _ -> {:ok, "hi"} end)

      scope(agent_id, hooks: saying({:deny, "No."}), tools: [echo])
      |> call("call_1", "echo")
      |> Pipeline.run()

      ledgered = scope(agent_id, tools: [echo], ledger: Ledger.Store)
      ledgered |> call("call_2", "echo") |> Pipeline.run()

      ledgered = %{ledgered | hooks: saying(:pass)}
      assert %Call{state: :done} = ledgered |> call("call_2", "echo") |> Pipeline.run()

      assert_received %Event{payload: {:tool_replayed, "call_2", "echo", {:ok, "hi"}}}
      refute_received {:settled, _call}
    end

    test "names who decided it, and what answered it", %{agent_id: agent_id} do
      served = tool("echo", fn _ -> {:ok, "hi", served_by: %{id: "w1", name: "echoes"}} end)

      scope(agent_id, hooks: saying(:allow), tools: [served])
      |> call("call_1", "echo")
      |> Pipeline.run()

      assert_received %Event{
        payload: {:tool_started, "call_1", "echo", %{}, _key, %{by: :hook, hooks: ["saying"]}}
      }

      assert_received %Event{
        payload: {:tool_finished, "call_1", "echo", {:ok, "hi"}, %{id: "w1", name: "echoes"}, _}
      }

      scope(agent_id, tools: [served]) |> call("call_2", "echo") |> Pipeline.run()

      assert_received %Event{
        payload: {:tool_started, "call_2", "echo", %{}, _key, %{by: :default, hooks: []}}
      }

      scope(agent_id, hooks: saying({:deny, "No."}), tools: [served])
      |> call("call_3", "echo")
      |> Pipeline.run()

      assert_received %Event{
        payload: {:tool_denied, "call_3", "echo", "No.", %{by: :hook, hooks: ["saying"]}}
      }
    end
  end

  describe "a tool call in doubt" do
    test "waits on a person, and keeps its claim so a replay asks too", %{agent_id: agent_id} do
      quiet = tool("refund", fn _ -> {:in_doubt, "The worker went away before it answered."} end)
      scope = scope(agent_id, tools: [quiet], ledger: Ledger.Store)
      call = call(scope, "call_1", "refund")

      assert %Call{state: :waiting, asks: [%Call.Ask{by: :doubt, prompt: prompt}]} =
               waiting = Pipeline.run(call)

      assert prompt =~ "refund may already have done what it does."
      assert prompt =~ "The worker went away before it answered."
      assert_received {:ran, "refund", false}
      assert_received %Event{payload: {:tool_parked, "call_1", "refund", ^prompt}}

      assert {:ok, %Ledger.Entry{result: nil}} =
               Ledger.fetch(Ledger.Store, Ledger.key(scope, Call.to_map(call)))

      assert [{%{in_doubt: true}, ^prompt}] = ToolRunner.parked([waiting])
    end

    test "runs once more under the same key where its tool says it may", %{agent_id: agent_id} do
      scope = scope(agent_id, tools: [Refund], ledger: Ledger.Store)
      call = call(scope, "call_1", "refund")

      assert %Call{state: :done, result: {:ok, %{"refunded" => true}}} = Pipeline.run(call)

      assert_received {:ran, false, key}
      assert_received {:ran, true, ^key}

      assert_received %Event{
        payload: {:tool_finished, "call_1", "refund", {:ok, _}, %{id: "w2", name: "refunds"}, _}
      }

      assert {:ok, %Ledger.Entry{result: {:ok, %{"refunded" => true}}}} =
               Ledger.fetch(Ledger.Store, Ledger.key(scope, Call.to_map(call)))
    end

    test "again waits on a person", %{agent_id: agent_id} do
      scope = scope(agent_id, tools: [Lost])

      assert %Call{state: :waiting, asks: [%Call.Ask{by: :doubt, prompt: prompt}]} =
               scope |> call("call_1", "refund") |> Pipeline.run()

      assert prompt =~ "No worker answered."
      assert_received {:ran, false}
      assert_received {:ran, true}
    end

    test "runs again, told so, once a person approves", %{agent_id: agent_id} do
      quiet =
        tool("refund", fn
          %{in_doubt: true} -> {:ok, %{"refunded" => true}}
          _first -> {:in_doubt, "No worker answered."}
        end)

      scope = scope(agent_id, tools: [quiet])
      waiting = scope |> call("call_1", "refund") |> Pipeline.run()

      assert %Call{state: :done, result: {:ok, %{"refunded" => true}}} =
               waiting |> Call.under(scope) |> Pipeline.answer(:approve) |> Pipeline.run()

      assert_received {:ran, "refund", false}
      assert_received {:ran, "refund", true}

      assert_received %Event{
        payload: {:tool_started, "call_1", "refund", _args, _key, %{by: :person, hooks: []}}
      }
    end

    test "refused tells the model it may have run, with no ledger to say so", %{
      agent_id: agent_id
    } do
      quiet = tool("refund", fn _ -> {:in_doubt, "No worker answered."} end)
      scope = scope(agent_id, tools: [quiet])
      waiting = scope |> call("call_1", "refund") |> Pipeline.run()

      waiting |> Call.under(scope) |> Pipeline.answer({:deny, "Leave it."}) |> Pipeline.run()

      assert_received %Event{
        payload: {:tool_denied, "call_1", "refund", reason, %{by: :person}}
      }

      assert reason =~ "may already have done what it does"
      assert reason =~ "Leave it."
    end
  end
end
