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
  @frames ~w(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

  @doc "The spinner frame for a tick count."
  @spec spinner(non_neg_integer()) :: String.t()
  def spinner(frame), do: Enum.at(@frames, rem(frame, length(@frames)))

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
    do: line("model", "ok #{seconds(ms)}", :cyan)

  def trace({:model_finished, {:error, reason}, ms}),
    do: line("model", "#{inspect(reason)} #{seconds(ms)}", :red)

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
    do: [" · the approval was abandoned · ", seconds(stats.elapsed_ms), dropped(stats.dropped)]

  defp detail(stats) do
    [
      " · ",
      seconds(stats.elapsed_ms),
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

  @doc "That an agent was restarted on another node."
  @spec moved(String.t(), node()) :: Text.t()
  def moved(key, node),
    do: note(["moved ", Text.tag(key, :bright), " to ", Text.tag(Atom.to_string(node), :bright)])

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

  @doc "Said when `/confirm` arrives with nothing waiting on it."
  @spec nothing_to_confirm() :: Text.t()
  def nothing_to_confirm, do: [Text.tag("  ▌ nothing is waiting to be confirmed\n\n", @faint)]

  @doc "That a pending removal was dropped because something else was typed."
  @spec cancelled() :: Text.t()
  def cancelled, do: note("removal cancelled")

  @doc "That a slash word names no command, so nothing was sent to the model."
  @spec unknown_command(String.t()) :: Text.t()
  def unknown_command("/kill") do
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

  def unknown_command(word) do
    [
      Text.tag("\n✗ #{word} is not a command, or is missing what it needs · ", :red),
      Text.tag("/help", :bright),
      Text.tag(" lists them · nothing was sent\n", @faint)
    ]
  end

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

  @help [
    {"Enter", "send what you typed; during a turn it steers the turn at its next boundary"},
    {"Shift-Enter", "a new line in the prompt"},
    {"Esc", "stop the turn"},
    {"Tab", "move focus between the prompt, the transcript and the fleet"},
    {"Ctrl-T", "toggle the trace"},
    {"Ctrl-F", "focus the fleet panel; again to put it away"},
    {"Up, Down, Enter", "in the fleet panel, choose an agent and connect to it"},
    {"Ctrl-D", "quit"},
    {"/spawn NAME [node=N] [prompt]", "start an agent beside this one and attach to it"},
    {"/connect NAME", "attach to an agent and show its conversation"},
    {"/move NAME node=N", "restart an agent on another node, as it was"},
    {"/stop [NAME | PREFIX/]", "interrupt this agent, another, or every agent under a prefix"},
    {"/shutdown NAME", "stop an agent and keep its conversation; /spawn brings it back"},
    {"/rm NAME | PREFIX/", "delete an agent and its conversation, after showing what goes"},
    {"/confirm", "go ahead with the removal shown"},
    {"/fleet", "list every agent in the cluster"},
    {"/approve [N | all]", "approve the parked call, one by number, or every one; y does too"},
    {"/deny [N] [reason]", "deny the parked call, or one by number, saying why; n does too"},
    {"/quit", "leave"},
    {"/help", "this list"}
  ]

  @doc "Every key and command, one per line."
  @spec help() :: [Text.t()]
  def help do
    width = @help |> Enum.map(fn {what, _does} -> String.length(what) end) |> Enum.max()

    Enum.map(@help, fn {what, does} ->
      ["  ", Text.tag(String.pad_trailing(what, width), :bright), Text.tag("  #{does}", @faint)]
    end)
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
  defp took(span, now), do: Text.tag(" · #{seconds(Activity.elapsed_ms(span, now))}", @faint)

  defp seconds(ms) when ms < 1_000, do: "#{ms}ms"
  defp seconds(ms), do: "#{Float.round(ms / 1_000, 1)}s"
end
