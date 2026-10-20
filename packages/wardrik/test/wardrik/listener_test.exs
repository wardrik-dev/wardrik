defmodule Wardrik.ListenerTest do
  use ExUnit.Case, async: false

  alias Wardrik.AgentID
  alias Wardrik.Event.Cursor
  alias Wardrik.Event.Log.Entry
  alias Wardrik.Test.AgentRunners
  alias Wardrik.Test.Script

  # Hands each entry to the test, keeps the cursor past it in a table, as a
  # host keeps it with its own work, and raises on an entry the test names.
  defmodule Runs do
    use Wardrik.Listener

    @impl true
    def handle(%Entry{event: %{"type" => type}} = entry, listener) do
      if :ets.member(listener.options[:saved], {:raise, type}) do
        :ets.delete(listener.options[:saved], {:raise, type})
        raise "#{type} is refused once"
      end

      send(listener.options[:test], {:handled, entry, listener.cursor})
      :ets.insert(listener.options[:saved], {:cursor, listener.cursor})
      :ok
    end

    @impl true
    def cursor(listener) do
      case :ets.lookup(listener.options[:saved], :cursor) do
        [{:cursor, cursor}] -> cursor
        [] -> listener.cursor
      end
    end
  end

  setup do
    host =
      Wardrik.new(
        store: Wardrik.Test.store(),
        issuer: %Wardrik.OrgIssuer{org: "acme"},
        context: Wardrik.context([])
      )

    owner = "listener#{System.unique_integer([:positive])}"
    saved = :ets.new(:saved, [:public])

    %{
      host: host,
      saved: saved,
      owner: owner,
      scope: Wardrik.as(host, maria()),
      resources: [Wardrik.Resource.parse!("acme/@#{owner}/agent/*")]
    }
  end

  defp maria, do: Wardrik.Principal.new("acme/@maria")

  defp agent(context, name) do
    id = AgentID.new!(name, org: "acme", user: context.owner)
    config = Script.new({AgentRunners, :echo, [self(), "ok"]})
    {^id, _pid} = Wardrik.Test.Fleet.start_agent([config: config], id)
    id
  end

  defp listen(context, opts) do
    start_supervised!(
      {Runs,
       [
         host: context.host,
         principal: maria(),
         resources: context.resources,
         test: self(),
         saved: context.saved
       ] ++ opts}
    )
  end

  # Asks `agent`, and waits for its turn to be over, written to its log.
  defp asked(context, agent, text) do
    {:ok, _message} = Wardrik.agent_ask(context.scope, agent, text)
    assert_receive {:turn, _messages}, 5_000

    assert Wardrik.Test.Fleet.await_update(fn ->
             match?(
               %Wardrik.Agent.Snapshot{status: %{state: :idle}, trace_id: nil},
               Wardrik.agent_read!(context.scope, agent)
             )
           end)
  end

  test "hands each entry written from now on, with a cursor that resumes in every agent", ctx do
    [one, two] = [agent(ctx, "one"), agent(ctx, "two")]
    asked(ctx, one, "before")

    listen(ctx, types: ["wardrik.run.completed"])
    asked(ctx, two, "now")

    assert_receive {:handled, %Entry{log: ^two} = entry, cursor}, 5_000
    assert entry.event["type"] == "wardrik.run.completed"
    assert {:ok, %{^one => _head, ^two => sequence}} = Cursor.decode(cursor)
    assert sequence == entry.sequence
    refute_received {:handled, %Entry{log: ^one}, _cursor}
  end

  test "a handle that raises is restarted, and reads on from the cursor saved", ctx do
    one = agent(ctx, "one")
    :ets.insert(ctx.saved, {{:raise, "wardrik.run.completed"}})
    listen(ctx, types: ["wardrik.run.started", "wardrik.run.completed"])

    asked(ctx, one, "hi")

    assert_receive {:handled, %Entry{event: %{"type" => "wardrik.run.started"}}, _cursor}, 5_000
    assert_receive {:handled, %Entry{event: %{"type" => "wardrik.run.completed"}}, _c}, 5_000
    refute_receive {:handled, %Entry{event: %{"type" => "wardrik.run.started"}}, _again}, 200
  end

  test "starts after the cursor it was given, and needs a host and a principal", ctx do
    one = agent(ctx, "one")
    asked(ctx, one, "hi")
    {:ok, events} = Wardrik.events(ctx.scope, resources: ctx.resources)
    [first | _rest] = Enum.to_list(events)

    listen(ctx, after: Wardrik.cursor("", first), types: ["wardrik.run.completed"])

    assert_receive {:handled, %Entry{log: ^one, event: %{"type" => "wardrik.run.completed"}},
                    _cursor},
                   5_000

    assert_raise KeyError, fn -> Runs.start_link(host: ctx.host) end
    assert_raise KeyError, fn -> Runs.start_link(principal: maria()) end
  end
end
