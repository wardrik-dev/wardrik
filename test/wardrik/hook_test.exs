defmodule Wardrik.HookTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Wardrik.Call
  alias Wardrik.Call.Ask
  alias Wardrik.Call.Denial
  alias Wardrik.Hook
  alias Wardrik.LLM.Config
  alias Wardrik.Scope

  # Does to the call whatever its value says, and reports what it hears.
  defmodule Scripted do
    @behaviour Hook

    @impl true
    def init(script), do: script

    @impl true
    def call(call, :allow), do: call
    def call(call, {:deny, reason}), do: Call.deny(call, reason)
    def call(call, {:ask, prompt}), do: Call.ask(call, prompt)
    def call(call, {:ask, prompt, memo}), do: Call.ask(call, prompt, memo)
    def call(call, {:assign, key, value}), do: Call.assign(call, key, value)
    def call(call, {:read, key}), do: send(self(), {:read, call.assigns[key]}) && call
    def call(_call, :answer_nonsense), do: :maybe
    def call(call, :forget_asks), do: %{call | asks: []}
    def call(call, :rename), do: %{call | target: %Call.Tool{name: "other"}}
    def call(_call, :raise), do: raise("hook is broken")

    @impl true
    def approved(call, script), do: send(self(), {:approved, call.id, Call.memo(call), script})
  end

  defp hook(name, script), do: Hook.new(name, Scripted, script)
  defp scope(hooks), do: Scope.root(Config.new(), :assistant, hooks: hooks)

  defp check(hooks, name \\ "echo") do
    %{id: "call_1", name: name, arguments: %{}} |> Call.tool(scope(hooks)) |> Hook.check()
  end

  describe "check/1" do
    test "no hooks allow everything, so a deployment without one configures nothing" do
      assert %Call{state: :allowed} = check([])
    end

    test "a hook that hands the call back as it was allows it" do
      assert %Call{state: :allowed, asks: [], denied: nil} = check([hook("quiet", :allow)])
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
        hook("second", :allow),
        hook("third", {:ask, "Really sure?", :three})
      ]

      call = check(hooks)

      assert call.state == :waiting

      assert call.asks == [
               %Ask{by: "first", prompt: "Sure?", memo: :one},
               %Ask{by: "third", prompt: "Really sure?", memo: :three}
             ]

      assert Call.prompt(call) == "Sure?\n\nReally sure?"
    end

    test "what one hook assigns, the hooks after it read" do
      assert %Call{state: :allowed} =
               check([hook("classify", {:assign, :risk, :high}), hook("read", {:read, :risk})])

      assert_received {:read, :high}
    end

    test "a hook that hands back something else refuses the call" do
      assert %Call{state: :denied, denied: %Denial{reason: reason}} =
               check([hook("odd", :answer_nonsense)])

      assert reason =~ "odd" and reason =~ ":maybe"
    end

    test "a hook that raises refuses the call, because governance must not fail open" do
      assert %Call{state: :denied, denied: %Denial{reason: reason}} =
               check([hook("broken", :raise)])

      assert reason =~ "hook is broken"
    end

    test "a hook cannot take back what another hook said" do
      hooks = [hook("first", {:ask, "Sure?"}), hook("sneaky", :forget_asks)]

      assert %Call{state: :denied, denied: %Denial{by: "sneaky", reason: reason}} = check(hooks)
      assert reason =~ "changed what another hook said"
    end

    test "a hook cannot change what the call is" do
      assert %Call{state: :allowed, target: %Call.Tool{name: "echo"}} =
               check([hook("renamer", :rename)])
    end
  end

  describe "approved/1" do
    test "tells each hook that asked, with its own memo" do
      hooks = [hook("first", {:ask, "Sure?", :one}), hook("second", :allow)]

      :ok = hooks |> check() |> Call.approve() |> Hook.approved()

      assert_received {:approved, "call_1", :one, {:ask, "Sure?", :one}}
      refute_received {:approved, _id, _memo, _script}
    end

    test "skips a hook the scope no longer has" do
      waiting = check([hook("gone", {:ask, "Sure?"})])

      :ok = waiting |> Call.approve() |> Call.under(scope([])) |> Hook.approved()
      refute_received {:approved, _id, _memo, _script}
    end

    test "a hook that fails to hear it is logged" do
      defmodule Unhearing do
        @behaviour Hook
        @impl true
        def init(_opts), do: nil
        @impl true
        def call(call, _value), do: Call.ask(call, "Sure?")
        @impl true
        def approved(_call, _value), do: raise("approval is broken")
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
      assert Hook.revision([hook("a", :allow)]) == Hook.revision([hook("a", :allow)])
      refute Hook.revision([hook("a", :allow)]) == Hook.revision([hook("a", {:ask, "?"})])
      refute Hook.revision([]) == Hook.revision([hook("a", :allow)])
    end
  end
end
