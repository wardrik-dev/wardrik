defmodule Wardrik.LLM.ToolRunnerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Wardrik.Call
  alias Wardrik.Event
  alias Wardrik.LLM.Config
  alias Wardrik.LLM.ToolRunner
  alias Wardrik.Scope

  setup do
    agent_id = Wardrik.Test.Fleet.id()
    :ok = Event.Bus.subscribe(agent_id)
    {:ok, agent_id: agent_id}
  end

  defp tool!(name, callback) do
    ReqLLM.Tool.new!(name: name, description: "test tool", callback: callback)
  end

  # A tool handed its context, as `Wardrik.Tool.new!/1` builds one.
  defp handed!(name, handler) do
    Wardrik.Tool.new!(name: name, description: "test tool", run: handler)
  end

  defp scope(agent_id, tools) do
    Config.new(tools: tools) |> Scope.root(agent_id, name: "turn")
  end

  # The shape `ReqLLM.Response.classify/1` actually produces: `:arguments`,
  # already decoded, with string ids.
  defp call(id, name, arguments), do: %{id: id, name: name, arguments: arguments}

  # What the model reads of an answered call.
  defp message(%Call{state: :done} = call), do: hd(ToolRunner.messages([call]))

  describe "a tool that parks" do
    test "stops the turn instead of answering it", %{agent_id: agent_id} do
      tools = [
        handed!("connect", fn _input, _context -> {:park, "Authorize at https://example.com"} end)
      ]

      scope = scope(agent_id, tools)

      assert %Call{
               state: :waiting,
               asks: [%Call.Ask{by: :tool, prompt: "Authorize at https://example.com"}]
             } = ToolRunner.execute(call("call_1", "connect", %{}), scope)
    end

    test "keeps where to authorize apart from the prompt", %{agent_id: agent_id} do
      link = %{url: "https://example.com/device", code: "WDJB-MJHT"}

      tools = [
        handed!("connect", fn _input, _context -> {:park, "Connect it first", link: link} end)
      ]

      parked = ToolRunner.execute(call("call_1", "connect", %{}), scope(agent_id, tools))

      assert Call.prompt(parked) == "Connect it first"
      assert Call.link(parked) == link
      assert [{%{id: "call_1", link: ^link}, "Connect it first"}] = ToolRunner.parked([parked])

      assert_receive %Event{payload: {:tool_parked, "call_1", "connect", "Connect it first"}}
      assert Call.link(Call.park(Call.tool(call("c", "t", %{})), "No link")) == nil
    end

    test "is announced as parked, not as finished", %{agent_id: agent_id} do
      tools = [handed!("connect", fn _input, _context -> {:park, "Authorize first"} end)]

      ToolRunner.execute(call("call_1", "connect", %{}), scope(agent_id, tools))

      assert_receive %Event{payload: {:tool_started, "call_1", "connect", _, _}}
      assert_receive %Event{payload: {:tool_parked, "call_1", "connect", "Authorize first"}}
      refute_receive %Event{payload: {:tool_finished, "call_1", "connect", _result}}
    end

    test "runs again when the call is approved", %{agent_id: agent_id} do
      test = self()

      handler = fn _input, _context ->
        if Process.get(:connected) do
          {:ok, %{"done" => true}}
        else
          send(test, :parked_once)
          Process.put(:connected, true)
          {:park, "Authorize first"}
        end
      end

      scope = scope(agent_id, [handed!("connect", handler)])
      call = call("call_1", "connect", %{})

      assert %Call{id: "call_1", state: :waiting} = waiting = ToolRunner.execute(call, scope)
      assert_receive :parked_once

      assert %Call{state: :done, result: {:ok, %{"done" => true}}} =
               waiting |> Call.approve() |> ToolRunner.execute(scope)
    end

    test "a park without a prompt is a bug in the tool, and the model is told", %{
      agent_id: agent_id
    } do
      tools = [tool!("odd", fn _input -> {:park, :not_a_prompt} end)]

      done = ToolRunner.execute(call("call_1", "odd", %{}), scope(agent_id, tools))

      [part] = message(done).content
      assert part.text =~ "Tool answered with"
    end
  end

  describe "execute_many_async/2" do
    test "executes multiple known tools and publishes progress", %{agent_id: agent_id} do
      tools = [
        tool!("echo", fn input -> {:ok, input} end),
        tool!("reverse", fn %{"input" => input} -> {:ok, String.reverse(input)} end)
      ]

      calls = [
        call("call_1", "echo", %{"input" => "Hello"}),
        call("call_2", "reverse", %{"input" => "World"})
      ]

      messages =
        calls |> ToolRunner.execute_many_async(scope(agent_id, tools)) |> ToolRunner.messages()

      assert_receive %Event{payload: {:tool_started, "call_1", "echo", _, _}}

      assert_receive %Event{
        payload: {:tool_finished, "call_1", "echo", {:ok, %{"input" => "Hello"}}}
      }

      assert_receive %Event{payload: {:tool_started, "call_2", "reverse", _, _}}
      assert_receive %Event{payload: {:tool_finished, "call_2", "reverse", {:ok, "dlroW"}}}

      assert Enum.map(messages, & &1.tool_call_id) == ["call_1", "call_2"]
      assert Enum.map(messages, & &1.name) == ["echo", "reverse"]
      assert Enum.all?(messages, &(&1.role == :tool))
    end

    test "answers an unknown tool with an error result rather than raising", %{
      agent_id: agent_id
    } do
      calls = [call("call_1", "nope", %{})]

      assert [message] =
               calls
               |> ToolRunner.execute_many_async(scope(agent_id, []))
               |> ToolRunner.messages()

      assert_receive %Event{
        payload: {:tool_finished, "call_1", "nope", {:error, "Unknown tool: nope"}}
      }

      assert message.tool_call_id == "call_1"
      assert message.metadata.is_error
    end

    test "a crashing tool is isolated and still yields a paired result", %{agent_id: agent_id} do
      tools = [tool!("boom", fn _ -> exit(:kaboom) end)]
      calls = [call("call_1", "boom", %{})]

      {[message], _log} =
        with_log(fn ->
          calls |> ToolRunner.execute_many_async(scope(agent_id, tools)) |> ToolRunner.messages()
        end)

      assert message.tool_call_id == "call_1"
      assert message.name == "boom"
      assert message.metadata.is_error
    end

    test "a schema violation tells the model what was expected", %{agent_id: agent_id} do
      tools = [
        ReqLLM.Tool.new!(
          name: "pick",
          description: "test tool",
          parameter_schema: [colour: [type: {:in, ["red", "blue"]}]],
          callback: fn input -> {:ok, input} end
        )
      ]

      [message] =
        [call("call_1", "pick", %{"colour" => "green"})]
        |> ToolRunner.execute_many_async(scope(agent_id, tools))
        |> ToolRunner.messages()

      [part] = message.content
      %{"error" => error} = JSON.decode!(part.text)

      assert message.metadata.is_error
      assert error =~ ~s(expected one of ["red", "blue"])
      refute error =~ "stacktrace"
    end

    test "a non-string error reason is inspected into the result", %{agent_id: agent_id} do
      tools = [tool!("boom", fn _ -> {:error, %RuntimeError{message: "nope"}} end)]

      assert [message] =
               [call("call_1", "boom", %{})]
               |> ToolRunner.execute_many_async(scope(agent_id, tools))
               |> ToolRunner.messages()

      assert message.tool_call_id == "call_1"
      assert message.metadata.is_error
    end

    test "results come back in call order even when tools finish out of order", %{
      agent_id: agent_id
    } do
      test_pid = self()

      tools = [
        tool!("waiter", fn _ ->
          send(test_pid, {:waiting, self()})
          receive do: (:go -> {:ok, "waiter"})
        end),
        tool!("runner", fn _ ->
          send(test_pid, :runner_done)
          {:ok, "runner"}
        end)
      ]

      calls = [call("call_1", "waiter", %{}), call("call_2", "runner", %{})]

      task =
        Task.async(fn ->
          calls |> ToolRunner.execute_many_async(scope(agent_id, tools)) |> ToolRunner.messages()
        end)

      # call_2's tool completes first; call_1's is still blocked. Any ordering
      # by completion rather than by call would put call_2 first.
      assert_receive {:waiting, waiter}
      assert_receive :runner_done
      send(waiter, :go)

      messages = Task.await(task)

      assert Enum.map(messages, & &1.tool_call_id) == ["call_1", "call_2"]
      assert Enum.map(messages, & &1.name) == ["waiter", "runner"]
    end

    test "events reach every subscriber", %{agent_id: agent_id} do
      test_pid = self()

      spawn_link(fn ->
        Event.Bus.subscribe(agent_id)
        send(test_pid, :ready)

        receive do: (%Event{payload: {:tool_started, _, _, _, _}} = e ->
                       send(test_pid, {:other, e}))
      end)

      assert_receive :ready
      assert [_, _] = Event.Bus.subscribers(agent_id)

      tools = [tool!("echo", fn input -> {:ok, input} end)]
      ToolRunner.execute_many_async([call("call_1", "echo", %{})], scope(agent_id, tools))

      assert_receive %Event{payload: {:tool_started, "call_1", "echo", _, _}}
      assert_receive {:other, %Event{payload: {:tool_started, "call_1", "echo", _, _}}}
    end
  end

  describe "timeout/2" do
    test "defaults when no tool declares one", %{agent_id: agent_id} do
      scope = scope(agent_id, [tool!("echo", fn i -> {:ok, i} end)])

      assert ToolRunner.timeout([call("c1", "echo", %{})], scope) == :timer.seconds(60)
    end

    test "takes what the config declares for a named tool", %{agent_id: agent_id} do
      config =
        Config.new(
          tools: [tool!("slow", fn i -> {:ok, i} end)],
          tool_timeouts: %{"slow" => :timer.minutes(10)}
        )

      scope = Scope.root(config, agent_id, name: "turn")

      assert ToolRunner.timeout([call("c1", "slow", %{})], scope) == :timer.minutes(10)
    end

    test "a batch runs under the longest of its calls", %{agent_id: agent_id} do
      config =
        Config.new(
          tools: [tool!("slow", fn i -> {:ok, i} end), tool!("echo", fn i -> {:ok, i} end)],
          tool_timeouts: %{"slow" => :timer.minutes(10)}
        )

      scope = Scope.root(config, agent_id, name: "turn")
      calls = [call("c1", "echo", %{}), call("c2", "slow", %{})]

      assert ToolRunner.timeout(calls, scope) == :timer.minutes(10)
    end

    test "an empty batch still has one", %{agent_id: agent_id} do
      assert ToolRunner.timeout([], scope(agent_id, [])) == :timer.seconds(60)
    end
  end

  describe "spans" do
    test "each call runs on its own child span of the turn", %{agent_id: agent_id} do
      tools = [tool!("echo", fn input -> {:ok, input} end)]

      calls = [call("call_1", "echo", %{}), call("call_2", "echo", %{})]
      turn = scope(agent_id, tools)

      ToolRunner.execute_many_async(calls, turn)

      assert_receive %Event{payload: {:tool_started, "call_1", "echo", _, _}} = one
      assert_receive %Event{payload: {:tool_started, "call_2", "echo", _, _}} = two

      for event <- [one, two] do
        refute Event.root?(event)
        assert event.source.trace.trace_id == turn.source.trace.trace_id
        assert event.source.trace.parent_span_id == turn.source.trace.span_id
        assert event.source.trace.name == "echo"
      end

      assert one.source.trace.span_id != two.source.trace.span_id
    end

    test "a call's start and finish share one span", %{agent_id: agent_id} do
      tools = [tool!("echo", fn input -> {:ok, input} end)]

      ToolRunner.execute(call("call_1", "echo", %{}), scope(agent_id, tools))

      assert_receive %Event{payload: {:tool_started, "call_1", "echo", _, _}} = started
      assert_receive %Event{payload: {:tool_finished, "call_1", "echo", _}} = finished

      assert started.source.trace.span_id == finished.source.trace.span_id
    end

    test "a call announces both ends of its span", %{agent_id: agent_id} do
      tools = [tool!("echo", fn input -> {:ok, input} end)]
      turn = scope(agent_id, tools)

      ToolRunner.execute(call("call_1", "echo", %{}), turn)

      assert_receive %Event{payload: {:span_started, "echo"}} = started
      assert_receive %Event{payload: {:span_finished, :ok, _ms}} = finished

      assert started.source.trace.span_id == finished.source.trace.span_id
      assert started.source.trace.parent_span_id == turn.source.trace.span_id
    end

    test "a failing tool closes its span as a failure", %{agent_id: agent_id} do
      tools = [tool!("boom", fn _input -> {:error, :nope} end)]

      ToolRunner.execute(call("call_1", "boom", %{}), scope(agent_id, tools))

      assert_receive %Event{payload: {:span_finished, {:error, :nope}, _ms}}
    end

    test "a tool that reports its own failure closes its span as a failure", %{
      agent_id: agent_id
    } do
      tools = [tool!("search", fn _input -> Wardrik.Tool.Result.error(:missing_api_key) end)]

      done = ToolRunner.execute(call("call_1", "search", %{}), scope(agent_id, tools))

      assert_receive %Event{payload: {:span_finished, {:error, _reason}, _ms}}

      # The model still gets a successful tool result saying the call failed.
      refute message(done).metadata[:is_error]
    end

    test "a tool that succeeds closes its span as a success", %{agent_id: agent_id} do
      tools = [tool!("search", fn input -> Wardrik.Tool.Result.ok(input) end)]

      ToolRunner.execute(call("call_1", "search", %{}), scope(agent_id, tools))

      assert_receive %Event{payload: {:span_finished, :ok, _ms}}
    end

    test "a crashing call still closes its span", %{agent_id: agent_id} do
      tools = [tool!("boom", fn _input -> exit(:kaboom) end)]

      with_log(fn ->
        [call("call_1", "boom", %{})]
        |> ToolRunner.execute_many_async(scope(agent_id, tools))
        |> ToolRunner.messages()
      end)

      assert_receive %Event{payload: {:span_started, "boom"}} = started
      assert_receive %Event{payload: {:span_finished, {:error, :kaboom}, _ms}} = finished

      assert started.source.trace.span_id == finished.source.trace.span_id
    end
  end

  describe "execute/2" do
    test "returns a canonical tool-result message", %{agent_id: agent_id} do
      tools = [tool!("echo", fn input -> {:ok, input} end)]

      message =
        call("call_1", "echo", %{"a" => 1})
        |> ToolRunner.execute(scope(agent_id, tools))
        |> message()

      assert_receive %Event{payload: {:tool_started, "call_1", "echo", _, _}}
      assert_receive %Event{payload: {:tool_finished, "call_1", "echo", {:ok, %{"a" => 1}}}}
      assert message.role == :tool
      assert message.tool_call_id == "call_1"
      assert message.name == "echo"
    end
  end

  defmodule AskingHook do
    @behaviour Wardrik.Hook

    @impl true
    def init(_opts), do: nil

    @impl true
    def call(%Call{target: %Call.Tool{name: "deploy"}}, _value),
      do: {:ask, "This ships to production."}

    def call(%Call{target: %Call.Tool{name: "drop"}}, _value), do: {:deny, "Never."}
    def call(_call, _value), do: :pass
  end

  defp governed(agent_id, tools) do
    Config.new(tools: tools)
    |> Scope.root(agent_id, name: "turn", hooks: [Wardrik.Hook.new("asking", AskingHook)])
  end

  describe "governance" do
    test "an allowed call runs as though no policy were there", %{agent_id: agent_id} do
      tools = [tool!("echo", fn input -> {:ok, input} end)]
      calls = [call("call_1", "echo", %{"a" => 1})]

      assert [%Call{state: :done} = done] =
               ToolRunner.execute_many_async(calls, governed(agent_id, tools))

      assert message(done).tool_call_id == "call_1"
      assert_receive %Event{payload: {:tool_started, "call_1", "echo", _, _}}
    end

    test "a denied call never runs and the model is told why", %{agent_id: agent_id} do
      test_pid = self()
      tools = [tool!("drop", fn _ -> send(test_pid, :ran) && {:ok, %{}} end)]
      calls = [call("call_1", "drop", %{})]

      assert [%Call{state: :done, denied: %Call.Denial{by: "asking"}} = done] =
               ToolRunner.execute_many_async(calls, governed(agent_id, tools))

      refute_receive :ran
      assert_receive %Event{payload: {:tool_denied, "call_1", "drop", "Never."}}

      [part] = message(done).content
      assert %{"ok" => false, "error" => %{"message" => "Never."}} = JSON.decode!(part.text)
    end

    test "a denial closes its span as a failure so a surface can see it", %{agent_id: agent_id} do
      tools = [tool!("drop", fn _ -> {:ok, %{}} end)]

      ToolRunner.execute_many_async([call("call_1", "drop", %{})], governed(agent_id, tools))

      assert_receive %Event{payload: {:span_finished, {:error, _reason}, _ms}}
    end

    test "an asked call parks instead of running", %{agent_id: agent_id} do
      test_pid = self()
      tools = [tool!("deploy", fn _ -> send(test_pid, :ran) && {:ok, %{}} end)]
      calls = [call("call_1", "deploy", %{})]

      assert [%Call{state: :waiting, asks: [%Call.Ask{by: "asking"}]} = parked_call] =
               ToolRunner.execute_many_async(calls, governed(agent_id, tools))

      refute_receive :ran
      assert parked_call.id == "call_1"
      assert parked_call.scope == nil
      assert_receive %Event{payload: {:tool_parked, "call_1", "deploy", _prompt}}
    end

    test "a batch reports each call's own outcome", %{agent_id: agent_id} do
      tools = [
        tool!("echo", fn input -> {:ok, input} end),
        tool!("deploy", fn _ -> {:ok, %{}} end),
        tool!("drop", fn _ -> {:ok, %{}} end)
      ]

      calls = [
        call("call_1", "echo", %{"a" => 1}),
        call("call_2", "deploy", %{}),
        call("call_3", "drop", %{})
      ]

      outcomes = ToolRunner.execute_many_async(calls, governed(agent_id, tools))

      assert [%Call{state: :done}, %Call{state: :waiting}, %Call{state: :done}] = outcomes
      assert [{%{id: "call_2"}, "This ships to production."}] = ToolRunner.parked(outcomes)
    end

    test "messages/1 refuses to invent a result for a parked call", %{agent_id: agent_id} do
      tools = [tool!("deploy", fn _ -> {:ok, %{}} end)]

      outcomes =
        ToolRunner.execute_many_async([call("call_1", "deploy", %{})], governed(agent_id, tools))

      assert_raise ArgumentError, ~r/call_1.*parked/, fn -> ToolRunner.messages(outcomes) end
    end

    test "an approved call runs without the hooks being asked again", %{agent_id: agent_id} do
      tools = [tool!("deploy", fn input -> {:ok, input} end)]

      assert %Call{state: :waiting} =
               waiting =
               ToolRunner.execute(call("call_1", "deploy", %{}), governed(agent_id, tools))

      assert %Call{state: :done} =
               done = waiting |> Call.approve() |> ToolRunner.execute(governed(agent_id, tools))

      assert message(done).tool_call_id == "call_1"
    end
  end

  describe "what a tool says about a call" do
    alias Wardrik.Test.Tools.Deploy
    alias Wardrik.Test.Tools.Fetch
    alias Wardrik.Test.Tools.Rules

    defmodule Reporting do
      @behaviour Wardrik.Hook

      @impl true
      def init(test_pid), do: test_pid

      @impl true
      def call(call, test_pid) do
        send(test_pid, {:hooked, call.target})
        :pass
      end
    end

    defmodule Refusing do
      @behaviour Wardrik.Hook

      @impl true
      def init(_opts), do: nil

      @impl true
      def call(_call, _value), do: {:deny, "Not now."}
    end

    defp under(agent_id, tools, hooks),
      do: Config.new(tools: tools) |> Scope.root(agent_id, name: "turn", hooks: hooks)

    test "is on the call before any hook reads it", %{agent_id: agent_id} do
      scope = under(agent_id, [Deploy], [Wardrik.Hook.new("reporting", Reporting, self())])

      ToolRunner.execute_many_async([call("call_1", "deploy", %{"target" => "prod"})], scope)

      assert_receive {:hooked, %Call.Tool{gated: true, subjects: ["prod"]}}
    end

    test "a gated call runs only where a hook allows it by name", %{agent_id: agent_id} do
      calls = [call("call_1", "deploy", %{"target" => "prod"})]

      assert [%Call{state: :waiting, asks: [%Call.Ask{by: :tool}]}] =
               ToolRunner.execute_many_async(calls, under(agent_id, [Deploy], []))

      refute_receive %Event{payload: {:tool_started, "call_1", _, _, _}}

      allowing = [Wardrik.Hook.new("rules", Rules, allow: ["deploy"])]

      assert [%Call{state: :done, result: {:ok, %{"deployed" => "prod"}}}] =
               ToolRunner.execute_many_async(calls, under(agent_id, [Deploy], allowing))
    end

    test "an answer from outside taints its call, and a refused call is not", %{
      agent_id: agent_id
    } do
      scope = under(agent_id, [Fetch, Deploy], [])

      assert [%Call{state: :done, tainted: true}, %Call{state: :waiting, tainted: false}] =
               ToolRunner.execute_many_async(
                 [call("call_1", "fetch", %{}), call("call_2", "deploy", %{})],
                 scope
               )

      refused = %{scope | hooks: [Wardrik.Hook.new("no", Refusing)]}

      assert [%Call{state: :done, tainted: false}] =
               ToolRunner.execute_many_async([call("call_3", "fetch", %{})], refused)
    end

    test "a tool handed its context can answer with content from outside", %{agent_id: agent_id} do
      tool =
        handed!("read_inbox", fn _input, _context -> {:ok, %{"mail" => "hi"}, outside: true} end)

      assert [%Call{state: :done, tainted: true}] =
               ToolRunner.execute_many_async(
                 [call("call_1", "read_inbox", %{})],
                 scope(agent_id, [tool])
               )
    end
  end

  describe "a tool handed its context" do
    test "reads the call and the run it is part of" do
      tool =
        handed!("whoami", fn _input, %Wardrik.Tool.Context{} = context ->
          {:ok,
           %{
             "id" => context.call_id,
             "key" => context.idempotency_key,
             "user" => Wardrik.Scope.agent_id(context.scope).user
           }}
        end)

      scope = scope(Wardrik.AgentID.new!("whoami", org: "test", user: "jon"), [tool])
      call = call("call_1", "whoami", %{})
      key = Wardrik.Ledger.idempotency_key(scope, call)

      assert %Call{
               state: :done,
               result: {:ok, %{"id" => "call_1", "key" => ^key, "user" => "jon"}}
             } =
               ToolRunner.execute(call, scope)
    end
  end

  describe "a tool whose annotations name credentials" do
    defmodule Vault do
      @behaviour Wardrik.Credential

      @impl true
      def resolve("github", %Call{
            scope: %Scope{source: %{agent_id: %Wardrik.AgentID{user: "jon"}}}
          }),
          do: {:ok, Wardrik.Credential.secret("ghp_x", owner: "jon")}

      def resolve("github", %Call{
            scope: %Scope{source: %{agent_id: %Wardrik.AgentID{user: "new"}}}
          }),
          do: {:error, {:authorization_required, %{url: "https://example.com/authorize"}, "new"}}

      def resolve("github", %Call{
            scope: %Scope{source: %{agent_id: %Wardrik.AgentID{user: "device"}}}
          }),
          do:
            {:error,
             {:authorization_required, %{url: "https://example.com/device", code: "WDJB"},
              "device"}}

      def resolve("github", %Call{
            scope: %Scope{source: %{agent_id: %Wardrik.AgentID{user: "later"}}}
          }) do
        if Process.get(:authorized),
          do: {:ok, Wardrik.Credential.secret("ghp_later", owner: "later")},
          else:
            {:error, {:authorization_required, %{url: "https://example.com/authorize"}, "later"}}
      end

      def resolve("github", %Call{
            scope: %Scope{source: %{agent_id: %Wardrik.AgentID{user: "stale"}}}
          }) do
        token = if Process.get(:refreshed), do: "ghp_fresh", else: "ghp_stale"
        {:ok, Wardrik.Credential.secret(token, owner: "stale")}
      end

      def resolve("github", %Call{
            scope: %Scope{source: %{agent_id: %Wardrik.AgentID{user: "revoked"}}}
          }),
          do: {:ok, Wardrik.Credential.secret("ghp_stale", owner: "revoked")}

      def resolve(_ref, _call), do: {:error, :denied}

      @impl true
      def refused("github", %Call{
            scope: %Scope{source: %{agent_id: %Wardrik.AgentID{user: user}}}
          }) do
        send(self(), {:refused, user})
        Process.put(:refreshed, true)
        :ok
      end
    end

    defmodule Needing do
      @behaviour Wardrik.Tool

      @impl true
      def tool do
        Wardrik.Tool.new!(
          name: "issues",
          description: "Searches issues.",
          parameter_schema: [],
          run: {__MODULE__, :run}
        )
      end

      @impl true
      def annotations(_name), do: %{credentials: ["github"]}

      def run(_input, %Wardrik.Tool.Context{credentials: %{"github" => credential}}) do
        case Wardrik.Credential.reveal(credential) do
          "ghp_stale" -> {:refused, "github"}
          token -> {:ok, %{"token" => token}}
        end
      end
    end

    defp needing(agent_id, user) do
      id = Wardrik.AgentID.new!(agent_id.name, org: agent_id.org, user: user)
      :ok = Wardrik.Event.Bus.subscribe(id)
      Scope.root(Config.new(tools: [Needing]), id, name: "turn", credentials: Vault)
    end

    test "is handed them resolved for the call's user, and keeps none", %{agent_id: agent_id} do
      assert %Call{state: :done, result: {:ok, %{"token" => "ghp_x"}}} =
               done = ToolRunner.execute(call("call_1", "issues", %{}), needing(agent_id, "jon"))

      assert done.private[:wardrik_credentials] == nil
    end

    test "parks on the link where the user has yet to authorize, the code kept apart", %{
      agent_id: agent_id
    } do
      assert %Call{state: :waiting, asks: [%Call.Ask{by: :tool, prompt: prompt, link: link}]} =
               parked =
               ToolRunner.execute(call("call_1", "issues", %{}), needing(agent_id, "new"))

      assert prompt ==
               "To use issues, connect github at its link. This carries on once it is connected."

      assert link == %{url: "https://example.com/authorize", code: nil}
      assert_receive %Event{payload: {:tool_parked, "call_1", "issues", ^prompt}}

      assert Call.awaits?(parked, "github", "new")
      refute Call.awaits?(parked, "github", "device")
      refute Call.awaits?(parked, "linear", "new")

      assert %Call{asks: [%{link: %{url: "https://example.com/device", code: "WDJB"}}]} =
               ToolRunner.execute(call("call_2", "issues", %{}), needing(agent_id, "device"))
    end

    test "runs once the user has authorized, when the parked call is approved", %{
      agent_id: agent_id
    } do
      Process.delete(:authorized)
      scope = needing(agent_id, "later")

      assert %Call{state: :waiting} =
               parked = ToolRunner.execute(call("call_1", "issues", %{}), scope)

      Process.put(:authorized, true)

      assert %Call{state: :done, result: {:ok, %{"token" => "ghp_later"}}} =
               parked |> Call.approve() |> ToolRunner.execute(scope)
    end

    test "is answered with why where none can be resolved", %{agent_id: agent_id} do
      assert %Call{state: :done, result: {:ok, %{"ok" => false, "error" => error}}} =
               ToolRunner.execute(call("call_1", "issues", %{}), needing(agent_id, "nobody"))

      assert error["code"] == "not_authorized"
      assert error["message"] =~ "issues needs github"

      resolving_nothing = %{needing(agent_id, "jon") | credentials: nil}

      assert %Call{result: {:ok, %{"error" => %{"message" => message}}}} =
               ToolRunner.execute(call("call_2", "issues", %{}), resolving_nothing)

      assert message =~ "resolves no credentials"
    end

    test "one the tool reports refused is resolved afresh, and the tool run once more", %{
      agent_id: agent_id
    } do
      Process.delete(:refreshed)

      assert %Call{state: :done, result: {:ok, %{"token" => "ghp_fresh"}}} =
               ToolRunner.execute(call("call_1", "issues", %{}), needing(agent_id, "stale"))

      assert_received {:refused, "stale"}
    end

    test "refused twice, the call is answered as not authorized", %{agent_id: agent_id} do
      assert %Call{state: :done, result: {:ok, %{"ok" => false, "error" => error}}} =
               ToolRunner.execute(call("call_1", "issues", %{}), needing(agent_id, "revoked"))

      assert error["message"] =~ "github is no longer valid"
    end
  end

  describe "refuse/3" do
    test "answers the model the way a policy denial does", %{agent_id: agent_id} do
      scope = scope(agent_id, [])

      assert %Call{state: :done, denied: %Call.Denial{by: :person}} =
               done = ToolRunner.refuse(call("call_1", "deploy", %{}), scope, "Not this quarter.")

      assert_receive %Event{payload: {:tool_denied, "call_1", "deploy", "Not this quarter."}}
      assert message(done).tool_call_id == "call_1"

      [part] = message(done).content

      assert %{"ok" => false, "error" => %{"message" => "Not this quarter."}} =
               JSON.decode!(part.text)
    end
  end

  describe "stopping one call" do
    test "kill_call/2 ends a running call and still answers the model", %{agent_id: agent_id} do
      test_pid = self()

      tools = [
        tool!("hang", fn _ ->
          send(test_pid, :started)
          receive do: (:never -> {:ok, %{}})
        end),
        tool!("echo", fn input -> {:ok, input} end)
      ]

      calls = [call("call_1", "hang", %{}), call("call_2", "echo", %{"a" => 1})]
      task = Task.async(fn -> ToolRunner.execute_many_async(calls, scope(agent_id, tools)) end)

      assert_receive :started, 1_000
      assert ToolRunner.kill_call(agent_id, "call_1") == :ok

      assert [killed, echoed] = task |> Task.await(5_000) |> ToolRunner.messages()
      assert killed.metadata.is_error
      assert killed.tool_call_id == "call_1"
      refute echoed.metadata[:is_error]
    end

    test "a call nobody is running cannot be killed", %{agent_id: agent_id} do
      assert ToolRunner.kill_call(agent_id, "call_nope") == {:error, :not_found}
    end

    test "in_flight/1 lists what could be stopped, and only for this agent", %{agent_id: agent_id} do
      test_pid = self()

      tools = [
        tool!("hang", fn _ ->
          send(test_pid, :started)
          receive do: (:never -> {:ok, %{}})
        end)
      ]

      task =
        Task.async(fn ->
          ToolRunner.execute_many_async([call("call_1", "hang", %{})], scope(agent_id, tools))
        end)

      assert_receive :started, 1_000

      assert [%{call_id: "call_1", name: "hang", pid: pid}] = ToolRunner.in_flight(agent_id)
      assert is_pid(pid)
      assert ToolRunner.in_flight(Wardrik.Test.Fleet.id()) == []

      Task.shutdown(task, :brutal_kill)
    end

    test "nothing is in flight once a batch has settled", %{agent_id: agent_id} do
      tools = [tool!("echo", fn input -> {:ok, input} end)]

      ToolRunner.execute_many_async([call("call_1", "echo", %{})], scope(agent_id, tools))

      assert ToolRunner.in_flight(agent_id) == []
    end
  end

  describe "timeout/2 against a deadline" do
    test "never gives a batch longer than its scope has left", %{agent_id: agent_id} do
      calls = [call("call_1", "echo", %{})]

      scope =
        Config.new(tools: [], tool_timeouts: %{"echo" => :timer.minutes(10)})
        |> Scope.root(agent_id, name: "turn", timeout: 1_000)

      assert ToolRunner.timeout(calls, scope) <= 1_000
    end

    test "a batch admitted with nothing left still gets a moment to answer", %{agent_id: agent_id} do
      calls = [call("call_1", "echo", %{})]
      scope = Config.new() |> Scope.root(agent_id, name: "turn", timeout: 0)

      assert ToolRunner.timeout(calls, scope) == 1
    end
  end
end
