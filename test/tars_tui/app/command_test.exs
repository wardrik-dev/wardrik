defmodule TarsTUI.App.CommandTest do
  use ExUnit.Case, async: true

  alias TarsTUI.App

  # `command/2` is pure, so these run without a terminal session behind them.
  # Booting one to test a function that reads a string costs a second and
  # proves nothing.

  test "the decision vocabulary only exists while a turn is parked" do
    assert App.command("y", true) == {:approve, nil}
    assert App.command("Yes", true) == {:approve, nil}
    assert App.command("n", true) == {:deny, nil, nil}
    assert App.command("no", true) == {:deny, nil, nil}
    assert App.command("n not during the freeze", true) == {:deny, nil, "not during the freeze"}
    assert App.command("no not this quarter", true) == {:deny, nil, "not this quarter"}

    # The same words are ordinary questions when nothing is waiting.
    assert App.command("y") == {:ask, "y"}
    assert App.command("no") == {:ask, "no"}
    assert App.command("n not during the freeze") == {:ask, "n not during the freeze"}
  end

  test "a bare answer can pick one of several parked calls, or all of them" do
    assert App.command("y 2", true) == {:approve, "2"}
    assert App.command("y all", true) == {:approve, :all}
    assert App.command("n 2", true) == {:deny, "2", nil}
    assert App.command("n 2 too risky", true) == {:deny, "2", "too risky"}
    assert App.command("n all not today", true) == {:deny, :all, "not today"}
  end

  test "only a bare word decides, so a question is never mistaken for one" do
    assert App.command("yes please list the services", true) ==
             {:ask, "yes please list the services"}

    assert App.command("nobody asked", true) == {:ask, "nobody asked"}
  end

  test "a decision can always be spelled out, parked or not" do
    for parked? <- [true, false] do
      assert App.command("/approve", parked?) == {:approve, nil}
      assert App.command("/y", parked?) == {:approve, nil}
      assert App.command("/approve 1", parked?) == {:approve, "1"}
      assert App.command("/approve all", parked?) == {:approve, :all}
      assert App.command("/deny", parked?) == {:deny, nil, nil}
      assert App.command("/n", parked?) == {:deny, nil, nil}
      assert App.command("/deny too risky", parked?) == {:deny, nil, "too risky"}
      assert App.command("/n too risky", parked?) == {:deny, nil, "too risky"}
      assert App.command("/deny 2 too risky", parked?) == {:deny, "2", "too risky"}
      assert App.command("/deny all", parked?) == {:deny, :all, nil}
    end
  end

  test "a selector is a number or `all`, so a reason is never mistaken for one" do
    assert App.command("/approve deploy") == {:unknown, "/approve"}
    assert App.command("/deny deploy is wrong") == {:deny, nil, "deploy is wrong"}
  end

  test "command/1 reads the prompt's vocabulary" do
    assert App.command("") == :blank
    assert App.command("  \n") == :blank
    assert App.command("/quit") == :quit
    assert App.command("/exit") == :quit
    assert App.command("/stop") == {:stop, nil}
    assert App.command("/help") == :help
    assert App.command("/confirm") == :confirm
    assert App.command(" hello ") == {:ask, "hello"}
  end

  test "a slash word that names nothing is reported rather than asked" do
    assert App.command("/spwan helper") == {:unknown, "/spwan"}
    assert App.command("/kill helper") == {:unknown, "/kill"}
    assert App.command("/connect") == {:unknown, "/connect"}
    assert App.command("/shutdown") == {:unknown, "/shutdown"}
    assert App.command("/rm") == {:unknown, "/rm"}
    assert App.command("/rm a b c") == {:unknown, "/rm"}
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
  end

  test "interrupting, shutting down and removing are three different words" do
    assert App.command("/stop helper") == {:stop, "helper"}
    assert App.command("/stop acme/") == {:stop, "acme/"}
    assert App.command("/shutdown helper") == {:shutdown, "helper"}
    assert App.command("/rm helper") == {:rm, "helper", false}
    assert App.command("/rm acme/") == {:rm, "acme/", false}
    assert App.command("/rm acme/ --yes") == {:rm, "acme/", true}
  end

  test "the fleet vocabulary works while a turn is parked" do
    assert App.command("/fleet", true) == :fleet
    assert App.command("/connect other", true) == {:connect, "other"}
  end
end
