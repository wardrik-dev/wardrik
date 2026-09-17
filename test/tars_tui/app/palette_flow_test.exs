defmodule TarsTUI.App.PaletteFlowTest do
  use ExUnit.Case, async: true

  alias TarsTUI.App.PaletteFlow
  alias TarsTUI.Command
  alias TarsTUI.Palette

  test "a move collects agent and node, then returns a line for the shared parser" do
    command = Command.find("/move")

    assert {:step, :agent, ^command, []} =
             PaletteFlow.select(%Palette{}, {command, "Move"}, [])

    agent = %Palette{step: :agent, command: command}

    assert {:step, :node, ^command, ["org/user/research"]} =
             PaletteFlow.select(agent, {"org/user/research", "Research"}, [])

    node = %Palette{step: :node, command: command, chosen: ["org/user/research"]}

    assert {:run, ^command, line} =
             PaletteFlow.select(node, {"worker@host", "Worker"}, [])

    assert Command.parse(line, false) ==
             {:move, "org/user/research", %{"node" => "worker@host"}}
  end

  test "approving one call skips selection while several require an explicit choice" do
    command = Command.find("/approve")
    call = {%{id: "one", name: "tool"}, "Allow?"}

    assert {:run, ^command, "/approve"} =
             PaletteFlow.select(%Palette{}, {command, "Approve"}, [call])

    assert {:step, :call, ^command, []} =
             PaletteFlow.select(%Palette{}, {command, "Approve"}, [call, call])
  end

  test "text submission works without a selected row and preserves the command parser" do
    command = Command.find("/spawn")
    palette = %Palette{step: :text, command: command, query: " worker --bg -- hello world "}

    assert {:run, ^command, line} = PaletteFlow.select(palette, nil, [])
    assert Command.parse(line, false) == {:spawn, "worker", %{}, "hello world", :background}
  end

  test "inspection and search return navigation actions, and help keys do nothing" do
    assert {:inspect_tool, 2, "log"} =
             PaletteFlow.select(%Palette{step: :tool, origin: "log"}, {2, "tool"}, [])

    assert {:search, "needle", 12} =
             PaletteFlow.select(%Palette{step: :search, query: "needle"}, {12, "row"}, [])

    assert :ignore = PaletteFlow.select(%Palette{step: :help}, {:key, "Ctrl-P"}, [])
    assert :ignore = PaletteFlow.select(%Palette{}, nil, [])
  end
end
