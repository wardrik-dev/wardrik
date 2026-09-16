defmodule TarsTUI.Fleet do
  @moduledoc """
  Pure rendering for the fleet panel in `TarsTUI.App`.

  The panel is a Breeze list with one row per agent: a glyph for what it is
  doing, its name, and the node it is running on when that is not this one.
  An agent under the same org and user as the one the client is attached to
  is named alone; any other shows its whole key, with the scope faint. The
  agent the client is attached to is marked.
  """

  alias Tars.Fleet.Member
  alias TarsTUI.Render
  alias TarsTUI.Text

  @faint [:faint, :light_black]

  @glyphs %{idle: "○", running: "◐", parked: "?"}
  @colours %{idle: @faint, running: :cyan, parked: :yellow}

  # The gutter before the panel, the list's border and selection column, and
  # a space on the right.
  @chrome 5
  @min_width 22
  @max_width 40

  @doc "The heading above the list, clipped to `width`."
  @spec heading([Member.t()], pos_integer()) :: String.t()
  def heading(members, width) do
    Render.line(Text.truncate(Text.tag(" fleet · #{length(members)}", @faint), width))
  end

  @doc """
  One agent's row, clipped to `width`.

  `attached` is the key of the agent the client is watching, which is marked
  rather than listed differently.
  """
  @spec row(Member.t(), String.t(), pos_integer()) :: String.t()
  def row(%Member{} = member, attached, width) do
    Render.line(Text.truncate(text(member, attached), width))
  end

  @doc """
  The width the panel needs to show every row whole, between
  #{@min_width} and #{@max_width} columns. `attached` decides which rows are
  named alone.
  """
  @spec width([Member.t()], String.t()) :: pos_integer()
  def width(members, attached \\ "") do
    members
    |> Enum.map(&(&1 |> text(attached) |> Text.plain() |> String.length()))
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(@chrome)
    |> max(@min_width)
    |> min(@max_width)
  end

  defp text(%Member{} = member, attached) do
    marker = if member.key == attached, do: Text.tag("›", [:bright, :cyan]), else: " "

    [
      marker,
      " ",
      Text.tag(@glyphs[member.status], @colours[member.status]),
      " ",
      label(member, attached),
      suffix(member)
    ]
  end

  # The name alone inside the attached agent's org and user; the whole key
  # anywhere else, so two agents called the same thing are told apart.
  defp label(%Member{org: org, user: user, name: name} = member, attached) do
    case scope(attached) do
      {^org, ^user} ->
        Text.tag(name, name_colour(member, attached))

      _elsewhere ->
        [Text.tag(prefix(member), @faint), Text.tag(name, name_colour(member, attached))]
    end
  end

  defp scope(key) do
    case String.split(key, "/") do
      [org, user, _name] -> {identity(org), identity(user)}
      _other -> nil
    end
  end

  defp identity("_"), do: nil
  defp identity(segment), do: segment

  defp prefix(%Member{key: key, name: name}) do
    String.slice(key, 0, String.length(key) - String.length(name))
  end

  defp name_colour(%Member{key: key}, key), do: [:bright]
  defp name_colour(_member, _attached), do: []

  # What distinguishes one row from another: how much is queued, what it is
  # waiting on, and which node it is on when that is not this one.
  defp suffix(%Member{status: :parked, waiting_on: [_ | _] = names}) do
    Text.tag([" ", Enum.join(names, ",")], :yellow)
  end

  defp suffix(%Member{pending: pending, node: node}) when pending > 0 do
    [Text.tag(" +#{pending}", @faint), elsewhere(node)]
  end

  defp suffix(%Member{node: node}), do: elsewhere(node)

  defp elsewhere(node) do
    if node == node(), do: [], else: Text.tag(" @#{short(node)}", @faint)
  end

  defp short(node), do: node |> Atom.to_string() |> String.split("@", parts: 2) |> hd()

  @doc "The fleet as transcript lines, for `/fleet`."
  @spec listing([Member.t()]) :: [Text.t()]
  def listing([]), do: [Text.tag("  no agents running", @faint)]

  def listing(members) do
    Enum.map(members, fn member ->
      [
        Text.tag("  #{@glyphs[member.status]} ", @colours[member.status]),
        Text.tag(member.key, :bright),
        Text.tag(" #{member.status} on #{member.node}", @faint)
      ]
    end)
  end
end
