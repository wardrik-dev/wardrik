defmodule Wardrik.HookTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Wardrik.Call
  alias Wardrik.Call.Ask
  alias Wardrik.Call.Denial
  alias Wardrik.Hook
  alias Wardrik.Test.Tools.Deploy

  # Says of every call whatever its value is, and reports what it hears.
  defmodule Scripted do
    @behaviour Hook

    @impl true
    def init(script), do: script

    @impl true
    def call(_call, :raise), do: raise("hook is broken")
    def call(_call, decision), do: decision

    @impl true
    def approved(call, memo, script), do: send(self(), {:approved, call.id, memo, script})
  end

  defp hook(name, script), do: Hook.new(name, Scripted, script)

  defp check(hooks, name \\ "echo"),
    do: Wardrik.Test.check(Wardrik.Test.scope(hooks: hooks), name)

  describe "check/1" do
    test "no hooks allow everything, so a deployment without one configures nothing" do
      assert %Call{state: :allowed} = check([])
    end

    test "a hook that passes allows the call" do
      assert %Call{state: :allowed, asks: [], denied: nil} = check([hook("quiet", :pass)])
    end

    test "a deny refuses the call, says whose it was, and ends the asking" do
      hooks = [
        hook("first", {:ask, "Sure?"}),
        hook("second", {:deny, "No."}),
        hook("never", :raise)
      ]

      assert %Call{state: :denied, denied: %Denial{by: "second", reason: "No."}} = check(hooks)
    end

    test "every hook that asks is kept, with its memo, in order" do
      hooks = [
        hook("first", {:ask, "Sure?", :one}),
        hook("second", :pass),
        hook("third", {:ask, "Really sure?"})
      ]

      call = check(hooks)

      assert call.state == :waiting

      assert call.asks == [
               %Ask{by: "first", prompt: "Sure?", memo: :one},
               %Ask{by: "third", prompt: "Really sure?", memo: nil}
             ]

      assert Call.prompt(call) == "Sure?\n\nReally sure?"
    end

    test "a hook that answers with something else refuses the call" do
      assert %Call{state: :denied, denied: %Denial{reason: reason}} =
               check([hook("odd", :maybe)])

      assert reason =~ "odd" and reason =~ ":maybe"
    end

    test "a hook that raises refuses the call, because governance must not fail open" do
      assert %Call{state: :denied, denied: %Denial{reason: reason}} =
               check([hook("broken", :raise)])

      assert reason =~ "hook is broken"
    end
  end

  describe "a gated tool's call" do
    defp gated(hooks, tainted \\ false) do
      scope = %{Wardrik.Test.scope(tools: [Deploy], hooks: hooks) | tainted: tainted}
      Wardrik.Test.check(scope, "deploy", %{"target" => "prod"})
    end

    test "waits on its tool where no hook allows it by name, under no hooks or quiet ones" do
      for hooks <- [[], [hook("quiet", :pass)]] do
        assert %Call{state: :waiting, asks: [%Ask{by: :tool, prompt: prompt}]} = gated(hooks)

        assert prompt ==
                 "deploy is gated, so it asks unless a rule allows it by name, and none does."
      end
    end

    test "goes ahead where a hook allows it, in that hook's name" do
      assert %Call{state: :allowed, allowed: ["rules"]} = gated([hook("rules", :allow)])
    end

    test "is still refused by a deny, and asked about by an ask" do
      assert %Call{state: :denied} = gated([hook("rules", :allow), hook("no", {:deny, "No."})])

      assert %Call{state: :waiting, asks: [%Ask{by: "careful"}]} =
               gated([hook("rules", :allow), hook("careful", {:ask, "Sure?"})])
    end

    test "waits on its tool in a run that has read content from outside, however it was allowed" do
      assert %Call{state: :waiting, asks: [%Ask{by: :tool, prompt: prompt}]} =
               gated([hook("rules", :allow)], true)

      assert prompt ==
               "rules allows deploy, but this run has read content from outside, " <>
                 "which may be what asked for it."
    end

    test "goes ahead in such a run where the hook allowed it after outside content" do
      assert %Call{state: :allowed, allowed: ["rules"], allowed_after_outside: ["rules"]} =
               gated([hook("rules", {:allow, after_outside: true})], true)
    end

    test "is not what an ungated call is: that goes ahead without an allow, tainted or not" do
      scope = %{Wardrik.Test.scope(hooks: [hook("quiet", :pass)]) | tainted: true}

      assert %Call{state: :allowed, allowed: []} = Wardrik.Test.check(scope, "echo")
    end
  end

  describe "approved/1" do
    test "tells each hook that asked, with its own memo" do
      hooks = [hook("first", {:ask, "Sure?", :one}), hook("second", :pass)]

      %Call{id: id} = call = check(hooks)
      :ok = call |> Call.approve() |> Hook.approved()

      assert_received {:approved, ^id, :one, {:ask, "Sure?", :one}}
      refute_received {:approved, _id, _memo, _script}
    end

    test "skips a hook the scope no longer has" do
      waiting = check([hook("gone", {:ask, "Sure?"})])

      :ok = waiting |> Call.approve() |> Call.under(Wardrik.Test.scope()) |> Hook.approved()
      refute_received {:approved, _id, _memo, _script}
    end

    test "a hook that fails to hear it is logged" do
      defmodule Unhearing do
        @behaviour Hook
        @impl true
        def init(_opts), do: nil
        @impl true
        def call(_call, _value), do: {:ask, "Sure?"}
        @impl true
        def approved(_call, _memo, _value), do: raise("approval is broken")
      end

      log =
        capture_log(fn ->
          :ok = [Hook.new("unhearing", Unhearing)] |> check() |> Call.approve() |> Hook.approved()
        end)

      assert log =~ "approval is broken"
    end
  end

  describe "revision/1" do
    test "is the same for the same hooks, and changes with what they hold" do
      assert Hook.revision([hook("a", :pass)]) == Hook.revision([hook("a", :pass)])
      refute Hook.revision([hook("a", :pass)]) == Hook.revision([hook("a", {:ask, "?"})])
      refute Hook.revision([]) == Hook.revision([hook("a", :pass)])
    end
  end
end
