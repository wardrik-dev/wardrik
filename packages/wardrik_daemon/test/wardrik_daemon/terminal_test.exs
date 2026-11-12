defmodule WardrikDaemon.CLI.TerminalTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias WardrikDaemon.CLI.Terminal

  test "takes input where WARDRIK_INPUT is 1, and writes plain text 80 wide off a terminal" do
    assert %Terminal{width: 80, colour?: false, input?: true} =
             Terminal.new(%{"WARDRIK_INPUT" => "1"})

    assert %Terminal{input?: false} = Terminal.new(%{})
  end

  test "reads a typed line, trimmed, and nil for none" do
    terminal = Terminal.new(%{})

    assert capture_io("sk-ant-123  \n", fn ->
             assert Terminal.secret(terminal, "Key: ") == "sk-ant-123"
           end) == "Key: "

    capture_io("\n", fn -> assert Terminal.secret(terminal, "Key: ") == nil end)
    capture_io("", fn -> assert Terminal.secret(terminal, "Key: ") == nil end)
  end

  test "writes lines, plain off a terminal" do
    terminal = Terminal.new(%{})

    assert capture_io(fn -> Terminal.lines(terminal, ["one", Owl.Data.tag("two", :green)]) end) ==
             "one\ntwo\n"
  end
end
