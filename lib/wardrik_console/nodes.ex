defmodule WardrikConsole.Nodes do
  @moduledoc """
  Nodes as a person names them.

  Several nodes of a cluster can run on one machine, each under a short name:
  `a` is `wardrik_a@localhost`. A node anywhere else goes by its full name.
  `named/1` reads a name as `cluster.nodes` and `--node` give one, `display/1`
  shows a node the same way, and `find/2` looks a node up among those
  connected however it was written.
  """

  @local_host "localhost"

  @doc """
  The node a name in `cluster.nodes` or `--node` stands for: `a` is
  `wardrik_a@localhost`, one of several on this machine, and a full name is
  itself.
  """
  @spec named(String.t()) :: node()
  def named(name) when is_binary(name) do
    if String.contains?(name, "@"),
      # reach:disable-next-line unsafe_atom_creation -- a node name from config.yaml or --node
      do: String.to_atom(name),
      # reach:disable-next-line unsafe_atom_creation -- a node name from config.yaml or --node
      else: String.to_atom("wardrik_#{name}@#{@local_host}")
  end

  @doc "How a node is shown: by its short name where it is one of several on this machine."
  @spec display(node()) :: String.t()
  def display(node) when is_atom(node) do
    case String.split(Atom.to_string(node), "@") do
      ["wardrik_" <> name, @local_host] -> name
      _other -> Atom.to_string(node)
    end
  end

  @doc """
  The node among `nodes` that `name` names, by its full name, by the part
  before its `@`, or as `display/1` shows it, and `nil` where none does.

  No atom is made from `name`, so it can be anything a person typed.
  """
  @spec find(String.t(), [node()]) :: node() | nil
  def find(name, nodes) when is_binary(name) and is_list(nodes) do
    Enum.find(nodes, fn node ->
      [short | _host] = String.split(Atom.to_string(node), "@", parts: 2)
      name in [Atom.to_string(node), short, display(node)]
    end)
  end
end
