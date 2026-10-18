defmodule WardrikTUI.Components.Chrome do
  @moduledoc "Header, activity hints, prompt hints, and usage footer."
  use Breeze.Component
  alias Wardrik.Agent.Activity.Presenter
  alias Wardrik.Event
  alias WardrikTUI.{Render, Text, Usage, View}
  @faint [:faint, :light_black]

  # The gutter before the spinner, and the spinner's own column.
  @spinner_columns 2
  # The elapsed count, right-aligned, with a column of margin after it.
  @elapsed_columns 7

  attr :model, :any, default: nil
  attr :agent_id, :any, required: true
  attr :verbose, :boolean, default: false

  def header(assigns) do
    assigns = assign(assigns, text: header_text(assigns))
    ~H'<box class="block w-full h-1 overflow-hidden">{@text}</box>'
  end

  attr :state, :map, required: true
  attr :width, :integer, required: true

  @doc """
  The activity row: what the agent is doing, in the words of the session's
  `Wardrik.Agent.Activity.Presenter`.

  While a turn runs the row opens with `WardrikTUI.Spinner` and closes with
  `WardrikTUI.Elapsed`. Breeze animates both as decorations: the glyph and the
  count are patched into the frame already drawn, rather than redrawn by this
  view.
  """
  def status(assigns) do
    spinning? = spinning?(assigns.state)
    since = if spinning?, do: assigns.state.started_at
    room = assigns.width - if(spinning?, do: @spinner_columns + @elapsed_columns, else: 0)

    assigns =
      assign(assigns,
        spinning?: spinning?,
        since: since,
        elapsed_columns: @elapsed_columns,
        gutter_class: "inline h-1 w-#{@spinner_columns - 1}",
        elapsed_class: "inline h-1 w-#{@elapsed_columns} overflow-hidden text-8",
        text: status_text(assigns.state, room)
      )

    ~H"""
    <box class="inline w-full h-1 overflow-hidden">
      <box :if={@spinning?} class={@gutter_class}>
      </box>
      <box
        :if={@spinning?}
        id="activity"
        implicit={WardrikTUI.Spinner}
        spinner-active={true}
        class="inline w-1 h-1 overflow-hidden text-secondary"
      >
      </box>
      <box class="inline h-1 overflow-hidden">{@text}</box>
      <box
        :if={@spinning?}
        id="elapsed"
        implicit={WardrikTUI.Elapsed}
        elapsed-since={@since}
        elapsed-width={@elapsed_columns}
        class={@elapsed_class}
      >
      </box>
    </box>
    """
  end

  # The row spins while a turn is running and nothing has taken the row from it.
  defp spinning?(%{notice: nil, available?: true, running?: true}), do: true
  defp spinning?(_state), do: false

  attr :usage, :any, required: true
  attr :width, :integer, required: true

  def meta(assigns) do
    assigns = assign(assigns, text: meta_text(assigns.usage, assigns.width))

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
      Render.tag(" wardrik", [:bright, :cyan]),
      if(assigns.verbose, do: Render.tag(" [trace]", :yellow), else: ""),
      Render.dim(" · #{model_name(assigns.model)} · #{assigns.agent_id}")
    ]
    |> Enum.join()
  end

  # A model as a person names it: `provider:model`.
  defp model_name(spec) when is_binary(spec), do: spec

  defp model_name({provider, opts}) when is_atom(provider) and is_list(opts),
    do: "#{provider}:#{opts[:model] || opts[:id]}"

  defp model_name(spec), do: inspect(spec)

  # A brief notice takes the row while it shows.
  defp status_text(%{notice: {_ref, text}}, width),
    do: Render.line(Render.justify([" ", text], "", width))

  defp status_text(%{available?: false, agent_id: id} = assigns, width) do
    left =
      Text.tag(
        " ⏻ #{id} is not running · the fleet restarts it if it can · /spawn #{id} brings it back",
        :yellow
      )

    Render.line(Render.justify(left, right(assigns), width))
  end

  defp status_text(%{running?: false, parked: [_ | _] = parked} = assigns, width) do
    left = Text.tag([" ? ", label(assigns), " · ", decision_keys(parked)], [:bright, :yellow])
    Render.line(Render.justify(left, right(assigns), width))
  end

  defp status_text(%{running?: false} = assigns, width) do
    left = Text.tag([" ", label(assigns), " · type a prompt and press Enter"], @faint)
    Render.line(Render.justify(left, right(assigns), width))
  end

  defp status_text(%{leader: {_ref, _origin}} = assigns, width) do
    head = [" ", Text.tag(label(assigns), :cyan)]
    Render.line(Render.justify(head, right(assigns), width))
  end

  defp status_text(assigns, width) do
    right = [below(assigns), Text.tag(chars(assigns.chars), @faint)]
    head = [" ", Text.tag(label(assigns), :cyan)]
    room = width - Text.length(right) - Text.length(head) - 4
    left = [head, reasoning(assigns.agent_activity.doing, assigns.thinking, room)]

    Render.line(Render.justify(left, right, width))
  end

  defp label(%{presenter: presenter, agent_activity: activity}),
    do: Presenter.label(presenter, activity)

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

  # The newest words of the reasoning while the model is asked, in the room
  # left on the row.
  defp reasoning(%Event.ModelStarted{}, thinking, room) when thinking != "" do
    Text.tag([" · ", Text.tag(newest(thinking, max(room, 8)), :italic)], @faint)
  end

  defp reasoning(_doing, _thinking, _room), do: []

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
  defp chars(n), do: "#{Usage.count(n)} chars"

  defp meta_text(usage, width) do
    usage = Usage.summary(usage)
    left = Text.tag(if(usage == "", do: "", else: " observed here · " <> usage), @faint)
    Render.line(Render.justify(left, "", width))
  end
end
