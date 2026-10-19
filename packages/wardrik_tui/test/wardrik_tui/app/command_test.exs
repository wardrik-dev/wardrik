defmodule WardrikTUI.CommandTest do
  use ExUnit.Case, async: true

  alias WardrikTUI.Command

  # `parse/2` is pure, so these run without a terminal session behind them.
  # Booting one to test a function that reads a string costs a second and
  # proves nothing.

  test "the decision vocabulary only exists while a turn is parked" do
    assert Command.parse("y", true) == {:approve, nil, nil}
    assert Command.parse("Yes", true) == {:approve, nil, nil}
    assert Command.parse("n", true) == {:deny, nil, nil}
    assert Command.parse("no", true) == {:deny, nil, nil}
    assert Command.parse("n not during the freeze", true) == {:deny, nil, "not during the freeze"}
    assert Command.parse("no not this quarter", true) == {:deny, nil, "not this quarter"}

    # The same words are ordinary questions when nothing is waiting.
    assert Command.parse("y") == {:ask, "y"}
    assert Command.parse("no") == {:ask, "no"}
    assert Command.parse("n not during the freeze") == {:ask, "n not during the freeze"}
  end

  test "a bare answer can pick one of several parked calls, or all of them" do
    assert Command.parse("y 2", true) == {:approve, "2", nil}
    assert Command.parse("y all", true) == {:approve, :all, nil}
    assert Command.parse("n 2", true) == {:deny, "2", nil}
    assert Command.parse("n 2 too risky", true) == {:deny, "2", "too risky"}
    assert Command.parse("n all not today", true) == {:deny, :all, "not today"}
  end

  test "only a bare word decides, so a question is never mistaken for one" do
    assert Command.parse("yes please list the services", true) ==
             {:ask, "yes please list the services"}

    assert Command.parse("nobody asked", true) == {:ask, "nobody asked"}
  end

  test "a decision can always be spelled out, parked or not" do
    for parked? <- [true, false] do
      assert Command.parse("/approve", parked?) == {:approve, nil, nil}
      assert Command.parse("/y", parked?) == {:approve, nil, nil}
      assert Command.parse("/approve 1", parked?) == {:approve, "1", nil}
      assert Command.parse("/approve all", parked?) == {:approve, :all, nil}

      assert Command.parse("/approve only this once", parked?) ==
               {:approve, nil, "only this once"}

      assert Command.parse("/approve 2 only this once", parked?) ==
               {:approve, "2", "only this once"}

      assert Command.parse("/deny", parked?) == {:deny, nil, nil}
      assert Command.parse("/n", parked?) == {:deny, nil, nil}
      assert Command.parse("/deny too risky", parked?) == {:deny, nil, "too risky"}
      assert Command.parse("/n too risky", parked?) == {:deny, nil, "too risky"}
      assert Command.parse("/deny 2 too risky", parked?) == {:deny, "2", "too risky"}
      assert Command.parse("/deny all", parked?) == {:deny, :all, nil}
    end
  end

  test "a selector is a number or `all`, so a note or a reason is never mistaken for one" do
    assert Command.parse("/approve deploy") == {:approve, nil, "deploy"}
    assert Command.parse("/deny deploy is wrong") == {:deny, nil, "deploy is wrong"}
  end

  test "parse/1 reads the prompt's vocabulary" do
    assert Command.parse("") == :blank
    assert Command.parse("  \n") == :blank
    assert Command.parse("/quit") == :quit
    assert Command.parse("/exit") == :quit
    assert Command.parse("/stop") == {:stop, nil}
    assert Command.parse("/help") == :help
    assert Command.parse("/confirm") == :confirm
    assert Command.parse(" hello ") == {:ask, "hello"}
  end

  test "a slash word that names nothing is reported rather than asked" do
    assert Command.parse("/spwan helper") == {:unknown, "/spwan"}
    assert Command.parse("/kill helper") == {:unknown, "/kill"}
  end

  test "a command given the wrong thing reports its usage rather than guessing" do
    assert Command.parse("/connect one two") == {:usage, "/connect"}
    assert Command.parse("/shutdown") == {:usage, "/shutdown"}
    assert Command.parse("/rm") == {:usage, "/rm"}
    assert Command.parse("/rm a b c") == {:usage, "/rm"}
    assert Command.parse("/quit now") == {:usage, "/quit"}
    assert Command.parse("/move researcher") == {:move, "researcher", %{}}
    assert Command.parse("/move researcher node=wardrik_b please") == {:usage, "/move"}
    assert Command.parse("/move researcher --bg") == {:usage, "/move"}
  end

  test "a command missing what it needs asks for it rather than failing" do
    assert Command.parse("/connect") == {:connect, nil}
    assert Command.parse("/move") == {:move, nil, %{}}
    assert Command.parse("/move researcher") == {:move, "researcher", %{}}
  end

  test "a line starting with two slashes is sent as text, one slash taken off" do
    assert Command.parse("//spawn is a word") == {:ask, "/spawn is a word"}
    assert Command.parse("  //etc/hosts  ") == {:ask, "/etc/hosts"}
    assert Command.parse("//", true) == {:ask, "/"}
  end

  test "the fleet has its own vocabulary" do
    assert Command.parse("/fleet") == :fleet
    assert Command.parse("/spawn researcher") == {:spawn, "researcher", %{}, nil, :attach}

    assert Command.parse("/spawn researcher look into it") ==
             {:spawn, "researcher", %{}, "look into it", :attach}

    assert Command.parse("/spawn researcher node=wardrik_b look into it") ==
             {:spawn, "researcher", %{"node" => "wardrik_b"}, "look into it", :attach}

    assert Command.parse("/spawn researcher node=wardrik_b") ==
             {:spawn, "researcher", %{"node" => "wardrik_b"}, nil, :attach}

    assert Command.parse("/move researcher node=wardrik_b") ==
             {:move, "researcher", %{"node" => "wardrik_b"}}

    assert Command.parse("/connect researcher") == {:connect, "researcher"}
  end

  test "a prompt is kept as typed, and `--` keeps even an option-shaped word in it" do
    assert Command.parse("/spawn researcher look  into   x=y please") ==
             {:spawn, "researcher", %{}, "look  into   x=y please", :attach}

    assert Command.parse("/spawn researcher node=wardrik_b -- Investigate x=y") ==
             {:spawn, "researcher", %{"node" => "wardrik_b"}, "Investigate x=y", :attach}

    assert Command.parse("/spawn researcher -- node=wardrik_b is not an option here") ==
             {:spawn, "researcher", %{}, "node=wardrik_b is not an option here", :attach}

    assert Command.parse("/spawn researcher --") == {:spawn, "researcher", %{}, nil, :attach}
    assert Command.parse("/spawn researcher stray -- prompt") == {:usage, "/spawn"}
  end

  test "`--bg` spawns in the background, wherever it sits among the options" do
    assert Command.parse("/spawn researcher --bg") ==
             {:spawn, "researcher", %{}, nil, :background}

    assert Command.parse("/spawn researcher --bg node=wardrik_b look into it") ==
             {:spawn, "researcher", %{"node" => "wardrik_b"}, "look into it", :background}

    assert Command.parse("/spawn researcher node=wardrik_b --bg -- look --bg into it") ==
             {:spawn, "researcher", %{"node" => "wardrik_b"}, "look --bg into it", :background}

    assert Command.parse("/spawn --bg") == {:usage, "/spawn"}
  end

  test "interrupting, shutting down and removing are three different words" do
    assert Command.parse("/stop helper") == {:stop, "helper"}
    assert Command.parse("/stop acme/") == {:stop, "acme/"}
    assert Command.parse("/shutdown helper") == {:shutdown, "helper"}
    assert Command.parse("/rm helper") == {:rm, "helper", false}
    assert Command.parse("/rm acme/") == {:rm, "acme/", false}
    assert Command.parse("/rm acme/ --yes") == {:rm, "acme/", true}
  end

  test "the fleet vocabulary works while a turn is parked" do
    assert Command.parse("/fleet", true) == :fleet
    assert Command.parse("/connect other", true) == {:connect, "other"}
  end

  test "names complete and near misses are suggested" do
    assert Command.complete("/conn") == ["/connect"]
    assert Command.complete("/s") == ["/spawn", "/stop", "/shutdown"]
    assert Command.complete("/zzz") == []

    assert "/spawn" in Command.suggest("/spwan")
    assert "/connect" in Command.suggest("/conect")
    assert Command.suggest("/zzzzzz") == []
  end

  test "help lists every command with its usage" do
    usages = Command.help() |> Enum.map(&elem(&1, 0))

    assert "/spawn NAME [node=N] [--bg] [-- prompt]" in usages
    assert "/rm NAME | PATTERN [--yes]" in usages
    assert length(usages) == length(Command.all())
  end
end
