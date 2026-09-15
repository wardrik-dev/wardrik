defmodule TarsTUI.App.CommandTest do
  use ExUnit.Case, async: true

  alias TarsTUI.App

  # `command/2` is pure, so these run without a terminal session behind them.
  # Booting one to test a function that reads a string costs a second and
  # proves nothing.

  test "the decision vocabulary only exists while a turn is parked" do
    assert App.command("y", true) == :approve
    assert App.command("Yes", true) == :approve
    assert App.command("n", true) == {:deny, nil}
    assert App.command("no", true) == {:deny, nil}
    assert App.command("n not during the freeze", true) == {:deny, "not during the freeze"}
    assert App.command("no not this quarter", true) == {:deny, "not this quarter"}

    # The same words are ordinary questions when nothing is waiting.
    assert App.command("y") == {:ask, "y"}
    assert App.command("no") == {:ask, "no"}
    assert App.command("n not during the freeze") == {:ask, "n not during the freeze"}
  end

  test "only a bare word decides, so a question is never mistaken for one" do
    assert App.command("yes please list the services", true) ==
             {:ask, "yes please list the services"}

    assert App.command("nobody asked", true) == {:ask, "nobody asked"}
  end

  test "a decision can always be spelled out, parked or not" do
    for parked? <- [true, false] do
      assert App.command("/approve", parked?) == :approve
      assert App.command("/y", parked?) == :approve
      assert App.command("/deny", parked?) == {:deny, nil}
      assert App.command("/n", parked?) == {:deny, nil}
      assert App.command("/deny too risky", parked?) == {:deny, "too risky"}
      assert App.command("/n too risky", parked?) == {:deny, "too risky"}
    end
  end

  test "command/1 reads the prompt's vocabulary" do
    assert App.command("") == :blank
    assert App.command("  \n") == :blank
    assert App.command("/quit") == :quit
    assert App.command("/exit") == :quit
    assert App.command("/stop") == :stop
    assert App.command("/help") == :help
    assert App.command(" hello ") == {:ask, "hello"}
  end

  test "the fleet has its own vocabulary" do
    assert App.command("/fleet") == :fleet
    assert App.command("/spawn researcher") == {:spawn, "researcher", %{}, nil}

    assert App.command("/spawn researcher look into it") ==
             {:spawn, "researcher", %{}, "look into it"}

    assert App.command("/spawn researcher node=tars_b look into it") ==
             {:spawn, "researcher", %{"node" => "tars_b"}, "look into it"}

    assert App.command("/spawn researcher node=tars_b") ==
             {:spawn, "researcher", %{"node" => "tars_b"}, nil}

    assert App.command("/move researcher node=tars_b") ==
             {:move, "researcher", %{"node" => "tars_b"}}

    assert App.command("/connect researcher") == {:connect, "researcher"}
    assert App.command("/kill acme/") == {:kill, "acme/"}
    assert App.command("/kill") == {:kill, ""}
  end

  test "the fleet vocabulary works while a turn is parked" do
    assert App.command("/fleet", true) == :fleet
    assert App.command("/connect other", true) == {:connect, "other"}
  end
end
