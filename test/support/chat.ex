defmodule WardrikChannel.Test.Chat do
  @moduledoc "A chat app that sends the test what it's asked to post, and knows people by `@name`."

  use WardrikChannel

  @impl Wardrik.Channel
  def request(%{body: body}, _opts), do: %{status: 200, headers: %{}, body: body}

  @impl WardrikChannel
  def deliver(%{body: {:reply, _text, _answering}} = outbound, channel) do
    refusals = channel.options[:refusals]

    if :counters.get(refusals, 1) > 0 do
      :counters.sub(refusals, 1, 1)
      send(channel.options[:test], {:refused, outbound})
      {:error, :busy}
    else
      delivered(channel, outbound)
    end
  end

  def deliver(outbound, channel), do: delivered(channel, outbound)

  defp delivered(channel, outbound) do
    send(channel.options[:test], {:delivered, outbound})
    :ok
  end

  @impl WardrikChannel
  def include?(%{names: names, member: member}, _channel), do: ("@" <> member.name) in names
end

defmodule WardrikChannel.Test do
  @moduledoc "Runs a chat channel for a test, over a real store and events, on the test's own server."

  import ExUnit.Callbacks, only: [start_supervised!: 1]

  alias WardrikTesting.Server

  @doc """
  Allows everything but deciding, which only an approver or whoever asked may do, as a host's
  authorizer would. Tells `test` each request it decides.
  """
  def deciders(test, %{operation: "agent." <> verb, scope: scope} = request)
      when verb in ["approve", "deny"] do
    send(test, {:authorizing, request})
    %{principal: principal, actor: {:channel, _name}, context: context} = scope

    if context[:approver] || context[:asked_by] == principal.id,
      do: :ok,
      else: {:error, :forbidden}
  end

  def deciders(_test, _request), do: :ok

  def start_channel(context) do
    n = System.unique_integer([:positive])
    name = :"wardrik #{n}"
    channel = "chat-#{n}"
    store = WardrikStore.ETS.new(name: :"store #{n}")
    events = Server.events(name)
    refusals = :counters.new(1, [])

    start_supervised!({WardrikStore, store})

    start_supervised!(
      {WardrikEvents, name: events, store: store, deployment: "test", retention: :infinity}
    )

    test = self()

    :ok =
      Server.start(name,
        authorize: &deciders(test, &1),
        offered: Map.get(context, :offered, [{"acme/triage", [channel]}])
      )

    opts = [
      server: Server,
      wardrik: name,
      events: events,
      channel: channel,
      store: store,
      token: "xoxb-test",
      owner: "acme",
      approvers: ["@maria"],
      test: self(),
      refusals: refusals
    ]

    start_supervised!({WardrikChannel.Test.Chat, opts})
    channel = WardrikChannel.channel(WardrikChannel.Test.Chat, opts)
    {:ok, workspace} = WardrikChannel.workspace(channel, "T1")

    %{
      name: name,
      store: store,
      events: events,
      channel: channel,
      workspace: workspace,
      refusals: refusals
    }
  end
end
