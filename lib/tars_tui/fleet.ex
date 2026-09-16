defmodule TarsTUI.Fleet do
  @moduledoc """
  Pure rendering for the fleet panel in `TarsTUI.App`.

  The panel is a Breeze list with one row per agent: a glyph for what it is
  doing, its name, how many delegations its turn has going and has started,
  what is queued behind it, and the node it is running on when that is not
  this one. An idle agent whose last turn failed says so. An agent under the
  same org and user as the one the client is attached to is named alone; any
  other shows its whole key, with the scope faint. The agent the client is
  attached to is marked.

  An expanded agent is followed by one row per delegation of its current
  turn, as a tree: a glyph for how it is going, its name, and how long it has
  taken.
  """

  alias Tars.Delegation
  alias Tars.Fleet.Member
  alias TarsTUI.Render
  alias TarsTUI.Text

  @faint [:faint, :light_black]

  @glyphs %{idle: "○", running: "◐", parked: "?"}
  @colours %{idle: @faint, running: :cyan, parked: :yellow}

  @delegation_glyphs %{running: "◐", ok: "✓", error: "✗"}
  @delegation_colours %{running: :cyan, ok: :green, error: :red}

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
  named alone, and `extra` is any other row the panel shows, such as
  `delegation/4` builds.
  """
  @spec width([Member.t()], String.t(), [Text.t()]) :: pos_integer()
  def width(members, attached \\ "", extra \\ []) do
    members
    |> Enum.map(&text(&1, attached))
    |> Kernel.++(extra)
    |> Enum.map(&(&1 |> Text.plain() |> String.length()))
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(@chrome)
    |> max(@min_width)
    |> min(@max_width)
  end

  @doc """
  One delegation as a row of the tree under its agent, indented by `depth`
  delegations above it, and clipped to `width`. `last?` closes the branch.
  `now` is the system time in milliseconds.
  """
  @spec delegation_row(
          Delegation.delegation(),
          non_neg_integer(),
          boolean(),
          integer(),
          pos_integer()
        ) ::
          String.t()
  def delegation_row(record, depth, last?, now, width) do
    Render.line(Text.truncate(delegation(record, depth, last?, now), width))
  end

  @doc "The text of `delegation_row/5`, unclipped."
  @spec delegation(Delegation.delegation(), non_neg_integer(), boolean(), integer()) :: Text.t()
  def delegation(record, depth, last?, now) do
    [
      "  ",
      String.duplicate("  ", depth),
      Text.tag(if(last?, do: "└ ", else: "├ "), @faint),
      Text.tag(@delegation_glyphs[record.status], @delegation_colours[record.status]),
      " ",
      Text.tag(record.name || "delegate", if(record.status == :running, do: [], else: @faint)),
      Text.tag(" #{seconds(Delegation.elapsed_ms(record, now))}", @faint)
    ]
  end

  defp seconds(ms) when ms < 1_000, do: "#{ms}ms"
  defp seconds(ms), do: "#{Float.round(ms / 1_000, 1)}s"

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

  # What distinguishes one row from another: what it is waiting on, its
  # delegations, how much is queued, how its last turn went, and which node it
  # is on when that is not this one.
  defp suffix(%Member{status: :parked, waiting_on: [_ | _] = names} = member) do
    [Text.tag([" ", Enum.join(names, ",")], :yellow), delegations(member), elsewhere(member.node)]
  end

  defp suffix(%Member{} = member) do
    [delegations(member), queued(member), failed(member), elsewhere(member.node)]
  end

  defp delegations(%Member{delegations: %{total: 0}}), do: []

  defp delegations(%Member{delegations: %{active: active, total: total}}) do
    Text.tag(" sub #{active}/#{total}", if(active > 0, do: :cyan, else: @faint))
  end

  defp queued(%Member{pending: 0}), do: []
  defp queued(%Member{pending: pending}), do: Text.tag(" +#{pending}", @faint)

  defp failed(%Member{status: :idle, outcome: :failed}), do: Text.tag(" failed", :red)
  defp failed(_member), do: []

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
