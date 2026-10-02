defmodule WardrikConsole.NodesTest do
  use ExUnit.Case, async: true

  alias WardrikConsole.Nodes

  test "a short name is a node on this machine, and a full name is itself" do
    assert Nodes.named("a") == :wardrik_a@localhost
    assert Nodes.named("wardrik@box1") == :wardrik@box1
  end

  test "a node on this machine is shown by its short name" do
    assert Nodes.display(:wardrik_a@localhost) == "a"
    assert Nodes.display(:wardrik@box1) == "wardrik@box1"
    assert Nodes.display(:wardrikd@localhost) == "wardrikd@localhost"
  end

  test "a node is found by its full name, the part before its @, or as it is shown" do
    nodes = [:wardrik_a@localhost, :wardrik_b@localhost, :wardrik@box1]

    assert Nodes.find("wardrik_b@localhost", nodes) == :wardrik_b@localhost
    assert Nodes.find("wardrik_b", nodes) == :wardrik_b@localhost
    assert Nodes.find("b", nodes) == :wardrik_b@localhost
    assert Nodes.find("wardrik", nodes) == :wardrik@box1
    assert Nodes.find("c", nodes) == nil
  end
end
