defmodule TarsTUI.Fleet do
  @moduledoc """
  Pure rendering for the fleet panel in `TarsTUI.App`.

  The panel is a Breeze list with one row per agent: a glyph for what it is
  doing, its name, how many delegations its turn has going and has started,
  what is queued behind it, and the node it is running on when that is not
  this one. An idle agent whose last turn failed says so, and one that
  finished a turn while the client was elsewhere says it has a new result. An
  agent under the same org and user as the one the client is attached to is
  named alone, unless another agent shares its name; any other shows its whole
  key, with the scope faint. The agent the client is attached to is marked.

  An agent needs attention when it is waiting on a person, or when it has a
  result or a failure the client has not looked at. `attention?/2` decides,
  and the heading counts.

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

  @doc """
  The heading above the list, clipped to `width`: how many agents are shown of
  how many there are, how many need attention, and the filter in force.
  """
  @spec heading(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          String.t(),
          pos_integer()
        ) ::
          String.t()
  def heading(shown, total, attention, filter, width) do
    count = if shown == total, do: "#{total}", else: "#{shown}/#{total}"

    text = [
      Text.tag(" fleet · #{count}", @faint),
      if(attention > 0, do: Text.tag(" · #{attention} need attention", :yellow), else: []),
      if(filter == "", do: [], else: Text.tag(" · #{filter}", :cyan))
    ]

    Render.line(Text.truncate(text, width))
  end

  @doc """
  Whether an agent needs a person: it is waiting on a call, or `unseen` holds
  how a turn ended while the client was elsewhere.
  """
  @spec attention?(Member.t(), %{String.t() => term()}) :: boolean()
  def attention?(%Member{status: :parked}, _unseen), do: true
  def attention?(%Member{key: key}, unseen), do: Map.has_key?(unseen, key)

  @doc "The names more than one agent goes by."
  @spec ambiguous([Member.t()]) :: MapSet.t(String.t())
  def ambiguous(members) do
    members
    |> Enum.frequencies_by(& &1.name)
    |> Enum.filter(fn {_name, count} -> count > 1 end)
    |> MapSet.new(fn {name, _count} -> name end)
  end

  @doc """
  One agent's row, clipped to `width`.

  `attached` is the key of the agent the client is watching, which is marked
  rather than listed differently. Options: `:ambiguous`, the names shared by
  several agents, which are shown as whole keys; `:unseen`, how the agent's
  last turn ended if the client has not looked, `:ok` or `:failed`.
  """
  @spec row(Member.t(), String.t(), pos_integer(), keyword()) :: String.t()
  def row(%Member{} = member, attached, width, opts \\ []) do
    Render.line(Text.truncate(text(member, attached, opts), width))
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
      Text.tag(" #{Text.duration(Delegation.elapsed_ms(record, now))}", @faint)
    ]
  end

  defp text(%Member{} = member, attached, opts) do
    unseen = Keyword.get(opts, :unseen)

    marker =
      cond do
        member.key == attached -> Text.tag("›", [:bright, :cyan])
        member.status == :parked or unseen != nil -> Text.tag("!", [:bright, :yellow])
        true -> " "
      end

    [
      marker,
      " ",
      Text.tag(@glyphs[member.status], @colours[member.status]),
      " ",
      label(member, attached, Keyword.get(opts, :ambiguous, MapSet.new())),
      suffix(member),
      new_result(unseen)
    ]
  end

  defp new_result(:ok), do: Text.tag(" new result", :green)
  defp new_result(_other), do: []

  # The name alone inside the attached agent's org and user; the whole key
  # anywhere else, and wherever two agents go by the same name.
  defp label(%Member{org: org, user: user, name: name} = member, attached, ambiguous) do
    case scope(attached) do
      {^org, ^user} when not is_map_key(ambiguous.map, name) ->
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
