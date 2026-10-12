defmodule WardrikTUI.Fleet do
  @moduledoc """
  Pure rendering for the fleet panel in `WardrikTUI.App`.

  The panel is a Breeze list with one row per agent: a glyph for what it is
  doing, its name, how many delegations its turn has going and has started,
  what is queued behind it, and the node it is running on when that is not
  this one. An idle agent whose last turn failed says so, and one that
  finished a turn while the client was elsewhere says it has a new result. An
  agent under the same org and user as the one the client is attached to is
  named alone, unless another agent shares its name; any other shows its whole
  ID, with the org and user faint. The agent the client is attached to is
  marked.

  An agent needs attention when it is waiting on a person, or when it has a
  result or a failure the client has not looked at. `attention?/2` decides,
  and the heading counts.

  An expanded agent is followed by one row per delegation of its current
  turn, as a tree: a glyph for how it is going, its name, and how long it has
  taken.
  """

  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix
  alias Wardrik.Delegation
  alias Wardrik.Fleet.Member
  alias WardrikTUI.Render
  alias WardrikTUI.Text

  @faint [:faint, :light_black]

  @glyphs %{idle: "○", running: "◐", parked: "?"}
  @colours %{idle: @faint, running: :cyan, parked: :yellow}

  @delegation_glyphs %{running: "◐", ok: "✓", error: "✗"}
  @delegation_colours %{running: :cyan, ok: :green, error: :red}

  @doc "An expanded agent's delegations, or `nil` when it is collapsed."
  def expanded_delegations(%{expanded: expanded} = assigns, id) do
    if MapSet.member?(expanded, id), do: followed(assigns, id), else: nil
  end

  @doc """
  An agent's delegations as this client has followed them: the attached
  agent's with its conversation, any other's from its lifecycle events.
  """
  def followed(%{agent_id: id, delegations: delegations}, id), do: delegations
  def followed(%{followed: followed}, id), do: Map.get(followed, id, Delegation.new())

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
  @spec attention?(Member.t(), %{AgentID.t() => term()}) :: boolean()
  def attention?(%Member{status: :parked}, _unseen), do: true
  def attention?(%Member{id: id}, unseen), do: Map.has_key?(unseen, id)

  @doc "The names more than one agent goes by."
  @spec ambiguous([Member.t()]) :: MapSet.t(String.t())
  def ambiguous(members) do
    members
    |> Enum.frequencies_by(& &1.id.name)
    |> Enum.filter(fn {_name, count} -> count > 1 end)
    |> MapSet.new(fn {name, _count} -> name end)
  end

  @doc """
  One agent's row, clipped to `width`.

  `attached` is the ID of the agent the client is watching, which is marked
  rather than listed differently. Options: `:ambiguous`, the names shared by
  several agents, which are shown as whole IDs; `:unseen`, how the agent's
  last turn ended if the client has not looked, `:ok` or `:failed`;
  `:delegations`, how many its turn has going and has started, as
  `Wardrik.Delegation.summary/1` counts them.
  """
  @spec row(Member.t(), AgentID.t(), pos_integer(), keyword()) :: String.t()
  def row(%Member{} = member, attached, width, opts \\ []) do
    row = Text.truncate(text(member, attached, opts), width)
    Render.line(if(Keyword.get(opts, :pad?, false), do: fill(row, width), else: row))
  end

  @doc """
  `text` filled to `width` with faint spaces, for a row drawn over other
  content: the compositor keeps a styled space where it would let an unstyled
  gap show what lies beneath.
  """
  @spec fill(Text.t(), pos_integer()) :: Text.t()
  def fill(text, width) do
    [text, Text.tag(String.duplicate(" ", max(width - Text.length(text), 0)), @faint)]
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
        member.id == attached -> Text.tag("›", [:bright, :cyan])
        member.status == :parked or unseen != nil -> Text.tag("!", [:bright, :yellow])
        true -> " "
      end

    [
      marker,
      " ",
      Text.tag(@glyphs[member.status], @colours[member.status]),
      " ",
      label(member, attached, Keyword.get(opts, :ambiguous, MapSet.new())),
      suffix(member, Keyword.get(opts, :delegations, %{active: 0, total: 0})),
      new_result(unseen)
    ]
  end

  defp new_result(:ok), do: Text.tag(" new result", :green)
  defp new_result(_other), do: []

  # The name alone inside the attached agent's org and user; the whole ID
  # anywhere else, and wherever two agents go by the same name.
  defp label(%Member{id: id} = member, attached, ambiguous) do
    named = Text.tag(name(id), name_colour(member, attached))

    if {id.org, id.user} == {attached.org, attached.user} and
         not MapSet.member?(ambiguous, id.name),
       do: named,
       else: [Text.tag(scope(id), @faint), named]
  end

  defp scope(%AgentID{org: org, user: user}), do: to_string(Prefix.new!(org: org, user: user))

  defp name(%AgentID{name: name, external_id: nil}), do: name
  defp name(%AgentID{name: name, external_id: external_id}), do: name <> "/" <> external_id

  defp name_colour(%Member{id: id}, id), do: [:bright]
  defp name_colour(_member, _attached), do: []

  # What distinguishes one row from another: what it is waiting on, its
  # delegations, how much is queued, how its last turn went, and which node it
  # is on when that is not this one.
  defp suffix(%Member{status: :parked, waiting_on: [_ | _] = names} = member, delegations) do
    [
      Text.tag([" ", Enum.join(names, ",")], :yellow),
      delegations(delegations),
      elsewhere(member.node)
    ]
  end

  defp suffix(%Member{} = member, delegations) do
    [delegations(delegations), queued(member), failed(member), elsewhere(member.node)]
  end

  defp delegations(%{total: 0}), do: []

  defp delegations(%{active: active, total: total}) do
    Text.tag(" sub #{active}/#{total}", if(active > 0, do: :cyan, else: @faint))
  end

  defp queued(%Member{pending: 0}), do: []
  defp queued(%Member{pending: pending}), do: Text.tag(" +#{pending}", @faint)

  defp failed(%Member{status: :idle, outcome: :failed}), do: Text.tag(" failed", :red)
  defp failed(_member), do: []

  defp elsewhere(nil), do: Text.tag(" asleep", @faint)

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
        Text.tag(to_string(member.id), :bright),
        Text.tag(
          " #{Member.label(member)}#{if member.asleep, do: "", else: " on #{member.node}"}",
          @faint
        )
      ]
    end)
  end
end
