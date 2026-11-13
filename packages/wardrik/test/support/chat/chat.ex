defmodule Wardrik.Chat.Test.Chat do
  @moduledoc "A chat app that sends the test what it's asked to post."

  use Wardrik.Chat

  @impl Wardrik.Channel
  def request(%{body: body}, _opts), do: %{status: 200, headers: %{}, body: body}

  @impl Wardrik.Chat
  def deliver(%{body: {:reply, "Answered: skip" <> _rest, _answering}} = outbound, channel) do
    send(channel.options[:test], {:skipped, outbound})
    {:skip, "it was asked to"}
  end

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
end

defmodule Wardrik.Chat.Test.Members do
  @moduledoc "Knows the chat members of `:members` as their users, as a host's identities would."

  @behaviour Wardrik.Chat.Identities

  @impl Wardrik.Chat.Identities
  def identify(%Wardrik.Chat.Identities.Request{workspace: "T1", member: member}, opts) do
    members = Keyword.fetch!(opts, :members)

    case Map.fetch(members, member) do
      {:ok, user} -> {:ok, %WardrikCore.Principal{id: user}}
      :error -> {:error, "Nobody here knows you yet."}
    end
  end

  def identify(_request, _opts), do: {:error, "Nobody here knows you yet."}
end

defmodule Wardrik.Chat.Test do
  @moduledoc "Runs a chat channel for a test, over a real store and events, on the test's own server."

  import ExUnit.Callbacks, only: [start_supervised!: 1]

  alias Wardrik.Testing.Server

  @members %{"U1" => "maria", "U2" => "jon", "U3" => "ana"}

  @doc "Returns the chat members the test's identities know, by member ID, as their users."
  def members, do: @members

  @doc """
  Allows everything but deciding, which only maria, whose binding allows it, or whoever asked may
  do, as a host's authorizer would. Tells `test` each request it decides.
  """
  def deciders(test, %{operation: "agent." <> verb, scope: scope} = request)
      when verb in ["approve", "deny"] do
    send(test, {:authorizing, request})
    %{principal: principal, actor: {:channel, _name}, context: context} = scope

    if principal.id == "maria" or context[:asked_by] == principal.id,
      do: :ok,
      else: {:error, :forbidden}
  end

  def deciders(_test, _request), do: :ok

  def start_channel(context) do
    n = System.unique_integer([:positive])
    name = :"wardrik #{n}"
    channel = "chat-#{n}"
    store = Wardrik.Store.ETS.new(name: :"store #{n}")
    events = Server.events(name)
    refusals = :counters.new(1, [])

    start_supervised!({Wardrik.Store, store})

    start_supervised!(
      {Wardrik.EventLog, name: events, store: store, deployment: "test", retention: :infinity}
    )

    test = self()

    :ok =
      Server.start(name,
        authorize: &deciders(test, &1),
        offered: Map.get(context, :offered, [{"agt_triage", [channel]}])
      )

    opts = [
      server: Server,
      wardrik: name,
      events: events,
      channel: channel,
      store: store,
      token: "xoxb-test",
      owner: "acme",
      identities: {Wardrik.Chat.Test.Members, members: @members},
      test: self(),
      refusals: refusals
    ]

    start_supervised!({Wardrik.Chat.Test.Chat, opts})
    channel = Wardrik.Chat.channel(Wardrik.Chat.Test.Chat, opts)
    {:ok, workspace} = Wardrik.Chat.workspace(channel, "T1")

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
