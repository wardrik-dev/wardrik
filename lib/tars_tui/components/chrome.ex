defmodule TarsTUI.Components.Chrome do
  @moduledoc "Header, activity hints, prompt hints, and usage footer."
  use Breeze.Component
  alias Tars.Fleet
  alias TarsTUI.{Activity, Render, Text, Usage, View}
  @faint [:faint, :light_black]

  attr :model, :any, default: nil
  attr :agent_id, :any, required: true
  attr :verbose, :boolean, default: false

  def header(assigns) do
    assigns = assign(assigns, text: header_text(assigns))
    ~H'<box class="block w-full h-1 overflow-hidden">{@text}</box>'
  end

  attr :state, :map, required: true
  attr :width, :integer, required: true

  def status(assigns) do
    assigns = assign(assigns, text: status_text(assigns.state, assigns.width))
    ~H'<box class="block w-full h-1 overflow-hidden">{@text}</box>'
  end

  attr :usage, :any, required: true
  attr :queued, :integer, required: true
  attr :running, :boolean, default: false
  attr :width, :integer, required: true

  def meta(assigns) do
    assigns =
      assign(assigns,
        text:
          meta_text(
            %{usage: assigns.usage, queued: assigns.queued, running?: assigns.running},
            assigns.width
          )
      )

    ~H'<box class="block w-full h-1 overflow-hidden">{@text}</box>'
  end

  # What Enter will do with the line, said where the line is typed.
  def placeholder(%{available?: false}), do: "not running · nothing typed here is sent"

  def placeholder(%{running?: true}),
    do: "Enter steers the turn at its next boundary · Esc stops it"

  def placeholder(%{parked: [_only]}),
    do: "Enter queues behind the parked turn · y approve · n deny"

  def placeholder(%{parked: [_ | _]}),
    do: "Enter queues behind the parked turn · /approve N · /deny N · /approve all"

  def placeholder(_assigns), do: "Ask anything · /help"

  defp header_text(assigns) do
    [
      Render.tag(" tars", [:bright, :cyan]),
      if(assigns.verbose, do: Render.tag(" [trace]", :yellow), else: ""),
      Render.dim(" · #{inspect(assigns.model)} · #{inspect(assigns.agent_id)}")
    ]
    |> Enum.join()
  end

  # A brief notice takes the row while it shows.
  defp status_text(%{notice: {_ref, text}}, width),
    do: Render.line(Render.justify([" ", text], "", width))

  defp status_text(%{available?: false, agent_id: key} = assigns, width) do
    {_org, _user, name} = Fleet.parse(key)

    left =
      Text.tag(
        " ⏻ #{key} is not running · the fleet restarts it if it can · /spawn #{name} brings it back",
        :yellow
      )

    Render.line(Render.justify(left, right(assigns), width))
  end

  defp status_text(%{running?: false, parked: [_ | _] = parked} = assigns, width) do
    names = Enum.map_join(parked, ", ", fn {call, _prompt} -> call.name end)
    left = Text.tag(" ? waiting on #{names} · #{decision_keys(parked)}", [:bright, :yellow])
    Render.line(Render.justify(left, right(assigns), width))
  end

  defp status_text(%{running?: false} = assigns, width) do
    left = Text.tag(" idle · type a prompt and press Enter", @faint)
    Render.line(Render.justify(left, right(assigns), width))
  end

  defp status_text(%{leader: {_ref, _origin}} = assigns, width) do
    span = Activity.innermost(assigns.activity)
    head = [" ", Text.tag(View.spinner(assigns.frame), :cyan), " ", label(span)]
    Render.line(Render.justify(head, right(assigns), width))
  end

  defp status_text(assigns, width) do
    span = Activity.innermost(assigns.activity)
    right = [below(assigns), Text.tag([chars(assigns.chars), elapsed(assigns), " "], @faint)]
    label = Text.truncate(label(span), max(div(width, 3), 20))
    head = [" ", Text.tag(View.spinner(assigns.frame), :cyan), " ", label]
    room = width - Text.length(right) - Text.length(head) - 4
    left = [head, doing(span, assigns.thinking, room)]

    Render.line(Render.justify(left, right, width))
  end

  # The keys that matter where focus is, with word of output below the rows
  # shown when there is some.
  defp right(assigns), do: [below(assigns), hints(assigns)]

  defp below(%{unread: unread}) when unread > 0, do: View.new_below()
  defp below(_assigns), do: []

  # The keys that matter where focus is, named after the pane, or the
  # directions the leader takes.
  defp hints(%{leader: {_ref, origin}} = assigns) do
    moves =
      case origin do
        "prompt" -> ["k transcript" | if(assigns.sidebar?, do: ["l fleet"], else: [])]
        "log" -> if(assigns.sidebar?, do: ["l fleet"], else: []) ++ ["j prompt"]
        _fleet -> ["h transcript", "j prompt"]
      end

    stop = if assigns.running? or assigns.parked != [], do: ["s stop"], else: []
    Text.tag(["Ctrl-X · ", Enum.join(moves ++ stop ++ ["Esc cancel"], " · "), " "], :yellow)
  end

  defp hints(%{palette: %{step: :text}}),
    do: Text.tag("type the rest · Enter run · Backspace back · Esc close ", :yellow)

  defp hints(%{palette: %{step: :help}}),
    do: Text.tag("type to search · Up/Down scroll · Enter run a command · Esc close ", :yellow)

  defp hints(%{palette: %{step: :search}}),
    do: Text.tag("type to search · Up/Down choose · Enter go there · Esc close ", :yellow)

  defp hints(%{palette: %{step: :tool}}),
    do: Text.tag("type to filter · Up/Down choose · Enter see it in full · Esc close ", :yellow)

  defp hints(%{palette: %{}}),
    do: Text.tag("type to filter · Up/Down choose · Enter run · Esc close ", :yellow)

  defp hints(%{editing: {_ref, _agent_id, _pid}}),
    do: Text.tag("editing the prompt · the screen returns when the editor closes ", :yellow)

  defp hints(%{pane: "log"}),
    do:
      Text.tag(
        "transcript · j/k scroll · Ctrl-U/D half page · / find · t tools · y copy · i prompt · Esc back ",
        @faint
      )

  defp hints(%{pane: "fleet"}),
    do:
      Text.tag(
        "fleet · j/k · l/h expand · n/a attention · Enter connect · i prompt · Esc back ",
        @faint
      )

  defp hints(%{pane: "inspector"}),
    do: Text.tag("inspector · j/k scroll · i prompt · Esc back ", @faint)

  defp hints(%{available?: false}),
    do: Text.tag("prompt · Ctrl-X pane · Ctrl-F fleet · Ctrl-D quit ", @faint)

  defp hints(%{parked: [_ | _]}), do: Text.tag("prompt · Esc abandon · Ctrl-D quit ", @faint)
  defp hints(_assigns), do: Text.tag("prompt · Ctrl-X pane · Ctrl-F fleet · Ctrl-D quit ", @faint)

  defp decision_keys([_only]), do: "y approve · n deny"
  defp decision_keys(_several), do: "/approve N · /deny N · /approve all"

  defp label(nil), do: Text.tag("working", @faint)
  defp label(%{name: nil}), do: Text.tag("working", @faint)
  defp label(%{name: name}), do: Text.tag(name, :cyan)

  # The newest words of the reasoning, in the room left on the row.
  defp doing(%{doing: "thinking"}, thinking, room) when thinking != "" do
    Text.tag([" · ", Text.tag(newest(thinking, max(room, 8)), :italic)], @faint)
  end

  defp doing(%{doing: doing}, _thinking, _room) when is_binary(doing) do
    Text.tag(" · #{doing}", @faint)
  end

  defp doing(_span, _thinking, _room), do: []

  # The last `room` columns of `text`, cut at a word and marked as a cut.
  defp newest(text, room) do
    text = Render.squash(text)
    over = String.length(text) - room

    if over > 0 do
      tail = String.slice(text, over + 1, room - 1)

      case String.split(tail, " ", parts: 2) do
        [_partial, words] -> "…" <> words
        [_whole] -> "…" <> tail
      end
    else
      text
    end
  end

  defp chars(0), do: ""
  defp chars(n), do: "#{Usage.count(n)} chars · "

  defp meta_text(assigns, width) do
    usage = Usage.summary(assigns.usage)
    left = Text.tag(if(usage == "", do: "", else: " observed here · " <> usage), @faint)
    Render.line(Render.justify(left, Text.tag(queued(assigns), @faint), width))
  end

  defp elapsed(%{started_at: started_at}) when is_integer(started_at) do
    "#{div(System.monotonic_time(:millisecond) - started_at, 1_000)}s"
  end

  defp elapsed(_assigns), do: ""

  defp queued(%{queued: 0}), do: ""
  defp queued(%{queued: 1, running?: true}), do: "1 message steering the turn "
  defp queued(%{queued: n, running?: true}), do: "#{n} messages steering the turn "
  defp queued(%{queued: 1}), do: "1 message queued behind the parked turn "
  defp queued(%{queued: n}), do: "#{n} messages queued behind the parked turn "
end
