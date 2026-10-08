defmodule WardrikTUI.App.Prompt do
  @moduledoc """
  Draft history and external-editor integration for the terminal prompt.
  """
  import Breeze.View, only: [assign: 2, update_implicit: 3]

  alias WardrikTUI.App.Display
  alias WardrikTUI.App.Interaction
  alias WardrikTUI.App.TermState
  alias WardrikTUI.History
  alias WardrikTUI.View

  # Recalls an older line when the cursor is on the prompt's first line, and
  # leaves the key to the prompt otherwise, where it moves the cursor up.
  @doc false
  def older(_event, %{focused: "prompt", assigns: %{leader: nil}} = term) do
    %{value: value, cursor: cursor} = prompt(term)

    if first_line?(value, cursor), do: {:noreply, recall(term, :back)}, else: :continue
  end

  def older(_event, _term), do: :continue

  # Recalls a newer line when the cursor is on the prompt's last line.
  @doc false
  def newer(_event, %{focused: "prompt", assigns: %{leader: nil}} = term) do
    %{value: value, cursor: cursor} = prompt(term)

    if last_line?(value, cursor), do: {:noreply, recall(term, :forward)}, else: :continue
  end

  def newer(_event, _term), do: :continue

  defp prompt(term) do
    draft = term.assigns.draft

    Map.merge(
      %{value: draft, cursor: String.length(draft)},
      TermState.implicit_state(term, "prompt")
    )
  end

  defp first_line?(value, cursor), do: not String.contains?(String.slice(value, 0, cursor), "\n")

  defp last_line?(value, cursor),
    do: not String.contains?(String.slice(value, cursor, String.length(value)), "\n")

  # The list walked is the one entered: the commands when the draft starts
  # with a slash, otherwise the attached agent's prompts.
  defp recall(term, direction) do
    which = term.assigns.walking || which(term.assigns.draft)
    history = term.assigns[which]

    step =
      case direction do
        :back -> History.back(history, term.assigns.draft)
        :forward -> History.forward(history)
      end

    case step do
      :none ->
        term

      {line, history} ->
        term
        |> assign([{which, history}, {:walking, if(History.browsing?(history), do: which)}])
        |> put_draft(line)
    end
  end

  defp which("//" <> _rest), do: :history

  defp which("/" <> _rest), do: :commands

  defp which(_draft), do: :history

  # The draft as the prompt shows it, with the cursor at its end.
  def put_draft(term, line) do
    at = String.length(line)

    term
    |> assign(draft: line)
    |> update_implicit("prompt", fn {_module, state} ->
      %{state | value: line, cursor: at, preferred_column: nil}
    end)
  end

  # Records a line entered: a question in the attached agent's history, a
  # slash command in the client's; an answer to a parked call in neither.
  def remember(term, value, command) do
    term = leave(term)

    case {command, String.trim(value)} do
      {{:ask, _text}, line} ->
        assign(term, history: History.push(term.assigns.history, line))

      {_other, "/" <> _rest = line} ->
        assign(term, commands: History.push(term.assigns.commands, line))

      _answer ->
        term
    end
  end

  def leave(term) do
    assign(term,
      walking: nil,
      history: History.leave(term.assigns.history),
      commands: History.leave(term.assigns.commands)
    )
  end

  # Opens the draft in the editor, from any pane, unless one is open already.
  # The editor runs in a process of its own and answers with `{:edited, ref,
  # result}`; the agent the draft belongs to is remembered with it.
  @doc false
  def edit(_event, %{assigns: %{palette: %{}}} = term), do: {:noreply, term}

  def edit(_event, %{assigns: %{editing: nil}} = term) do
    %{draft: draft, agent_id: agent_id, editor: editor} = term.assigns
    view = self()
    ref = make_ref()
    context = %{terminal: term.terminal, server: term.server}
    # The view owns the editor and hears it exit; the TUI has no tree to start
    # it under.
    # credo:disable-for-next-line Wardrik.Credo.Check.SupervisedProcesses
    {pid, _monitor} = spawn_monitor(fn -> send(view, {:edited, ref, editor.(draft, context)}) end)

    {:noreply, term |> assign(editing: {ref, agent_id, pid}) |> Interaction.focus_pane("prompt")}
  end

  def edit(_event, term), do: {:noreply, Interaction.sync_pane(term)}

  # What the editor saved becomes the draft of the agent it was opened for:
  # the prompt when that agent is still attached, its kept view otherwise. An
  # editor that failed leaves the draft as it was and says why.
  def edited(%{assigns: %{agent_id: agent_id}} = term, agent_id, {:ok, text}),
    do: put_draft(term, text)

  def edited(term, agent_id, {:ok, text}) do
    case term.assigns.views do
      %{^agent_id => kept} ->
        kept = %{kept | draft: text, prompt: %{}}
        assign(term, views: Map.put(term.assigns.views, agent_id, kept))

      _views ->
        term
    end
  end

  def edited(term, _agent_id, {:error, {:exit, _status} = reason}),
    do: Interaction.flash(term, View.editor_failed(reason))

  def edited(term, _agent_id, {:error, reason}),
    do: Display.append(term, View.editor_failed(reason))
end
