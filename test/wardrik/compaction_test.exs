defmodule Wardrik.CompactionTest do
  use ExUnit.Case, async: true
  use Mimic

  import Wardrik.Test.LLM

  alias Wardrik.Compaction
  alias WardrikCore.Context

  @opts [window: 100]

  setup context do
    stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)
    test = self()

    :telemetry.attach(
      context.test,
      [:wardrik, :conversation, :compacted],
      fn _name, _measurements, metadata, _config -> send(test, {:compacted, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(context.test) end)
    :ok
  end

  defp turn(messages, fields \\ []) do
    struct!(
      Context.new(
        agent_id: "acme/digest",
        model: "anthropic:claude-haiku-4-5",
        step: :turn,
        span: WardrikCore.Span.root(),
        messages: messages
      ),
      fields
    )
  end

  defp run(context, opts \\ @opts), do: Compaction.call(context, &{:ok, &1}, opts)

  defp history do
    [
      ReqLLM.Context.user(String.duplicate("a", 100), %{labels: ["outside"]}),
      ReqLLM.Context.assistant(String.duplicate("b", 100)),
      ReqLLM.Context.user(String.duplicate("c", 100)),
      ReqLLM.Context.assistant(String.duplicate("d", 100)),
      ReqLLM.Context.user("What now?")
    ]
  end

  test "summarises the older turns once the history passes at, keeping the latest word for word" do
    test = self()
    summary = %{answer("They talked.") | usage: %{input_tokens: 100, output_tokens: 3}}

    expect(ReqLLM, :stream_text, fn _model, [system | older], [tools: []] ->
      send(test, {:summarising, system, older})
      {:ok, summary}
    end)

    assert {:ok, compacted} = run(turn(history()))

    assert_receive {:summarising, %{role: :system}, older}
    assert older == Enum.take(history(), 4)

    assert [%{role: :user, content: [%{text: text}]}, %{role: :user} = kept] = compacted.messages
    assert text =~ "They talked."
    assert Context.labels(compacted) == ["outside"]
    assert kept == List.last(history())
    assert %{input_tokens: 100, output_tokens: 3} = compacted.measurements
    assert compacted.instructions == nil
    assert compacted.step == :turn

    assert_receive {:compacted,
                    %{agent_id: "acme/digest", messages_before: 5, messages_after: 2} = counts}

    assert counts.tokens_before > counts.tokens_after
  end

  test "keeps the latest turn whole, however long it is" do
    expect(ReqLLM, :stream_text, fn _model, _messages, _opts -> {:ok, answer("Earlier.")} end)

    messages = history() ++ [ReqLLM.Context.assistant(String.duplicate("e", 400))]

    assert {:ok, %{messages: [_summary, %{role: :user}, %{role: :assistant}]}} =
             run(turn(messages))
  end

  test "leaves a history under at, a single turn, and a resumed turn be" do
    reject(&ReqLLM.stream_text/3)
    short = [ReqLLM.Context.user("Hi.")]
    assert {:ok, %{messages: ^short}} = run(turn(short))

    one_turn = [ReqLLM.Context.user(String.duplicate("a", 400))]
    assert {:ok, %{messages: ^one_turn}} = run(turn(one_turn))

    resumed = turn(history(), resume: %WardrikCore.Resume{reason: :spend?, input: :approve})
    assert {:ok, %{messages: messages}} = run(resumed)
    assert messages == history()
  end

  test "leaves the history as it was when the summary fails" do
    expect(ReqLLM, :stream_text, fn _model, _messages, _opts -> {:error, :timeout} end)
    assert {:ok, %{messages: messages}} = run(turn(history()))
    assert messages == history()
    refute_received {:compacted, _metadata}
  end

  test "reads the window from the model catalog where it isn't given" do
    reject(&ReqLLM.stream_text/3)
    assert {:ok, %{messages: messages}} = run(turn(history()), [])
    assert messages == history()
  end

  test "is on unless a definition turns it off", context do
    store = Wardrik.Test.Store.new(:"store #{context.test}")
    wardrik = Wardrik.new(name: :"wardrik #{context.test}", store: store)
    start_supervised!({WardrikStore, store})
    start_supervised!({Wardrik, wardrik})
    base = %{"model" => "anthropic:claude-haiku-4-5"}

    assert {:ok, opts} = Wardrik.Definition.resolve(wardrik, "acme/a", base)
    assert {Compaction, []} in opts[:middleware]

    tuned = Map.put(base, "compaction", %{"at" => 0.5, "keep" => 0.2, "window" => 1000})
    assert {:ok, opts} = Wardrik.Definition.resolve(wardrik, "acme/a", tuned)
    assert {Compaction, [at: 0.5, keep: 0.2, window: 1000]} in opts[:middleware]

    assert {:ok, opts} =
             Wardrik.Definition.resolve(wardrik, "acme/a", Map.put(base, "compaction", false))

    refute Enum.any?(opts[:middleware], &match?({Compaction, _opts}, &1))
  end
end
