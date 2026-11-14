defmodule Wardrik.UnreadableTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Wardrik.Test.Wardrik

  alias Wardrik.Store.Durable

  @model "anthropic:claude-haiku-4-5"
  @why "it holds a gone_reason, which none of its middleware or capabilities reads"

  setup context do
    started = start_wardrik(context)
    Map.put(started, :scope, owner(started.wardrik))
  end

  # Saved as parked on a reason none of the agent's middleware reads, as when a release drops it.
  defp saved_as_gone(%{wardrik: wardrik, store: store, scope: scope}, id) do
    run!(scope, "agent.define", %{"agent" => id, "model" => @model})
    run!(scope, "agent.stop", %{"agent" => id})

    key =
      wardrik
      |> Wardrik.agents()
      |> WardrikCore.saved_key({id, nil})

    gone = %{
      "reason" => %{"type" => "gone_reason", "version" => 1, "value" => %{}},
      "messages" => [],
      "span" => nil,
      "measurements" => %{}
    }

    durable = Wardrik.Store.scope(store, "durable")
    {value, vsn} = Wardrik.Store.lookup(durable, key)
    state = %{value["state"] | "state" => "waiting", "parked" => gone}
    {:ok, _vsn} = Wardrik.Store.put(durable, key, %{value | "state" => state}, if_vsn: vsn)
    key
  end

  defp started(context, id) do
    capture_log(fn ->
      Wardrik.run(context.scope, "agent.ask", %{"agent" => id, "content" => "Hi"})
    end)
  end

  test "refuses to start an agent whose saved state can't be read, and says why", context do
    saved_as_gone(context, "acme/old")

    log =
      capture_log(fn ->
        assert {:error, %Wardrik.Error{type: :conflict, message: message}} =
                 Wardrik.run(context.scope, "agent.ask", %{
                   "agent" => "acme/old",
                   "content" => "Hi"
                 })

        assert message ==
                 "acme/old can't start, as its saved state can't be read: #{@why}. Define it again to start it over; its definition, files and events stay."

        assert refused(context.scope, "agent.ask", %{"agent" => "acme/old", "content" => "Hi"}) ==
                 :conflict
      end)

    assert [_once] = Regex.scan(~r/can't be read/, log)
  end

  test "lists the agent as unreadable, with why", context do
    key = saved_as_gone(context, "acme/old")
    started(context, "acme/old")
    assert :ok != Durable.check(context.store, key)

    assert %{"agents" => [listed]} = run!(context.scope, "agents.list", %{})
    assert %{"id" => "acme/old", "status" => "unreadable", "problem" => @why} = listed

    assert %{"status" => "unreadable", "problem" => @why} =
             run!(context.scope, "agent.read", %{"agent" => "acme/old"})

    assert %{"agent" => %{"status" => "unreadable"}} =
             run!(context.scope, "agent.stop", %{"agent" => "acme/old"})
  end

  test "defining the agent again starts it over, and says so", context do
    key = saved_as_gone(context, "acme/old")
    started(context, "acme/old")

    assert %{"reset" => [reset], "status" => status} =
             run!(context.scope, "agent.define", %{"agent" => "acme/old", "model" => @model})

    assert reset == "acme/old started over, as its saved state couldn't be read: #{@why}."
    assert status in ["idle", "running"]
    assert Durable.noted(context.store, key) == :error

    defined = run!(context.scope, "agent.define", %{"agent" => "acme/old", "model" => @model})
    refute Map.has_key?(defined, "reset")
  end

  test "defining the agent again starts over a state nothing has read yet", context do
    saved_as_gone(context, "acme/old")

    capture_log(fn ->
      assert %{"reset" => [reset]} =
               run!(context.scope, "agent.define", %{"agent" => "acme/old", "model" => @model})

      assert reset == "acme/old started over, as its saved state couldn't be read: #{@why}."
    end)
  end

  test "notes a state until the state itself is written again", context do
    key = saved_as_gone(context, "acme/old")
    started(context, "acme/old")
    assert {:ok, @why} = Durable.noted(context.store, key)

    durable = Wardrik.Store.scope(context.store, "durable")
    {value, vsn} = Wardrik.Store.lookup(durable, key)
    {:ok, _vsn} = Wardrik.Store.put(durable, key, %{value | "meta" => value["meta"]}, if_vsn: vsn)
    assert {:ok, @why} = Durable.noted(context.store, key)

    state = %{value["state"] | "state" => "idle", "parked" => nil}
    {:ok, _vsn} = Wardrik.Store.put(durable, key, %{value | "state" => state})

    assert Durable.noted(context.store, key) == :error
    assert Durable.check(context.store, "wardrik/agents/none") == :ok
  end
end
