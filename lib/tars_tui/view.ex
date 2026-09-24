defmodule TarsTUI.View do
  @moduledoc """
  Pure rendering for `TarsTUI.App`.

  Prose is written once and never redrawn, and nothing wraps it: the terminal
  soft-wraps it and a resize reflows it correctly.

  Structured rows are clipped instead. A span line is a label rather than
  prose, and the tree only reads as a tree while each node occupies one row —
  a fan-out branch named after a paragraph would otherwise take five.

  The span tree is indentation rather than a drawn block. A span prints one
  line when it opens and one when it closes, each indented by its depth, so the
  shape of a turn is legible in scrollback without anything being repainted.
  """

  alias TarsTUI.Activity
  alias TarsTUI.Render
  alias TarsTUI.Text

  @default_width 100
  @faint [:faint, :light_black]
  @doc "One line of the model's reasoning, for a transcript that wants it."
  @spec reasoning(Text.t()) :: Text.t()
  def reasoning(line), do: [Text.tag(["┊ ", line], @faint), "\n"]

  @doc """
  One span as a line of the tree, indented by `depth`.

  A running span shows no time; a settled one shows what it took and how it
  went. Clipped to one row, whatever it was named.
  """
  @spec span(Activity.span(), non_neg_integer(), integer(), pos_integer()) :: Text.t()
  def span(span, depth, now, width \\ @default_width) do
    indent = String.duplicate("  ", depth)

    row = [
      Text.tag([glyph(span), " ", span.name || "?"], colour(span)),
      cause(span),
      took(span, now)
    ]

    [indent, Text.truncate(row, room(width - String.length(indent))), "\n"]
  end

  @doc "A low-level event as a trace line, or `nil` when it is not worth one."
  @spec trace(tuple()) :: Text.t() | nil
  def trace({:model_started, model_spec}),
    do: line("model", inspect(model_spec), :cyan)

  def trace({:model_finished, :ok, ms}),
    do: line("model", "ok #{Text.duration(ms)}", :cyan)

  def trace({:model_finished, {:error, reason}, ms}),
    do: line("model", "#{inspect(reason)} #{Text.duration(ms)}", :red)

  def trace({:meta, meta}), do: line("meta", inspect(meta), @faint)
  def trace({:tool_started, id, name}), do: line("tool", "#{name} #{id}", :yellow)

  def trace({:tool_finished, id, name, {:ok, output}}),
    do: line("tool", "#{name} #{id} ok #{payload(output)}", :yellow)

  def trace({:tool_finished, id, name, {:error, why}}),
    do: line("tool", "#{name} #{id} #{inspect(why)}", :red)

  def trace({:tool_denied, id, name, reason}),
    do: line("deny", "#{name} #{id} #{reason}", :red)

  def trace({:tool_parked, id, name, prompt}),
    do: line("ask", "#{name} #{id} #{prompt}", :yellow)

  def trace({:delegation_started, task}), do: line("deleg", Render.squash(task), :magenta)

  def trace({:delegation_finished, {:ok, _text}, ms}),
    do: line("deleg", "ok #{Text.duration(ms)}", :magenta)

  def trace({:delegation_finished, {:error, reason}, ms}),
    do: line("deleg", "#{inspect(reason)} #{Text.duration(ms)}", :red)

  def trace({:turn_parked, calls}),
    do:
      line(
        "turn",
        "waiting on #{Enum.map_join(calls, ", ", fn {call, _} -> call.name end)}",
        :yellow
      )

  def trace({:turn_resumed, decisions}),
    do: line("turn", "resumed · #{map_size(decisions)} call(s) answered", :cyan)

  def trace({:deadline_reached, count}),
    do: line("turn", "deadline reached after #{count} message(s)", :yellow)

  def trace({:turn_started, questions}), do: line("turn", Enum.join(questions, " | "), :cyan)
  def trace({:turn_finished, messages}), do: line("turn", "#{length(messages)} message(s)", :cyan)

  def trace({:turn_interrupted, stats}),
    do: line("turn", "interrupted #{inspect(stats)}", :yellow)

  def trace(_payload), do: nil

  @doc "What an interrupt stopped, so a kill switch is never silent."
  @spec interrupted(map()) :: Text.t()
  def interrupted(stats) do
    [Text.tag(["\n■ stopped", detail(stats), "\n"], :yellow)]
  end

  defp detail(%{resolution: :idle}), do: " · nothing was running"

  defp detail(%{resolution: :abandoned} = stats),
    do: [
      " · the approval was abandoned · ",
      Text.duration(stats.elapsed_ms),
      dropped(stats.dropped)
    ]

  defp detail(stats) do
    [
      " · ",
      Text.duration(stats.elapsed_ms),
      if(stats.resolution == :killed, do: " · killed", else: ""),
      dropped(stats.dropped)
    ]
  end

  defp dropped(0), do: ""
  defp dropped(1), do: " · 1 queued message dropped"
  defp dropped(n), do: " · #{n} queued messages dropped"

  @spec error(term()) :: Text.t()
  def error(reason), do: Text.tag("\n✗ #{inspect(reason)}\n", :red)

  @doc """
  What the agent is waiting for, so a parked turn never looks like a hung one.

  A turn that stopped to ask shows no spinner and produces no further output,
  which is indistinguishable from a crash unless the reason is on screen. It is
  also the one moment the agent needs something from the person watching, so it
  is the loudest thing the transcript prints, and it says which keys answer it.
  """
  @spec parked([{Tars.Tool.call(), String.t()}]) :: Text.t()
  def parked(calls) do
    [
      "\n",
      bar([Text.tag("APPROVAL NEEDED", [:bright, :yellow]), several(calls)]),
      calls |> Enum.with_index(1) |> Enum.map(&asked/1),
      bar(answers(calls)),
      "\n"
    ]
  end

  defp several([_only]), do: []
  defp several(calls), do: Text.tag(" · #{length(calls)} calls, each decided on its own", @faint)

  defp asked({{call, prompt}, index}) do
    [
      bar([
        Text.tag("#{index}  ", @faint),
        Text.tag(call.name, [:bright, :yellow]),
        Text.tag(["  ", args(call)], @faint)
      ]),
      bar([Text.tag(["   ", prompt], :yellow)]),
      bar([Text.tag(["   ", call.id], @faint)])
    ]
  end

  defp answers([_only]) do
    [
      Text.tag("y", [:bright, :yellow]),
      Text.tag(" approve · ", @faint),
      Text.tag("n", [:bright, :yellow]),
      Text.tag(" deny · ", @faint),
      Text.tag("n <reason>", [:bright, :yellow]),
      Text.tag(" deny and say why · ", @faint),
      Text.tag("Esc", [:bright, :yellow]),
      Text.tag(" abandon", @faint)
    ]
  end

  defp answers(_calls) do
    [
      Text.tag("/approve N", [:bright, :yellow]),
      Text.tag(" approve one · ", @faint),
      Text.tag("/deny N <reason>", [:bright, :yellow]),
      Text.tag(" deny one · ", @faint),
      Text.tag("/approve all", [:bright, :yellow]),
      Text.tag(" approve every one · ", @faint),
      Text.tag("Esc", [:bright, :yellow]),
      Text.tag(" abandon", @faint)
    ]
  end

  defp bar(content), do: [Text.tag("  ▌ ", :yellow), content, "\n"]

  # What a tool actually returned, so the transcript holds the deterministic
  # answer next to whatever the model went on to say about it. Truncated,
  # because a trace line is a row and a tool result is not.
  @payload_chars 400

  defp payload(output) do
    output
    |> encode()
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, @payload_chars)
  end

  defp encode(output) when is_binary(output), do: output

  # A tool result reaches the model as JSON, so it almost always encodes. A
  # value that does not is still worth showing, as Elixir rather than nothing.
  defp encode(output) do
    JSON.encode!(output)
  rescue
    _error in [Protocol.UndefinedError, ArgumentError] -> inspect(output)
  end

  defp args(%{arguments: args}) when map_size(args) == 0, do: ""
  defp args(%{arguments: args}), do: Enum.map_join(args, "  ", fn {k, v} -> "#{k}=#{v}" end)

  @doc """
  What a person decided, echoed so the transcript records who chose what, and
  how many calls are still waiting.
  """
  @spec decided(
          [{Tars.Tool.call(), String.t()}],
          :approve | {:deny, String.t()},
          non_neg_integer()
        ) ::
          Text.t()
  def decided(calls, decision, remaining \\ 0) do
    names = Enum.map_join(calls, ", ", fn {call, _prompt} -> call.name end)

    line =
      case decision do
        :approve -> Text.tag(["  ▌ approved ", names], :green)
        {:deny, reason} -> Text.tag(["  ▌ denied ", names, " · ", reason], :red)
      end

    [line, waiting(remaining), "\n\n"]
  end

  defp waiting(0), do: []
  defp waiting(1), do: Text.tag(" · 1 call still waiting", @faint)
  defp waiting(n), do: Text.tag(" · #{n} calls still waiting", @faint)

  @doc "Said when several calls wait and a decision names none of them."
  @spec choose([{Tars.Tool.call(), String.t()}]) :: Text.t()
  def choose(calls) do
    [
      Text.tag(
        "  ▌ #{length(calls)} calls are waiting · say which: /approve 1, /deny 2 <reason>, or /approve all\n\n",
        :yellow
      )
    ]
  end

  @doc "Said when a decision names a call that is not waiting."
  @spec no_such_call(String.t()) :: Text.t()
  def no_such_call(selector),
    do: [Text.tag("  ▌ nothing waiting is numbered #{selector}\n\n", @faint)]

  @doc "Said when a decision is offered with nothing waiting on one."
  @spec nothing_to_answer() :: Text.t()
  def nothing_to_answer, do: [Text.tag("  ▌ nothing is waiting for a decision\n\n", @faint)]

  @doc "No decision was accepted while an earlier decision is executing or the call changed."
  @spec decision_pending() :: Text.t()
  def decision_pending do
    Text.tag(
      "  ▌ no decision sent · wait for the refreshed approval list before answering again\n\n",
      :yellow
    )
  end

  @doc "One tool call and its arguments, as the transcript shows it live or replayed."
  @spec tool_call(String.t(), map()) :: Text.t()
  def tool_call(name, arguments) when map_size(arguments) == 0,
    do: Text.tag("  ⇢ #{name}", @faint)

  def tool_call(name, arguments),
    do: Text.tag("  ⇢ #{name} #{Render.squash(JSON.encode!(arguments))}", @faint)

  @doc "A replayed tool result: what the tool returned, or the error it reported."
  @spec tool_result(String.t(), String.t(), boolean()) :: Text.t()
  def tool_result(name, output, true),
    do: Text.tag(["  ✓ ", name, " · ", payload(output)], @faint)

  def tool_result(name, output, false),
    do: [Text.tag("  ✗ #{name}", :red), Text.tag([" · ", payload(output)], @faint)]

  @doc "That an agent was started in the fleet, and this client attached to it."
  @spec spawned(String.t()) :: Text.t()
  def spawned(key), do: note(["spawned and connected to ", Text.tag(key, [:bright, :cyan])])

  @doc "That an agent was started in the fleet and left to work, this client staying where it is."
  @spec spawned_background(String.t(), String.t()) :: Text.t()
  def spawned_background(key, name) do
    note([
      "spawned ",
      Text.tag(key, [:bright, :cyan]),
      " in the background · ",
      Text.tag("/connect #{name}", :bright),
      " attaches"
    ])
  end

  @doc """
  That `/spawn` named an agent already running, so nothing was started: this
  client connected to it, or, in the background, left it alone.
  """
  @spec already_running(String.t(), String.t(), :attach | :background) :: Text.t()
  def already_running(key, _name, :attach),
    do: note([Text.tag(key, [:bright, :cyan]), " was already running · connected to it"])

  def already_running(key, name, :background) do
    note([
      Text.tag(key, :bright),
      " is already running · nothing was started · ",
      Text.tag("/connect #{name}", :bright),
      " attaches"
    ])
  end

  @doc "That a prompt was sent to an agent this client is not attached to."
  @spec sent_to(String.t(), String.t()) :: Text.t()
  def sent_to(key, text),
    do: note(["sent to ", Text.tag(key, :bright), ": ", Text.tag(text, :bright)])

  @doc "That an agent was restarted on another node."
  @spec moved(String.t(), node()) :: Text.t()
  def moved(key, node) do
    note([
      "moved ",
      Text.tag(key, :bright),
      " to ",
      Text.tag(Atom.to_string(node), :bright),
      " · restarted there with its conversation"
    ])
  end

  @doc """
  What `/move` would do to an agent whose turn is running or waiting, so the
  interruption is chosen rather than stumbled into.
  """
  @spec move_preview(String.t(), node(), :running | :parked) :: Text.t()
  def move_preview(key, node, status) do
    doing =
      case status do
        :running ->
          "its turn is running and would be interrupted · what it has said so far is kept"

        :parked ->
          "its turn is waiting on a decision, which would be abandoned"
      end

    [
      "\n",
      move_bar([
        Text.tag("/move #{key}", [:bright, :yellow]),
        Text.tag(" restarts it on ", @faint),
        Text.tag(Atom.to_string(node), :bright)
      ]),
      move_bar([Text.tag(["   ", doing], :yellow)]),
      move_bar([
        Text.tag("/confirm", [:bright, :yellow]),
        Text.tag(" goes ahead · anything else cancels", @faint)
      ]),
      "\n"
    ]
  end

  defp move_bar(content), do: [Text.tag("  ▌ ", :yellow), content, "\n"]

  @doc "Said when `/move` has nowhere to go: this is the only node. A brief notice."
  @spec only_node() :: Text.t()
  def only_node, do: brief("#{node()} is the only node · there is nowhere to move an agent to")

  @doc "That a node name matches none in the cluster, and which there are."
  @spec no_such_node(String.t(), [node()]) :: Text.t()
  def no_such_node(name, nodes) do
    [
      Text.tag("\n✗ no node named #{name} · ", :red),
      Text.tag("the cluster has ", @faint),
      Text.tag(Enum.map_join(nodes, ", ", &Atom.to_string/1), :bright),
      Text.tag(" · node=N takes the whole name or the part before the @\n", @faint)
    ]
  end

  @doc "That a command was given options it does not take."
  @spec unknown_options([String.t()], TarsTUI.Command.t()) :: Text.t()
  def unknown_options(keys, command) do
    [
      Text.tag(
        "\n✗ #{Enum.map_join(keys, ", ", &(&1 <> "="))} is not an option of #{command.name} · ",
        :red
      ),
      Text.tag("usage: ", @faint),
      Text.tag(command.usage, :bright),
      "\n"
    ]
  end

  @doc "That a node could not be reached for a spawn or a move."
  @spec unreachable(node(), term()) :: Text.t()
  def unreachable(node, reason) do
    [
      Text.tag("\n✗ #{node} could not be reached · ", :red),
      Text.tag("#{Render.squash(inspect(reason))} · /fleet shows what is running where\n", @faint)
    ]
  end

  @doc "That some agents were not removed, and what to do about it."
  @spec not_removed([String.t()]) :: Text.t()
  def not_removed(keys) do
    [
      Text.tag("\n✗ not removed: #{Enum.join(keys, ", ")} · ", :red),
      Text.tag(
        "each may be restarting on another node · /fleet shows where, then /rm again\n",
        @faint
      )
    ]
  end

  @doc "That this client is now watching a different agent."
  @spec connected(String.t()) :: Text.t()
  def connected(key), do: note(["connected to ", Text.tag(key, [:bright, :cyan])])

  @doc "That the attached agent came back under a new process, and this client followed it."
  @spec followed(String.t(), node()) :: Text.t()
  def followed(key, node),
    do:
      note([
        "reconnected to ",
        Text.tag(key, :bright),
        " on ",
        Text.tag(Atom.to_string(node), :bright)
      ])

  @doc "That the conversation grew while this client was watching another agent."
  @spec away(pos_integer()) :: Text.t()
  def away(1), do: note("1 message arrived while this client was elsewhere · replayed below")
  def away(n), do: note("#{n} messages arrived while this client was elsewhere · replayed below")

  @doc "That the fleet panel now shows only the agents matching a query. A brief notice."
  @spec filtered(String.t(), non_neg_integer(), non_neg_integer()) :: Text.t()
  def filtered(query, shown, total),
    do: brief(["the panel shows #{shown} of #{total} agents matching ", Text.tag(query, :cyan)])

  @doc "That the fleet panel shows every agent again. A brief notice."
  @spec unfiltered() :: Text.t()
  def unfiltered, do: brief("the panel shows every agent")

  @doc "That a word of a filter query is not one the panel understands. A brief notice."
  @spec bad_filter(String.t()) :: Text.t()
  def bad_filter(word) do
    [
      Text.tag("✗ #{word} is not a filter · ", :red),
      Text.tag("text, name:, org:, user:, node:, status:idle|running|parked, attention", @faint)
    ]
  end

  @doc "Said when `/next` finds no agent needing attention. A brief notice."
  @spec nothing_needs_attention() :: Text.t()
  def nothing_needs_attention, do: brief("no agent needs attention")

  @doc "That the transcript was searched and where it landed. A brief notice."
  @spec match(String.t(), pos_integer(), pos_integer()) :: Text.t()
  def match(query, index, count),
    do:
      brief(["match #{index} of #{count} for ", Text.tag(query, :cyan), " · n next · N previous"])

  @doc "That nothing in the transcript matches. A brief notice."
  @spec no_match(String.t()) :: Text.t()
  def no_match(query), do: brief(["nothing in the transcript matches ", Text.tag(query, :cyan)])

  @doc "Said when `n` or `N` is pressed with nothing searched for. A brief notice."
  @spec nothing_searched() :: Text.t()
  def nothing_searched,
    do: brief(["nothing searched for yet · ", Text.tag("/", :bright), " searches"])

  @doc "That the conversation holds no tool call to inspect. A brief notice."
  @spec no_tools() :: Text.t()
  def no_tools, do: brief("no tool calls in this conversation yet")

  @doc "That text went to the clipboard. A brief notice."
  @spec copied(:answer | :code, non_neg_integer()) :: Text.t()
  def copied(:answer, chars), do: brief("copied the answer · #{chars} characters")
  def copied(:code, chars), do: brief("copied the last code block · #{chars} characters")

  @doc "Why nothing was copied. A brief notice."
  @spec not_copied(:no_answer | :no_code | :no_clipboard | {:exit, non_neg_integer()}) :: Text.t()
  def not_copied(:no_answer), do: brief("nothing to copy · no answer yet")
  def not_copied(:no_code), do: brief("nothing to copy · the answer has no code block")

  def not_copied(:no_clipboard),
    do: Text.tag("✗ no clipboard tool · install wl-copy, xclip, xsel or pbcopy", :red)

  def not_copied({:exit, status}),
    do: Text.tag("✗ the clipboard tool exited with status #{status} · nothing was copied", :red)

  @doc "That an agent was asked to stop what it is doing."
  @spec stopped(String.t()) :: Text.t()
  def stopped(key), do: note(["asked ", Text.tag(key, :bright), " to stop"])

  @doc "That every agent under a prefix was asked to stop."
  @spec stopped_under(String.t(), non_neg_integer()) :: Text.t()
  def stopped_under(prefix, 0), do: note(["nothing running under ", Text.tag(prefix, :bright)])

  def stopped_under(prefix, n),
    do: note(["asked #{n} under ", Text.tag(prefix, :bright), " to stop"])

  @doc "That an agent was shut down with its conversation kept."
  @spec shut_down(String.t(), String.t()) :: Text.t()
  def shut_down(key, name) do
    note([
      "shut down ",
      Text.tag(key, :bright),
      " · its conversation is kept · ",
      Text.tag("/spawn #{name}", :bright),
      " brings it back"
    ])
  end

  @doc """
  What `/rm` is about to remove, so nothing permanent happens on one line.
  """
  @spec removal_preview(String.t(), [String.t()], String.t() | nil) :: Text.t()
  def removal_preview(target, keys, skipped) do
    [
      "\n",
      rm_bar([
        Text.tag("/rm #{target}", [:bright, :red]),
        Text.tag(
          " removes #{count(keys, "agent")}, and what they said, for good:",
          @faint
        )
      ]),
      Enum.map(keys, &rm_bar([Text.tag(["   ", &1], :bright)])),
      skipped_bar(skipped),
      rm_bar([
        Text.tag("/confirm", [:bright, :red]),
        Text.tag(" goes ahead · anything else cancels", @faint)
      ]),
      "\n"
    ]
  end

  defp skipped_bar(nil), do: []

  defp skipped_bar(key),
    do: rm_bar([Text.tag(["   skipping ", key, " · you are attached to it"], :yellow)])

  defp rm_bar(content), do: [Text.tag("  ▌ ", :red), content, "\n"]

  defp count([_one], noun), do: "1 #{noun}"
  defp count(many, noun), do: "#{length(many)} #{noun}s"

  @doc "Said when `/confirm` arrives with nothing waiting on it. A brief notice."
  @spec nothing_to_confirm() :: Text.t()
  def nothing_to_confirm, do: brief("nothing is waiting to be confirmed")

  @doc "That a pending removal or move was dropped because something else was typed."
  @spec cancelled(:rm | :move) :: Text.t()
  def cancelled(:rm), do: note("removal cancelled · nothing was removed")
  def cancelled(:move), do: note("move cancelled · the agent stays where it is")

  @doc """
  That a slash word names no command, so nothing was sent to the model, with
  the commands it most resembles.
  """
  @spec unknown_command(String.t(), [String.t()]) :: Text.t()
  def unknown_command(word, suggestions \\ [])

  def unknown_command("/kill", _suggestions) do
    [
      Text.tag("\n✗ /kill is gone · ", :red),
      Text.tag("/stop", :bright),
      Text.tag(" interrupts · ", @faint),
      Text.tag("/shutdown", :bright),
      Text.tag(" keeps the conversation · ", @faint),
      Text.tag("/rm", :bright),
      Text.tag(" deletes it\n", @faint)
    ]
  end

  def unknown_command(word, suggestions) do
    [
      Text.tag("\n✗ #{word} is not a command · nothing was sent", :red),
      meant(suggestions),
      Text.tag(" · ", @faint),
      Text.tag("/help", :bright),
      Text.tag(" lists them · start with ", @faint),
      Text.tag("//", :bright),
      Text.tag(" to send the line as typed\n", @faint)
    ]
  end

  defp meant([]), do: []

  defp meant(names),
    do: [Text.tag(" · did you mean ", @faint), Text.tag(Enum.join(names, ", "), :bright)]

  @doc """
  The command palette: a title, the query with a cursor, one row per choice
  with the one under the cursor marked, and a line of keys, as the rows of a
  box `width` by `height`, borders included.

  Each row is `{:row, text}`, `{:header, text}`, a heading standing over the
  section it names, or `{:blank, text}`, a row of air. Rows beyond the room
  are left out, keeping the one under the cursor in view.
  """
  @spec palette(
          String.t(),
          String.t(),
          [{:row | :header | :blank, Text.t()}],
          non_neg_integer(),
          pos_integer(),
          pos_integer()
        ) ::
          String.t()
  def palette(title, query, rows, cursor, width, height) do
    inner = max(width - 2, 4)
    room = max(height - 5, 1)
    first = max(cursor - room + 1, 0)

    shown =
      rows
      |> Enum.with_index()
      |> Enum.drop(first)
      |> Enum.take(room)
      |> Enum.map(fn {row, index} -> choice(row, index == cursor, inner) end)

    [
      Text.tag(" #{title}", [:bright, :cyan]),
      [Text.tag(" › ", [:bright, :cyan]), query, Text.tag("▏", @faint)],
      rule(first, length(shown), length(rows), inner)
    ]
    |> Kernel.++(if(shown == [], do: [Text.tag("   nothing matches", @faint)], else: shown))
    |> Enum.map_join("\n", &Render.line(pad(Text.truncate(&1, inner), inner)))
  end

  # The rule says which part of the list is in view, when not all of it is.
  defp rule(first, shown, total, inner) when shown < total do
    counter = "#{first + 1}-#{first + shown} of #{total} "
    gap = String.duplicate(" ", max(inner - 2 - String.length(counter), 0))
    Text.tag([" ─", gap, counter], @faint)
  end

  defp rule(_first, _shown, _total, _inner), do: Text.tag(" ─", @faint)

  # A heading sits a column out from its rows, with a rule running off it.
  defp choice({:header, row}, _cursor?, inner) do
    gap = max(inner - Text.length(row) - 3, 0)
    [" ", row, Text.tag([" ", String.duplicate("─", gap)], @faint)]
  end

  defp choice({:row, row}, true, _inner),
    do: [Text.tag(" › ", [:bright, :cyan]), Text.tag(row, :bright)]

  defp choice({:row, row}, false, _inner), do: ["   ", row]
  defp choice({:blank, _row}, _cursor?, _inner), do: []

  # The padding carries a style: the compositor lets an unstyled space show
  # what lies under it, and an overlay row must cover the row beneath.
  defp pad(data, width),
    do: [data, Text.tag(String.duplicate(" ", max(width - Text.length(data), 0)), @faint)]

  @doc """
  One command as a palette row: what it does, what it is called, and the key
  that does the same or that it was reached for recently, each in a column.

  The arguments a command takes are left to the step that asks for them, and
  to `help_command/2`.
  """
  @spec palette_command(TarsTUI.Command.t(), boolean()) :: Text.t()
  def palette_command(command, recent?) do
    [
      pad(command.label, label_width() + 2),
      pad(Text.tag(command.name, @faint), name_width() + 2),
      mark(command.shortcut, recent?)
    ]
  end

  defp mark(nil, false), do: []
  defp mark(nil, true), do: Text.tag("recent", @faint)
  defp mark(shortcut, _recent?), do: Text.tag(shortcut, :yellow)

  defp label_width, do: TarsTUI.Command.all() |> Enum.map(&String.length(&1.label)) |> Enum.max()
  defp name_width, do: TarsTUI.Command.all() |> Enum.map(&String.length(&1.name)) |> Enum.max()

  @doc "What the palette asks for at a step, as its title."
  @spec palette_title(TarsTUI.Command.step() | :commands, TarsTUI.Command.t() | nil) :: String.t()
  def palette_title(:commands, _command), do: "Commands · Ctrl-P"
  def palette_title(:agent, command), do: "#{command.name} · which agent?"
  def palette_title(:node, command), do: "#{command.name} · which node?"
  def palette_title(:call, command), do: "#{command.name} · which call?"
  def palette_title(:text, command), do: "#{command.usage} · type the rest, then Enter"
  def palette_title(:help, _command), do: "Help · every key and command · Enter runs a command"
  def palette_title(:search, _command), do: "Search the transcript · Enter goes to the match"
  def palette_title(:tool, _command), do: "Tool calls · Enter shows one in full"

  @doc "One matching transcript row as a search result: its number and text."
  @spec search_row(non_neg_integer(), String.t()) :: Text.t()
  def search_row(row, text),
    do: [Text.tag(String.pad_leading("#{row + 1}", 5), @faint), "  ", String.trim(text)]

  @doc "One tool call as a palette row: its number, how it went, its name and arguments."
  @spec tool_row(TarsTUI.Exchange.t(), pos_integer()) :: Text.t()
  def tool_row(exchange, index) do
    [
      Text.tag("#{index}  ", @faint),
      exchange_glyph(exchange),
      " ",
      Text.tag(exchange.name, :bright),
      Text.tag(["  ", args(exchange)], @faint)
    ]
  end

  defp exchange_glyph(%{ok?: nil}), do: Text.tag("◐", :cyan)
  defp exchange_glyph(%{ok?: true}), do: Text.tag("✓", :green)
  defp exchange_glyph(%{ok?: false}), do: Text.tag("✗", :red)

  @doc """
  One tool call in full, as transcript lines: its name and how it went, its
  arguments, and what it returned, each laid out over as many lines as it
  takes, up to a limit.
  """
  @spec tool_inspector(TarsTUI.Exchange.t(), pos_integer()) :: [Text.t()]
  def tool_inspector(exchange, index) do
    [
      [
        Text.tag("#{index}  ", @faint),
        exchange_glyph(exchange),
        " ",
        Text.tag(exchange.name, [:bright, :cyan]),
        Text.tag(exchange_state(exchange), @faint),
        Text.tag("  · Esc closes", @faint)
      ],
      "",
      Text.tag("arguments", :bright)
    ] ++
      indented_lines(pretty(exchange.arguments)) ++
      ["", Text.tag("output", :bright)] ++
      indented_lines(output_text(exchange))
  end

  defp exchange_state(%{ok?: nil}), do: "  running"
  defp exchange_state(%{ok?: true}), do: "  ok"
  defp exchange_state(%{ok?: false}), do: "  failed"

  @inspector_chars 20_000

  defp output_text(%{output: nil}), do: Text.tag("nothing yet", @faint)

  defp output_text(%{output: output}) do
    text =
      case JSON.decode(output) do
        {:ok, decoded} when is_map(decoded) or is_list(decoded) -> pretty(decoded)
        _other -> output
      end

    if String.length(text) > @inspector_chars,
      do:
        String.slice(text, 0, @inspector_chars) <>
          "\n… #{String.length(text) - @inspector_chars} more characters",
      else: text
  end

  defp pretty(value) when is_map(value) and map_size(value) == 0, do: "none"

  defp pretty(value),
    do: value |> JSON.encode_to_iodata!() |> IO.iodata_to_binary() |> pretty_json()

  # One key or element per line, nested by indentation.
  defp pretty_json(json) do
    case JSON.decode(json) do
      {:ok, decoded} -> decoded |> format(0) |> IO.iodata_to_binary()
      _other -> json
    end
  end

  defp format(map, depth) when is_map(map) do
    pad = String.duplicate("  ", depth + 1)

    entries =
      map
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> Enum.map(fn {key, value} ->
        [pad, JSON.encode!(to_string(key)), ": ", format(value, depth + 1)]
      end)

    ["{\n", Enum.intersperse(entries, ",\n"), "\n", String.duplicate("  ", depth), "}"]
  end

  defp format(list, depth) when is_list(list) do
    pad = String.duplicate("  ", depth + 1)
    entries = Enum.map(list, &[pad, format(&1, depth + 1)])
    ["[\n", Enum.intersperse(entries, ",\n"), "\n", String.duplicate("  ", depth), "]"]
  end

  defp format(value, _depth), do: JSON.encode!(value)

  defp indented_lines(%Text{} = text), do: [["  ", text]]

  defp indented_lines(text) when is_binary(text),
    do: text |> String.split("\n") |> Enum.map(&["  ", &1])

  @doc """
  One delegation in full, as transcript lines: what it was asked, the work
  under it, and what it answered or why it failed. `now` is the system time in
  milliseconds.
  """
  @spec inspector(Tars.Delegation.delegation(), [Tars.Delegation.span()], String.t(), integer()) ::
          [Text.t()]
  def inspector(record, activity, key, now) do
    [
      [Text.tag(record.name || "delegate", [:bright, :cyan]), Text.tag(" · #{key}", @faint)],
      state(record, now),
      "",
      Text.tag("task", :bright),
      ["  ", record.task],
      ""
    ] ++
      work(activity, now) ++ answer(record)
  end

  defp state(%{status: :running} = record, now),
    do: Text.tag("◐ running · #{Text.duration(Tars.Delegation.elapsed_ms(record, now))}", :cyan)

  defp state(%{status: :ok} = record, now),
    do: Text.tag("✓ done · #{Text.duration(Tars.Delegation.elapsed_ms(record, now))}", :green)

  defp state(%{status: :error} = record, now),
    do: Text.tag("✗ failed · #{Text.duration(Tars.Delegation.elapsed_ms(record, now))}", :red)

  defp work([], _now), do: [Text.tag("activity", :bright), Text.tag("  nothing yet", @faint), ""]

  defp work(spans, now) do
    [Text.tag("activity", :bright)] ++
      Enum.map(spans, fn span ->
        [
          "  ",
          Text.tag(glyph(span), colour(span)),
          " ",
          span.name || "?",
          Text.tag(" · #{Text.duration(Tars.Delegation.elapsed_ms(span, now))}", @faint)
        ]
      end) ++ [""]
  end

  defp answer(%{status: :ok, output: output}),
    do: [Text.tag("output", :bright), ["  ", presence(output, "nothing was said")]]

  defp answer(%{status: :error, error: reason}),
    do: [Text.tag("error", :red), ["  ", Render.squash(inspect(reason))]]

  defp answer(_running), do: []

  defp presence(nil, fallback), do: Text.tag(fallback, @faint)
  defp presence("", fallback), do: Text.tag(fallback, @faint)
  defp presence(text, _fallback), do: text

  @doc "Why the editor left the prompt as it was."
  @spec editor_failed(term()) :: Text.t()
  def editor_failed(:no_editor),
    do: [Text.tag("\n✗ no editor · set $VISUAL or $EDITOR to edit the prompt\n", :red)]

  def editor_failed(:remote),
    do:
      brief(
        "the editor is only offered in a local terminal · over SSH it would run on the server"
      )

  def editor_failed({:exit, status}),
    do: brief("the editor exited with status #{status} · the prompt is as it was")

  def editor_failed(reason),
    do: [Text.tag("\n✗ the editor failed · #{inspect(reason)} · the prompt is as it was\n", :red)]

  @doc "That nothing was sent, because the agent is not running."
  @spec unavailable(String.t()) :: Text.t()
  def unavailable(key), do: [Text.tag("\n✗ #{key} is not running · nothing was sent\n", :red)]

  @doc "The glyph in front of what a person typed: `›` sent, `»` queued behind a turn."
  @spec prompt(String.t()) :: Text.t()
  def prompt(glyph), do: Text.tag(glyph <> " ", [:bright, :cyan])

  @doc """
  A message sent while a turn runs or waits. A running turn is asked to stop at
  its next boundary and the message joins it; one that is parked keeps it
  behind the answer it is waiting for.
  """
  @spec steered(String.t(), :running | :parked) :: Text.t()
  def steered(text, :running) do
    [
      prompt("»"),
      Text.tag(text, :bright),
      Text.tag("  · steers the turn at its next boundary", @faint)
    ]
  end

  def steered(text, :parked) do
    [prompt("»"), Text.tag(text, :bright), Text.tag("  · queued behind the parked turn", @faint)]
  end

  @doc "A message a person sent, as the transcript shows it."
  @spec question(String.t()) :: Text.t()
  def question(text), do: [prompt("›"), Text.tag(text, :bright)]

  @doc "That a key names nothing the fleet is holding."
  @spec no_such_agent(String.t()) :: Text.t()
  def no_such_agent(key), do: [Text.tag("\n✗ no agent at #{key}\n", :red)]

  # Each key, where it works, and what it does. `"prompt"`, `"log"` and
  # `"fleet"` are the panes; `nil` is anywhere.
  @keys [
    {"prompt", "Enter", "send what you typed; during a turn, steer it at its next boundary"},
    {"prompt", "Shift-Enter", "a new line in the prompt"},
    {"prompt", "Up, Down",
     "on the first or last line, recall an older or newer prompt; with / typed, a command"},
    {"prompt", "Esc", "stop the turn, or abandon a parked one"},
    {"prompt", "Ctrl-D", "quit, with nothing typed"},
    {"log", "j/k, Ctrl-U/D, PageUp/Down", "scroll a row, half a page, a page"},
    {"log", "End", "follow the newest output again"},
    {"log", "/", "search the transcript; then n and N step through the matches"},
    {"log", "t", "pick a tool call and see its arguments and output in full"},
    {"log", "y", "copy the last answer to the clipboard"},
    {"fleet", "Up, Down, Enter", "choose an agent and connect to it"},
    {"fleet", "h, l", "hide or show an agent's delegations; Enter on one inspects it"},
    {"fleet", "n, a", "move to the next agent needing attention, and show only those"},
    {"log", "i, Esc", "back to the prompt"},
    {"fleet", "i, Esc", "back to the prompt"},
    {nil, "Ctrl-G", "edit the prompt in $VISUAL or $EDITOR; what is saved comes back unsent"},
    {nil, "Ctrl-P", "command palette: type to filter, Up/Down choose, Enter runs, Esc closes"},
    {nil, "Tab, Shift-Tab", "cycle the prompt, the transcript and the fleet panel"},
    {nil, "Ctrl-X then h/j/k/l",
     "move focus in that direction; then s stops the turn, Esc cancels"},
    {nil, "Ctrl-F", "show or hide the fleet panel"},
    {nil, "Ctrl-T", "toggle the trace"},
    {nil, "Ctrl-C", "leave at once, without asking"}
  ]

  @pane_names %{"prompt" => "prompt", "log" => "transcript", "fleet" => "fleet"}

  @key_width @keys |> Enum.map(fn {_pane, key, _does} -> String.length(key) end) |> Enum.max()

  @doc """
  The keys that work in `where` as help rows, `nil` being the keys that work
  anywhere. The section they sit under says where that is, so no row names it.
  """
  @spec help_keys(String.t() | nil) :: [Text.t()]
  def help_keys(where) do
    @keys
    |> Enum.filter(fn {pane, _key, _does} -> pane == where end)
    |> Enum.map(fn {_pane, key, does} -> help_row(Text.tag(key, :bright), [], does) end)
  end

  @doc "The panes with keys of their own, the one in focus first."
  @spec help_panes(String.t()) :: [String.t()]
  def help_panes(pane) do
    @pane_names |> Map.keys() |> Enum.sort_by(&if(&1 == pane, do: 0, else: 1))
  end

  @doc "What a section of keys or commands is called, `pane` being the one in focus."
  @spec help_section(String.t(), String.t()) :: Text.t()
  def help_section(where, pane) do
    [
      Text.tag(Map.get(@pane_names, where, where), [:bright, :cyan]),
      if(where == pane, do: Text.tag(" · here", :cyan), else: [])
    ]
  end

  @doc """
  One command as a help row: its usage, then what it does, led by the key that
  does the same. A command that cannot run now is faint, and belongs under a
  section that says so.
  """
  @spec help_command(TarsTUI.Command.t(), boolean()) :: Text.t()
  def help_command(command, available?) do
    help_row(
      Text.tag(command.usage, if(available?, do: :bright, else: @faint)),
      shortcut_tag(command.shortcut, available?),
      command.summary
    )
  end

  # A key that does the same is only worth naming while the command can run.
  defp shortcut_tag(nil, _available?), do: []
  defp shortcut_tag(_key, false), do: []
  defp shortcut_tag(key, true), do: Text.tag("#{key} · ", :yellow)

  # Keys and commands share one first column, so what they do runs down the
  # list in a line.
  defp help_row(first, lead, does) do
    [pad(first, help_width() + 2), lead, Text.tag(does, @faint)]
  end

  defp help_width, do: max(@key_width, usage_width())

  defp usage_width, do: TarsTUI.Command.all() |> Enum.map(&String.length(&1.usage)) |> Enum.max()

  @doc "How a command is used, when it was given something else."
  @spec usage(TarsTUI.Command.t()) :: Text.t()
  def usage(command) do
    [
      Text.tag("\n✗ usage: ", :red),
      Text.tag(command.usage, :bright),
      Text.tag(" · #{command.summary}\n", @faint)
    ]
  end

  @doc "That the agents named were removed with their stores."
  @spec forgotten([String.t()]) :: Text.t()
  def forgotten([key]), do: note(["removed ", Text.tag(key, :bright), " and its store"])

  def forgotten(keys) do
    note([
      "removed #{length(keys)} agents and their stores: ",
      Text.tag(Enum.join(keys, ", "), :bright)
    ])
  end

  @doc "That a prefix matched nothing running."
  @spec nothing_under(String.t()) :: Text.t()
  def nothing_under(prefix), do: note(["nothing running under ", Text.tag(prefix, :bright)])

  @doc "That a removal would have taken the agent this client is attached to."
  @spec attached(String.t()) :: Text.t()
  def attached(key),
    do: note(["you are attached to ", Text.tag(key, :bright), " · /connect elsewhere first"])

  defp note(content), do: ["\n", Text.tag("· ", @faint), content, "\n"]

  # One row for the status bar, shown for a moment.
  defp brief(content), do: [Text.tag("· ", @faint), content]

  @doc "That the transcript has rows below the ones shown, for the status row."
  @spec new_below() :: Text.t()
  def new_below, do: Text.tag("↓ new output below · End to follow · ", :yellow)

  # Two columns go to the glyph and its trailing space, and one is left spare.
  defp room(width), do: max(width - 3, 1)

  defp line(kind, detail, tag) do
    [
      Text.tag(String.pad_trailing(kind, 6), tag),
      Text.tag(detail, @faint),
      "\n"
    ]
  end

  defp glyph(%{status: :running}), do: "·"
  defp glyph(%{status: :ok}), do: "✓"
  defp glyph(%{status: :error}), do: "✗"
  defp glyph(%{status: :parked}), do: "?"

  defp colour(%{status: :running}), do: @faint
  defp colour(%{status: :ok}), do: :green
  defp colour(%{status: :error}), do: :red
  defp colour(%{status: :parked}), do: :yellow

  defp cause(%{error: nil}), do: []
  defp cause(%{error: reason}), do: Text.tag(" · #{inspect(reason)}", :red)

  defp took(%{status: :running}, _now), do: []

  defp took(span, now),
    do: Text.tag(" · #{Text.duration(Activity.elapsed_ms(span, now))}", @faint)
end
