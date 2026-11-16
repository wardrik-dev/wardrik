defmodule Wardrik.DigestTest do
  use ExUnit.Case, async: true

  import Wardrik.Test.LLM
  import Wardrik.Test.Wardrik

  @moduletag :capture_log

  @model "anthropic:claude-haiku-4-5"
  @agent "acme/triage"

  defmodule Outside do
    @moduledoc "Labels each message a person sends `outside`."
    @behaviour Wardrik.Middleware

    @impl true
    def call(%Wardrik.Context{step: :turn, messages: messages} = context, next, _opts),
      do: next.(%{context | messages: Enum.map(messages, &labelled/1)})

    def call(context, next, _opts), do: next.(context)

    defp labelled(%{role: :user} = message),
      do: %{message | metadata: Map.put(message.metadata, :labels, ["outside"])}

    defp labelled(message), do: message
  end

  setup context do
    {fake, endpoints} = Wardrik.Test.Model.start()
    store_name = :"store #{context.test}"
    store = Wardrik.Test.Store.new(store_name)

    wardrik =
      Wardrik.new(
        authorizer: {Wardrik.Test.Allow, []},
        resolver: {Wardrik.Test.Owned, :"wardrik #{context.test}"},
        name: :"wardrik #{context.test}",
        store: store,
        idle_timeout: 0.05,
        middleware: Map.get(context, :middleware, []),
        endpoints: endpoints
      )

    start_supervised!({Wardrik.Store, store})
    start_supervised!({Wardrik, wardrik})
    event_log = Wardrik.events(wardrik)
    :ok = Wardrik.EventLog.subscribe(event_log, :all)
    test = self()

    Wardrik.Testing.Model.answer(fake, fn request ->
      [%{content: [%{text: system} | _]} | _] = messages = Wardrik.Testing.Model.messages(request)

      if String.starts_with?(system, "Write a digest") do
        send(test, {:digesting, messages})
        used(answer("Asked about tea."))
      else
        answer("Tea.")
      end
    end)

    %{wardrik: wardrik, scope: owner(wardrik), fake: fake}
  end

  defp used(response), do: %{response | usage: %{input_tokens: 40, output_tokens: 10}}

  defp define(%{scope: scope} = cx, definition) do
    run!(scope, "agent.define", Map.merge(%{"agent" => @agent, "model" => @model}, definition))
    asleep(cx)
  end

  defp asleep(%{wardrik: wardrik}) do
    case Wardrik.Operations.Running.whereis(wardrik, @agent) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 1_000
    end
  end

  # Asks the sleeping agent, and waits for it to sleep again.
  defp ask(%{scope: scope} = cx, text) do
    run!(scope, "agent.ask", %{"agent" => @agent, "content" => text})
    until("wardrik.run.completed")
    asleep(cx)
  end

  defp digest(scope) do
    case Wardrik.run(scope, "agent.file", %{"agent" => @agent, "path" => "digests/agent.md"}) do
      {:ok, %{"file" => file, "content" => content}} -> {file, content}
      {:error, %Wardrik.Error{type: :not_found}} -> nil
    end
  end

  @tag middleware: [Outside]
  test "writes a digest before the agent sleeps, with the labels and spend of what it read",
       %{scope: scope, wardrik: wardrik} = cx do
    define(cx, %{"tools" => ["files"]})
    refute_received {:digesting, _messages}
    assert digest(scope) == nil

    ask(cx, "Which tea?")
    assert_received {:digesting, [_system, %{role: :user}, %{role: :assistant}]}

    assert {%{"by" => @agent, "labels" => ["outside"]}, content} = digest(scope)

    assert content =~
             ~r/\A---\nconversation: agent\nupdated: .+\nthrough: \S+\n---\n\nAsked about tea.\n\z/

    assert %{"tokens" => 50} = Wardrik.Spending.today(wardrik, @agent)

    assert %{"events" => events} = run!(scope, "audit.list", %{})

    assert %{"data" => %{"file" => %{"path" => "digests/agent.md"}}} =
             Enum.find(events, &(&1["type"] == "wardrik.file.written"))
  end

  test "folds what came since into the digest so far, and writes nothing without it",
       %{scope: scope} = cx do
    define(cx, %{"tools" => ["files"]})
    ask(cx, "Which tea?")
    assert_received {:digesting, _messages}

    ask(cx, "And milk?")
    assert_received {:digesting, [_system, so_far, %{role: :user} = asked, %{role: :assistant}]}

    assert [%{text: "Your digest of this conversation so far:\n\nAsked about tea."}] =
             so_far.content

    assert [%{text: "And milk?"} | _sent] = asked.content

    run!(scope, "agent.spawn", %{"agent" => @agent})
    asleep(cx)
    refute_received {:digesting, _messages}
  end

  test "lets the agent sleep when its digest fails, is off, or has no files to go in",
       %{scope: scope} = cx do
    define(cx, %{"tools" => ["files"]})

    Wardrik.Testing.Model.answer(cx.fake, fn request ->
      [%{content: [%{text: system} | _]} | _] = Wardrik.Testing.Model.messages(request)
      if String.starts_with?(system, "Write a digest"), do: {:status, 400}, else: answer("Tea.")
    end)

    ask(cx, "Which tea?")
    assert digest(scope) == nil

    for definition <- [%{"tools" => ["files"], "digest" => false}, %{}] do
      define(cx, definition)
      ask(cx, "Which tea?")
      assert digest(scope) == nil
    end
  end
end
