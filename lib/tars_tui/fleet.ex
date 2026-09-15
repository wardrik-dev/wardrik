defmodule TarsTUI.Fleet do
  @moduledoc """
  Pure rendering for the fleet panel in `TarsTUI.App`.

  One row per agent: a glyph for what it is doing, its name, and the node it is
  running on when that is not this one. The agent the client is attached to is
  marked.
  """

  alias Tars.Fleet.Member
  alias TarsTUI.Render
  alias TarsTUI.Text

  @faint [:faint, :light_black]

  @glyphs %{idle: "○", running: "◐", parked: "?", unknown: "·"}
  @colours %{idle: @faint, running: :cyan, parked: :yellow, unknown: @faint}

  @doc """
  The panel as one string per row, clipped to `width`.

  `attached` is the key of the agent the client is watching, which is marked
  rather than listed differently.
  """
  @spec panel([Member.t()], String.t(), pos_integer(), pos_integer()) :: String.t()
  def panel(members, attached, width, height) do
    rows =
      [heading(members, width)] ++
        Enum.map(members, &row(&1, attached, width))

    rows
    |> pad(height)
    |> Enum.take(height)
    |> Enum.join("\n")
  end

  defp heading(members, width) do
    Render.line(Text.truncate(Text.tag(" fleet · #{length(members)}", @faint), width))
  end

  defp row(%Member{} = member, attached, width) do
    marker = if member.key == attached, do: Text.tag("›", [:bright, :cyan]), else: " "

    row = [
      marker,
      " ",
      Text.tag(@glyphs[member.status] || @glyphs.unknown, @colours[member.status] || @faint),
      " ",
      Text.tag(member.name, name_colour(member, attached)),
      suffix(member)
    ]

    Render.line(Text.truncate(row, width))
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

  defp pad(rows, height) do
    rows ++ List.duplicate("", max(height - length(rows), 0))
  end

  @doc "The fleet as transcript lines, for `/fleet`."
  @spec listing([Member.t()]) :: [Text.t()]
  def listing([]), do: [Text.tag("  no agents running", @faint)]

  def listing(members) do
    Enum.map(members, fn member ->
      [
        Text.tag("  #{@glyphs[member.status] || @glyphs.unknown} ", @colours[member.status]),
        Text.tag(member.key, :bright),
        Text.tag(" #{member.status} on #{member.node}", @faint)
      ]
    end)
  end
end
