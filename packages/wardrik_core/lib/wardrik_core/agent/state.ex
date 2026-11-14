defmodule WardrikCore.Agent.State do
  @moduledoc false

  alias WardrikCore.Agent.Stored

  require Logger

  @type t() :: %__MODULE__{}
  @type state :: :idle | :due | :running | :waiting

  defstruct [
    :agent_id,
    :conversation,
    :model,
    :context,
    :task,
    :started_at,
    :turn_kind,
    :span,
    :parked,
    :checkpoint,
    :deferred,
    :unreadable,
    :configure,
    state: :idle,
    messages: [],
    pending_messages: [],
    in_flight: [],
    calls: %{},
    answered: [],
    answers: []
  ]

  @doc "Splits off the messages the next turn answers: those in a row from the same principal."
  @spec next_batch([ReqLLM.Message.t()]) :: {[ReqLLM.Message.t()], [ReqLLM.Message.t()]}
  def next_batch([first | _messages] = pending),
    do: Enum.split_while(pending, fn message -> same_principal?(message, first) end)

  defp same_principal?(message, other), do: principal_id(message) == principal_id(other)

  defp principal_id(message), do: id(principal(message))

  defp id(%WardrikCore.Principal{id: id}), do: id
  defp id(nil), do: nil

  defp principal(%ReqLLM.Message{metadata: metadata}), do: Map.get(metadata || %{}, :principal)

  @spec new(keyword()) :: t()
  def new(opts) do
    endpoints = endpoints(opts[:context])
    opts = Keyword.update!(opts, :model, &canonical_spec!(&1, endpoints))

    struct!(__MODULE__, opts)
  end

  defp endpoints(%WardrikCore.Context{endpoints: endpoints}), do: endpoints
  defp endpoints(nil), do: %{}

  @doc "Adds a message to the queue."
  @spec queue(t(), ReqLLM.Message.t()) :: t()
  def queue(%__MODULE__{} = state, message),
    do: %{state | pending_messages: state.pending_messages ++ [message]}

  @doc "Takes the next batch off the queue, as the messages in flight."
  @spec take_batch(t()) :: {[ReqLLM.Message.t()], t()}
  def take_batch(%__MODULE__{} = state) do
    {batch, rest} = next_batch(state.pending_messages)
    {batch, %{state | in_flight: batch, pending_messages: rest}}
  end

  @doc """
  Replaces the model or settings, from the next turn. An agent loaded without them is configured
  by them, and reads what it kept in its middleware's formats.
  """
  @spec configure(t(), keyword()) :: t()
  def configure(%__MODULE__{unreadable: {_reason, _json}} = state, _opts), do: state

  def configure(%__MODULE__{} = state, opts) do
    {model, settings} = Keyword.pop(opts, :model, state.model)
    Stored.resolve(%{state | model: model, context: configured(state, settings)})
  end

  defp configured(%__MODULE__{context: nil} = state, settings),
    do:
      WardrikCore.Context.new(
        [agent_id: state.agent_id, conversation: state.conversation] ++ settings
      )

  defp configured(%__MODULE__{context: context}, settings), do: struct!(context, settings)

  @doc "Returns why what the agent kept can't be read, or `nil`."
  @spec unreadable(t()) :: String.t() | nil
  def unreadable(%__MODULE__{unreadable: {reason, _json}}), do: reason
  def unreadable(%__MODULE__{}), do: nil

  @doc "Returns whether the agent can run turns: it's configured, and what it kept was read."
  @spec ready?(t()) :: boolean()
  def ready?(%__MODULE__{context: context, deferred: deferred, unreadable: unreadable}),
    do: context != nil and deferred == nil and unreadable == nil

  @doc "Marks a turn running in `task`."
  @spec running(t(), Task.t(), atom(), WardrikCore.Span.t()) :: t()
  def running(%__MODULE__{} = state, task, kind, span),
    do: %{
      state
      | state: :running,
        task: task,
        calls: %{},
        turn_kind: kind,
        span: span,
        started_at: System.monotonic_time()
    }

  @doc """
  Returns what the agent waits on, or `nil`. While a resumed turn runs, that's the parked calls
  not yet answered.
  """
  @spec waiting(t()) :: term() | nil
  def waiting(%__MODULE__{state: :waiting, parked: parked}), do: parked.reason

  def waiting(%__MODULE__{state: :running, parked: %{reason: {:tool_calls, results}}} = state),
    do:
      {:tool_calls,
       for(
         {call, {:park, _reason}} = result <- results,
         call.id not in state.answered,
         do: result
       )}

  def waiting(%__MODULE__{}), do: nil

  @doc "Notes the calls answered, by `input` and the answers kept, as the turn it resumes starts."
  @spec answered(t(), term()) :: t()
  def answered(%__MODULE__{} = state, input),
    do: %{
      state
      | answered: Enum.flat_map([input | Enum.map(state.answers, &elem(&1, 0))], &ids/1)
    }

  defp ids(input) when is_map(input), do: Map.keys(input)
  defp ids(_input), do: []

  @doc "Keeps answers to calls the running turn will park on again, to resume it with then."
  @spec answer_later(t(), map(), map()) :: t()
  def answer_later(%__MODULE__{} = state, input, metadata),
    do: %{
      state
      | answered: state.answered ++ Map.keys(input),
        answers: state.answers ++ [{input, metadata}]
    }

  @doc "Keeps a running turn's checkpoint, and the private data it saved."
  @spec checkpointed(t(), map()) :: t()
  def checkpointed(%__MODULE__{} = state, checkpoint) do
    state = keep_private(state, checkpoint.private)
    checkpoint = %{checkpoint | private: state.context.private}
    %{state | checkpoint: checkpoint, parked: nil}
  end

  @doc "Takes what a turn ended with: answered, parked, or failed."
  @spec finished(t(), WardrikCore.Middleware.result()) :: t()
  def finished(%__MODULE__{} = state, {:ok, context}),
    do: %{
      keep_private(state, context.private)
      | state: :idle,
        task: nil,
        parked: nil,
        checkpoint: nil,
        in_flight: [],
        messages: context.messages,
        answered: [],
        answers: []
    }

  def finished(%__MODULE__{} = state, {:park, reason, context}),
    do: %{
      keep_private(state, context.private)
      | state: :waiting,
        task: nil,
        checkpoint: nil,
        answered: [],
        parked: %{
          reason: reason,
          messages: context.messages,
          metadata: context.metadata,
          span: context.span,
          measurements: context.measurements
        }
    }

  def finished(%__MODULE__{} = state, {:error, _reason}), do: unanswered(state)

  @doc "Drops the turn, keeping the messages it was answering in the history."
  @spec unanswered(t()) :: t()
  def unanswered(%__MODULE__{} = state),
    do: %{
      state
      | state: :idle,
        task: nil,
        parked: nil,
        checkpoint: nil,
        in_flight: [],
        messages: state.messages ++ state.in_flight,
        answered: [],
        answers: []
    }

  # A value it couldn't save would stop every save after it, so it's dropped, and said so.
  defp keep_private(state, private) do
    {kept, dropped} = Stored.keepable(private)

    for key <- dropped,
        do:
          Logger.warning(
            "Agent #{state.agent_id} can't keep #{inspect(key)}'s private data: its key isn't a WardrikCore.Format"
          )

    put_in(state.context.private, kept)
  end

  @doc "What survives a restart, as JSON. See `WardrikCore.Agent.Stored`."
  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = state), do: Stored.dump(state)

  @doc "Reads a kept state. It's configured again before it runs. See `configure/2`."
  @spec load(term()) :: t()
  def load(json), do: Stored.load(json)

  @doc false
  @spec canonical_prices!(%{optional(ReqLLM.model_input()) => WardrikCore.price()}) ::
          %{optional(String.t()) => WardrikCore.price()}
  def canonical_prices!(prices),
    do: Map.new(prices, fn {spec, price} -> {canonical_spec!(spec), price} end)

  @doc false
  @spec canonical_endpoints!(%{optional(String.t() | atom()) => WardrikCore.endpoint()}) ::
          %{optional(String.t()) => WardrikCore.endpoint()}
  def canonical_endpoints!(endpoints),
    do: Map.new(endpoints, fn {name, endpoint} -> {to_string(name), endpoint!(endpoint)} end)

  @endpoint NimbleOptions.new!(
              model: [type: :string, required: true],
              base_url: [type: :string, required: true],
              key: [type: :string]
            )

  defp endpoint!(endpoint) do
    endpoint
    |> NimbleOptions.validate!(@endpoint)
    |> Keyword.update!(:model, &canonical_spec!/1)
  end

  @doc false
  @spec canonical_spec!(ReqLLM.model_input(), map()) :: String.t()
  def canonical_spec!(spec, endpoints \\ %{})

  def canonical_spec!(name, endpoints) when is_map_key(endpoints, name), do: name

  def canonical_spec!(spec, _endpoints) do
    case ReqLLM.model(spec) do
      {:ok, model} -> LLMDB.Model.spec(model)
      {:error, reason} -> raise ArgumentError, "Invalid model: #{inspect(reason)}"
    end
  end
end
