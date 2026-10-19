defmodule Wardrik.Compaction do
  @moduledoc """
  When an agent's history is summarised, and how much of it is kept as it was.

  An agent that runs for weeks keeps adding to one conversation. Before the
  conversation outgrows what its model can read, the agent replaces the older
  part of it with a summary the model writes, and keeps the most recent part
  word for word:

      Wardrik.LLM.Config.new(history: Wardrik.Compaction.new(at: 0.5, keep: 0.2))

  | Field | What it decides |
  | --- | --- |
  | `:at` | compact once the history reaches this share of the model's context window. `0.6` |
  | `:keep` | how much of the most recent history is kept word for word, as a share of the window, less than `:at`. `0.25` |
  | `:window` | the context window in tokens, for a model the host's `Wardrik.LLM.Client` does not know. What it knows otherwise, and #{128_000} where it knows nothing |

  It is an agent's `Wardrik.History` unless its config names another, and a
  config with `%Wardrik.History.All{}` never compacts.

  Sizes are estimated from the text a history holds, as `Wardrik.LLM.Tokens`
  counts it, since no provider counts tokens before a call is made. The kept
  part always begins with a person's message, so a tool call is never
  separated from its result. A history with no such place to cut is left as it
  is, and so is one whose older part is only the summary an earlier compaction
  left there.

  An agent compacts as a turn begins, before the messages it answers join
  the history; see `prepare/3` for the summary itself.
  """

  alias Wardrik.Call
  alias Wardrik.Call.Pipeline
  alias Wardrik.Conversation
  alias Wardrik.Conversation.Assistant
  alias Wardrik.Conversation.ToolError
  alias Wardrik.Conversation.ToolResult
  alias Wardrik.Conversation.User
  alias Wardrik.Host
  alias Wardrik.LLM.Answer
  alias Wardrik.LLM.Client
  alias Wardrik.LLM.Model
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

  @doc "The context window of the model `run` asks, in tokens."
  @spec window(t(), Run.t()) :: pos_integer()
  def window(%__MODULE__{window: window}, _run) when is_integer(window), do: window

  def window(%__MODULE__{}, %Run{config: config, host: host}) do
    case Client.model(Host.llm(host), config.model_spec) do
      {:ok, %Model{window: window}} when is_integer(window) -> window
      _unknown -> @default_window
    end
  end

  @doc """
  Where `history` would be cut, if it has outgrown `compaction` for the
  model `run` asks: `{:ok, older, recent}`, or `:keep` where it has not, has
  nowhere to cut, or would have only an earlier summary to summarise.
  """
  @spec split(t(), Conversation.t(), Run.t()) ::
          {:ok, [Conversation.message()], [Conversation.message()]} | :keep
  def split(%__MODULE__{} = compaction, %Conversation{} = history, %Run{} = run) do
    messages = Conversation.to_list(history)
    tails = Tokens.tails(messages)
    window = window(compaction, run)

    if List.first(tails, 0) > compaction.at * window,
      do: cut(messages, tails, compaction.keep * window),
      else: :keep
  end

  # The kept part is the longest tail within `keep` tokens that begins with a
  # person's message, and at least that person's last message. Tails only
  # shrink, so the first that fits is the longest.
  defp cut(messages, tails, keep) do
    starts =
      for {{%User{}, tail}, index} <- Enum.with_index(Enum.zip(messages, tails)),
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
  defp summary?([%User{} = summary, %Assistant{} = acknowledgement]) do
    String.starts_with?(Conversation.text(summary), @summary_intro) and
      Conversation.text(acknowledgement) == @acknowledgement
  end

  defp summary?(_older), do: false

  @doc """
  Compacts `history` under `:run`, if `compaction` says it is due.

  The older part is summarised by the agent's own model, through
  `Wardrik.Call.Pipeline`, so the run's hooks decide and count the call like
  any other, and its `Wardrik.LLM.Dispatch` admits it. The summary and an
  acknowledgement take the older part's place, and the recent part follows
  word for word. `:keep` where nothing is due; `{:error, reason}` where the
  summary could not be made, which leaves the history as it was.

  The summary is made in a span of its own, `"compacting history"`, so a
  long one shows as what the agent is doing.

  An older part that takes more than half the model's window is summarised in
  parts, oldest first: each is written out as a transcript within that half,
  and asked about together with the summary of the parts before it, so no one
  request outgrows the model.
  """
  @spec prepare(t(), Conversation.t(), run: Run.t()) ::
          {:ok, Conversation.t()} | :keep | {:error, term()}
  def prepare(%__MODULE__{} = compaction, %Conversation{} = history, run: %Run{} = run) do
    with {:ok, older, recent} <- split(compaction, history, run),
         {:ok, summary} <- Run.span(run, "compacting history", &summarise(&1, compaction, older)) do
      {:ok,
       Conversation.new([
         User.new(@summary_intro <> summary),
         Assistant.new(@acknowledgement) | recent
       ])}
    end
  end

  defp summarise(%Run{} = run, compaction, older) do
    budget = trunc(@request_share * window(compaction, run))

    if Tokens.messages(older) <= budget do
      ask(run, older ++ [User.new(@ask)])
    else
      older
      |> parts(budget)
      |> Enum.reduce_while({:ok, nil}, &summarise_part(run, &1, &2))
      |> summarised()
    end
  end

  defp summarise_part(run, part, {:ok, summary}) do
    case ask(run, [User.new(continued(summary, part))]) do
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

  defp line(%User{} = message), do: "Person: " <> Conversation.text(message)
  defp line(%ToolResult{} = message), do: answered(message)
  defp line(%ToolError{} = message), do: answered(message)

  defp line(%Assistant{} = message) do
    text = Conversation.text(message)
    said = if text == "", do: [], else: ["You: " <> text]

    calls =
      for %{name: name, arguments: arguments} <- message.parts,
          do: "You called #{name} with #{written(arguments)}"

    Enum.join(said ++ calls, "\n")
  end

  defp answered(message), do: "#{message.name} answered: " <> Conversation.text(message)

  defp written(arguments) when is_binary(arguments), do: arguments
  defp written(arguments), do: JSON.encode!(arguments)

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
    request =
      Request.new(%{run.config | tools: [], system: @summarise}, Conversation.new(messages))

    case request |> Pipeline.model(run) |> Pipeline.run(&generate/1) do
      %Call{state: :waiting} = waiting -> {:error, {:parked, Call.prompt(waiting)}}
      %Call{state: :denied, denied: denied} -> {:error, {:policy_denied, denied.reason}}
      %Call{result: result} -> text(result)
    end
  end

  defp generate(%Call{run: run} = call),
    do: Call.answer(call, Client.generate(Host.llm(run.host), Pipeline.request(call)))

  defp text({:ok, %Answer{message: message}}) do
    case message |> Conversation.text() |> String.trim() do
      "" -> {:error, :empty_summary}
      summary -> {:ok, summary}
    end
  end

  defp text({:error, reason}), do: {:error, reason}

  defimpl Wardrik.History do
    defdelegate prepare(compaction, history, opts), to: Wardrik.Compaction
  end
end
