defmodule Wardrik.Compaction do
  @moduledoc """
  When an agent's history is summarised, and how much of it is kept as it was.

  An agent that runs for weeks keeps adding to one conversation. Before the
  conversation outgrows what its model can read, the agent replaces the older
  part of it with a summary the model writes, and keeps the most recent part
  word for word:

      Wardrik.LLM.Config.new(history: {Wardrik.Compaction, Wardrik.Compaction.new(at: 0.5, keep: 0.2)})

  | Field | What it decides |
  | --- | --- |
  | `:at` | compact once the history reaches this share of the model's context window. `0.6` |
  | `:keep` | how much of the most recent history is kept word for word, as a share of the window, less than `:at`. `0.25` |
  | `:window` | the context window in tokens, for a model the catalog does not know. The catalog's otherwise, and #{128_000} where it has none |

  It is an agent's `Wardrik.History` unless its config names another, and a
  config with `history: nil` never compacts.

  Sizes are estimated from the text a history holds, as `Wardrik.LLM.Tokens`
  counts it, since no provider counts tokens before a call is made. The kept
  part always begins with a person's message, so a tool call is never
  separated from its result. A history with no such place to cut is left as it
  is, and so is one whose older part is only the summary an earlier compaction
  left there.

  An agent compacts as a turn begins, before the messages it answers join
  the history; see `prepare/3` for the summary itself.
  """

  @behaviour Wardrik.History

  alias ReqLLM.Context
  alias Wardrik.Call
  alias Wardrik.Call.Pipeline
  alias Wardrik.LLM.Message
  alias Wardrik.LLM.Request
  alias Wardrik.LLM.Tokens
  alias Wardrik.Run

  defstruct at: 0.6, keep: 0.25, window: nil

  @type t() :: %__MODULE__{at: float(), keep: float(), window: pos_integer() | nil}

  @default_window 128_000

  # The most of the model's window one summary request carries of the
  # conversation it summarises.
  @request_share 0.5

  @summarise """
  You are condensing the earlier part of a conversation you are having, so you can carry on
  without it. Write down everything you will need later: what the person asked for and still
  wants, decisions made, facts found, results of tool calls that matter, work in progress and
  what is left to do. Leave out pleasantries and anything already superseded. Write plainly, as
  notes to yourself, and do not answer anything.
  """

  @summary_intro "What we said earlier in this conversation, summarised:\n\n"
  @acknowledgement "Understood. I have the summary of our earlier conversation."
  @ask "Summarise the conversation so far."

  @doc """
  A compaction policy from its fields. Raises on a field it does not have, on
  an `:at` or `:keep` that is not a share between 0 and 1, on a `:keep` that
  is not less than `:at`, and on a `:window` that is not a whole number of
  tokens.
  """
  @spec new(keyword()) :: t()
  def new(fields \\ []) do
    compaction = struct!(__MODULE__, fields)

    share!(compaction.at, :at)
    share!(compaction.keep, :keep)
    window!(compaction.window)

    if compaction.keep >= compaction.at do
      raise ArgumentError,
            "a compaction keeps less than it waits for: :keep is #{compaction.keep} " <>
              "and :at #{compaction.at}"
    end

    compaction
  end

  defp share!(share, _key) when is_number(share) and share > 0 and share < 1, do: :ok

  defp share!(share, key),
    do: raise(ArgumentError, "#{inspect(key)} is a share between 0 and 1, got: #{inspect(share)}")

  defp window!(nil), do: :ok
  defp window!(window) when is_integer(window) and window > 0, do: :ok

  defp window!(window),
    do: raise(ArgumentError, ":window is a whole number of tokens, got: #{inspect(window)}")

  @doc "The context window of `model_spec`, in tokens."
  @spec window(t(), term()) :: pos_integer()
  def window(%__MODULE__{window: window}, _model_spec) when is_integer(window), do: window

  def window(%__MODULE__{}, model_spec) do
    case ReqLLM.model(model_spec) do
      {:ok, %{limits: %{context: context}}} when is_integer(context) and context > 0 -> context
      _unknown -> @default_window
    end
  end

  @doc """
  Where `context` would be cut, if it has outgrown `compaction` for
  `model_spec`: `{:ok, older, recent}`, or `:keep` where it has not, has
  nowhere to cut, or would have only an earlier summary to summarise.
  """
  @spec split(t() | nil, Context.t(), term()) ::
          {:ok, [ReqLLM.Message.t()], [ReqLLM.Message.t()]} | :keep
  def split(nil, _context, _model_spec), do: :keep

  def split(%__MODULE__{} = compaction, %Context{} = context, model_spec) do
    messages = Context.to_list(context)
    tails = Tokens.tails(messages)
    window = window(compaction, model_spec)

    if List.first(tails, 0) > compaction.at * window,
      do: cut(messages, tails, compaction.keep * window),
      else: :keep
  end

  # The kept part is the longest tail within `keep` tokens that begins with a
  # person's message, and at least that person's last message. Tails only
  # shrink, so the first that fits is the longest.
  defp cut(messages, tails, keep) do
    starts =
      for {{%{role: :user}, tail}, index} <- Enum.with_index(Enum.zip(messages, tails)),
          index > 0,
          do: {index, tail}

    case Enum.find(starts, fn {_index, tail} -> tail <= keep end) || List.last(starts) do
      nil ->
        :keep

      {index, _tail} ->
        {older, recent} = Enum.split(messages, index)
        if summary?(older), do: :keep, else: {:ok, older, recent}
    end
  end

  # What `prepare/3` puts in place of an older part.
  defp summary?([%{role: :user} = summary, %{role: :assistant} = acknowledgement]) do
    String.starts_with?(Message.text(summary), @summary_intro) and
      Message.text(acknowledgement) == @acknowledgement
  end

  defp summary?(_older), do: false

  @doc """
  Compacts `context` under `run`, if `compaction` says it is due.

  The older part is summarised by the agent's own model, through
  `Wardrik.Call.Pipeline`, so the run's hooks decide and count the call like
  any other, and its `Wardrik.LLM.Dispatch` admits it. The summary and an
  acknowledgement take the older part's place, and the recent part follows
  word for word. `:keep` where nothing is due; `{:error, reason}` where the
  summary could not be made, which leaves the context as it was.

  An older part that takes more than half the model's window is summarised in
  parts, oldest first: each is written out as a transcript within that half,
  and asked about together with the summary of the parts before it, so no one
  request outgrows the model.
  """
  @impl Wardrik.History
  @spec prepare(Context.t(), Run.t(), t() | nil) ::
          {:ok, Context.t()} | :keep | {:error, term()}
  def prepare(%Context{} = context, %Run{config: config} = run, compaction) do
    compaction = compaction || %__MODULE__{}

    with {:ok, older, recent} <- split(compaction, context, config.model_spec),
         {:ok, summary} <- summarise(run, compaction, older) do
      {:ok,
       Context.new([
         Context.user(@summary_intro <> summary),
         Context.assistant(@acknowledgement) | recent
       ])}
    end
  end

  defp summarise(%Run{config: config} = run, compaction, older) do
    budget = trunc(@request_share * window(compaction, config.model_spec))

    if Tokens.messages(older) <= budget do
      ask(run, older ++ [Context.user(@ask)])
    else
      older
      |> parts(budget)
      |> Enum.reduce_while({:ok, nil}, &summarise_part(run, &1, &2))
      |> summarised()
    end
  end

  defp summarise_part(run, part, {:ok, summary}) do
    case ask(run, [Context.user(continued(summary, part))]) do
      {:ok, summary} -> {:cont, {:ok, summary}}
      error -> {:halt, error}
    end
  end

  defp summarised({:ok, nil}), do: {:error, :empty_summary}
  defp summarised(result), do: result

  defp continued(nil, part),
    do: "Here is the conversation so far, as a transcript:\n\n#{part}\n\n#{@ask}"

  defp continued(summary, part) do
    "Here is a summary of the conversation up to a point:\n\n#{summary}\n\n" <>
      "What was said after it, as a transcript:\n\n#{part}\n\n#{@ask}"
  end

  # The messages written out as a transcript, in parts of at most `budget`
  # tokens: cut between messages where the next one fits, and within a message
  # that is longer than a part.
  defp parts(messages, budget) do
    limit = Tokens.chars(budget)

    messages
    |> Enum.map(&line/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.flat_map(&slices(&1, limit))
    |> Enum.chunk_while({[], 0}, &pack(&1, &2, limit), &close/1)
  end

  defp line(%{role: :user} = message), do: "Person: " <> Message.text(message)
  defp line(%{role: :tool} = message), do: "#{message.name} answered: " <> Message.text(message)

  defp line(%{role: :assistant} = message) do
    said = if Message.text(message) == "", do: [], else: ["You: " <> Message.text(message)]

    calls =
      for call <- Map.get(message, :tool_calls) || [],
          do: "You called #{ReqLLM.ToolCall.name(call)} with #{ReqLLM.ToolCall.args_json(call)}"

    Enum.join(said ++ calls, "\n")
  end

  defp line(_message), do: ""

  defp slices(line, limit) do
    if String.length(line) <= limit,
      do: [line],
      else: line |> String.codepoints() |> Enum.chunk_every(limit) |> Enum.map(&Enum.join/1)
  end

  defp pack(line, {[], 0}, _limit), do: {:cont, {[line], String.length(line)}}

  defp pack(line, {lines, length}, limit) do
    grown = length + 2 + String.length(line)

    if grown <= limit,
      do: {:cont, {[line | lines], grown}},
      else: {:cont, joined(lines), {[line], String.length(line)}}
  end

  defp close({[], 0}), do: {:cont, {[], 0}}
  defp close({lines, _length}), do: {:cont, joined(lines), {[], 0}}

  defp joined(lines), do: lines |> Enum.reverse() |> Enum.join("\n\n")

  defp ask(run, messages) do
    request = Request.new(%{run.config | tools: [], system: @summarise}, Context.new(messages))

    case request |> Pipeline.model(run) |> Pipeline.run(&generate/1) do
      %Call{state: :waiting} = waiting -> {:error, {:parked, Call.prompt(waiting)}}
      %Call{state: :denied, denied: denied} -> {:error, {:policy_denied, denied.reason}}
      %Call{result: result} -> text(result)
    end
  end

  defp generate(call) do
    admitted = Pipeline.request(call)
    Call.answer(call, ReqLLM.generate_text(admitted.model_spec, admitted.context, admitted.opts))
  end

  defp text({:ok, response}) do
    case response |> ReqLLM.Response.text() |> to_string() |> String.trim() do
      "" -> {:error, :empty_summary}
      summary -> {:ok, summary}
    end
  end

  defp text({:error, reason}), do: {:error, reason}
end
