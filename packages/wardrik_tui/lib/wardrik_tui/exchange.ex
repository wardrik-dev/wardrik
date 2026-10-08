defmodule WardrikTUI.Exchange do
  @moduledoc """
  One tool call of a conversation and what it returned, as `WardrikTUI.App`
  keeps them for `/tools`.

  A call is recorded when the model makes it, with `output` and `ok?` still
  `nil`, and completed when its result arrives: by `id` when both sides carry
  one, otherwise the oldest call of that name still waiting.

  A conversation's calls are kept in a `WardrikTUI.Exchange.Log`, so that
  recording or completing one takes the same time however many came before,
  as when a long conversation is replayed; `list/1` gives them oldest first.
  """

  alias WardrikTUI.Exchange.Log

  @type t() :: %__MODULE__{
          id: String.t() | nil,
          name: String.t(),
          arguments: map(),
          output: String.t() | nil,
          ok?: boolean() | nil
        }

  @enforce_keys [:name, :arguments]
  defstruct id: nil, name: nil, arguments: %{}, output: nil, ok?: nil

  @doc "A log with no calls in it."
  @spec new() :: Log.t()
  def new, do: %Log{}

  @doc "Records a call at the end of `log`."
  @spec call(Log.t(), String.t() | nil, String.t(), map()) :: Log.t()
  def call(%Log{} = log, id, name, arguments) when is_binary(name),
    do: record(log, %__MODULE__{id: id, name: name, arguments: arguments || %{}})

  @doc """
  Completes the call `id` names, or the oldest call of `name` still waiting,
  with its output. A result no call is waiting for is recorded on its own.
  """
  @spec finish(Log.t(), String.t() | nil, String.t(), String.t(), boolean()) :: Log.t()
  def finish(%Log{} = log, id, name, output, ok?) do
    case named(log, id) || waiting(log, name) do
      {nil, log} ->
        record(log, %__MODULE__{id: id, name: name, arguments: %{}, output: output, ok?: ok?})

      {n, log} ->
        %{log | calls: Map.update!(log.calls, n, &%{&1 | output: output, ok?: ok?})}
    end
  end

  @doc "Whether the call has its result."
  @spec settled?(t()) :: boolean()
  def settled?(%__MODULE__{output: output}), do: output != nil

  @doc "Every call in `log`, oldest first."
  @spec list(Log.t()) :: [t()]
  def list(%Log{calls: calls, count: count}), do: for(n <- 0..(count - 1)//1, do: calls[n])

  @doc "The `index`th call in `log`, counting from 1, or `nil`."
  @spec at(Log.t(), integer()) :: t() | nil
  def at(%Log{calls: calls}, index) when is_integer(index), do: Map.get(calls, index - 1)

  @doc "Whether `log` has no calls."
  @spec empty?(Log.t()) :: boolean()
  def empty?(%Log{count: count}), do: count == 0

  defp record(%Log{count: n} = log, exchange) do
    log = %{log | calls: Map.put(log.calls, n, exchange), count: n + 1}
    log = if exchange.id, do: %{log | ids: Map.put_new(log.ids, exchange.id, n)}, else: log

    if settled?(exchange), do: log, else: wait(log, exchange.name, n)
  end

  defp wait(log, name, n),
    do: %{log | waiting: Map.update(log.waiting, name, :queue.from_list([n]), &:queue.in(n, &1))}

  defp named(_log, nil), do: nil

  defp named(log, id) do
    case Map.fetch(log.ids, id) do
      {:ok, n} -> {n, log}
      :error -> nil
    end
  end

  # The oldest call of `name` with no result yet. A call completed by its id
  # stays in the queue until it reaches the front, and is dropped there.
  defp waiting(log, name) do
    queue = Map.get(log.waiting, name, :queue.new())

    case :queue.peek(queue) do
      :empty ->
        {nil, log}

      {:value, n} ->
        if settled?(log.calls[n]),
          do: waiting(%{log | waiting: Map.put(log.waiting, name, :queue.drop(queue))}, name),
          else: {n, log}
    end
  end
end
