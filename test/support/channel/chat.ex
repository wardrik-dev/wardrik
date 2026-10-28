defmodule Wardrik.Test.Channel.Chat do
  @moduledoc "A chat app that sends the test what it's asked to post, and knows people by `@name`."

  use WardrikChannel

  @impl Wardrik.Channel
  def request(_opts, %{body: body}), do: %{status: 200, headers: %{}, body: body}

  @impl WardrikChannel
  def deliver(channel, %{body: {:reply, _text, _answering}} = outbound) do
    refusals = channel.options[:refusals]

    if :counters.get(refusals, 1) > 0 do
      :counters.sub(refusals, 1, 1)
      send(channel.options[:test], {:refused, outbound})
      {:error, :busy}
    else
      delivered(channel, outbound)
    end
  end

  def deliver(channel, outbound), do: delivered(channel, outbound)

  defp delivered(channel, outbound) do
    send(channel.options[:test], {:delivered, outbound})
    :ok
  end

  @impl WardrikChannel
  def include?(_channel, _installation, names, member), do: ("@" <> member.name) in names
end

defmodule Wardrik.Test.Channel.Tools do
  @moduledoc "A capability with one tool, `echo`."
  @behaviour WardrikCore.Capability

  @impl WardrikCore.Capability
  def tools(_context, _opts) do
    [
      WardrikCore.Tool.new!(
        name: "echo",
        description: "Echoes text",
        schema: [text: [type: :string]],
        run: fn args, _context -> {:ok, Map.get(args, :text, "")} end
      )
    ]
  end
end

defmodule Wardrik.Test.Channel do
  @moduledoc "Starts a Wardrik with a chat channel for a test, and stubs the model's answers."

  @doc "Returns the channel the Wardrik `wardrik` runs as `name`, as the Wardrik builds it."
  def fetch(wardrik, name) do
    with {:ok, {adapter, opts}} <- Wardrik.Operations.Channels.fetch(wardrik, name),
         do: {:ok, WardrikChannel.channel(adapter, opts)}
  end

  import ExUnit.Callbacks, only: [start_supervised!: 1]

  @model "anthropic:claude-haiku-4-5"

  def start_wardrik(context) do
    store = WardrikStore.ETS.new(name: :"store #{context.test}")
    name = :"wardrik #{context.test}"
    refusals = :counters.new(1, [])

    chat = [
      token: "xoxb-test",
      owner: "acme",
      approvers: ["@maria"],
      test: self(),
      refusals: refusals
    ]

    start_supervised!({WardrikStore, store})

    start_supervised!(
      {Wardrik,
       Wardrik.new(
         name: name,
         store: store,
         channels: [chat: {Wardrik.Test.Channel.Chat, chat}],
         capabilities: [tools: Wardrik.Test.Channel.Tools],
         policies: [careful: [ask: ["echo"]]],
         defaults: %{"retries" => %{"attempts" => 0, "on_exhausted" => "fail"}}
       )}
    )

    {:ok, channel} = fetch(name, "chat")

    {:ok, workspace} = WardrikChannel.workspace(channel, "T1")
    owner = Wardrik.as(name, "acme/@maria", roles: [:owner], resources: ["*"])

    %{
      wardrik: name,
      store: store,
      channel: channel,
      workspace: workspace,
      owner: owner,
      refusals: refusals
    }
  end

  def define(owner, id, fields \\ []) do
    {:ok, _agent} = Wardrik.Agent.define(owner, id, [model: @model] ++ fields)
    :ok
  end

  def answers(responses) do
    {:ok, queue} = Agent.start_link(fn -> responses end)

    Mimic.stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)

    Mimic.stub(ReqLLM, :stream_text, fn _model, _messages, _opts ->
      {:ok, Agent.get_and_update(queue, fn [next | rest] -> {next, rest} end)}
    end)
  end

  def answer(text), do: response(ReqLLM.Context.assistant(text))

  def calling(id, name, args),
    do:
      response(
        ReqLLM.Context.assistant("",
          tool_calls: [ReqLLM.ToolCall.new(id, name, JSON.encode!(args))]
        )
      )

  defp response(message),
    do: %ReqLLM.Response{id: "resp", model: "test", context: nil, message: message}
end
