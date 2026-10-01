defmodule WardrikDaemon.CLI.TerminalTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias WardrikDaemon.CLI.Terminal

  test "reads the terminal the script puts ahead of a command's arguments" do
    assert Terminal.read(["--terminal=132,colour", "status"]) ==
             {%Terminal{width: 132, colour?: true}, ["status"]}

    assert Terminal.read(["--terminal=90,plain", "parked"]) ==
             {%Terminal{width: 90, colour?: false}, ["parked"]}

    assert Terminal.read(["--terminal=90,plain,input", "approve"]) ==
             {%Terminal{width: 90, input?: true}, ["approve"]}

    assert {%Terminal{input?: false}, []} = Terminal.read(["--terminal=90,colour,no-input"])
  end

  test "is plain and 80 wide where none is described, or its width does not read" do
    assert Terminal.read(["status"]) == {%Terminal{width: 80, colour?: false}, ["status"]}
    assert {%Terminal{width: 80}, []} = Terminal.read(["--terminal=wide,colour"])
    assert {%Terminal{width: 80}, []} = Terminal.read(["--terminal=0,plain"])
  end

  test "writes in colour only where the terminal takes it" do
    data = Owl.Data.tag("ok", :green)

    assert capture_io(fn -> Terminal.puts(%Terminal{colour?: true}, data) end) =~ IO.ANSI.green()
    assert capture_io(fn -> Terminal.puts(%Terminal{}, data) end) == "ok\n"
  end
end
