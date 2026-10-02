defmodule WardrikTUI.PaletteTest do
  use ExUnit.Case, async: true

  alias WardrikTUI.Command
  alias WardrikTUI.Palette

  @rows ["Connect to an agent", "Spawn an agent", "Every key and command", "Quit"]

  describe "filter/3" do
    test "an empty query keeps every row in order" do
      assert Palette.filter(@rows, "", & &1) == @rows
    end

    test "keeps the rows whose text holds the query's letters in order, ignoring case" do
      assert Palette.filter(@rows, "AGENT", & &1) == ["Connect to an agent", "Spawn an agent"]
      assert Palette.filter(@rows, "spag", & &1) == ["Spawn an agent"]
      assert Palette.filter(@rows, "zzz", & &1) == []
    end

    test "ranks the tightest match first, keeping the order given among equals" do
      rows = ["Shut an agent down", "Quit", "Every key and command"]

      assert Palette.filter(rows, "qu", & &1) == ["Quit"]
      assert Palette.filter(rows, "an", & &1) == ["Shut an agent down", "Every key and command"]
      assert Palette.filter(["a b c", "abc"], "abc", & &1) == ["abc", "a b c"]
    end

    test "reads the text through the function given" do
      rows = [{:a, "Connect"}, {:b, "Quit"}]

      assert Palette.filter(rows, "qu", &elem(&1, 1)) == [{:b, "Quit"}]
    end
  end

  describe "Command.palette/1" do
    @idle %{busy?: false, parked: 0, confirm?: false, nodes: 1, attention: 0}

    test "leaves out what cannot run now" do
      names = @idle |> Command.palette() |> Enum.map(& &1.name)

      assert "/connect" in names
      assert "/help" in names
      refute "/stop" in names
      refute "/approve" in names
      refute "/deny" in names
      refute "/confirm" in names
      refute "/move" in names
      refute "/next" in names
    end

    test "offers each command when its moment comes" do
      names = fn context -> context |> Command.palette() |> Enum.map(& &1.name) end

      assert "/stop" in names.(%{@idle | busy?: true})
      assert "/approve" in names.(%{@idle | parked: 2})
      assert "/confirm" in names.(%{@idle | confirm?: true})
      assert "/move" in names.(%{@idle | nodes: 2})
      assert "/next" in names.(%{@idle | attention: 1})
    end

    test "every command has a label and steps the palette knows" do
      for command <- Command.all() do
        assert is_binary(command.label) and command.label != ""
        assert Enum.all?(command.arguments, &(&1 in [:agent, :node, :call, :text]))
      end
    end
  end
end
