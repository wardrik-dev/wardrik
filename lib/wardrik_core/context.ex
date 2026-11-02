defmodule WardrikCore.Context do
  @moduledoc """
  The state passed through a turn's middleware.

  `step` is `:turn`, `:generate` (a model call), `{:tool_call, call}`, or `{:step, name}` for your
  own. Middleware reads and changes the rest, such as `messages`, `response` and `attributes`.
  """
  use WardrikCore.Private

  @type step :: :turn | :generate | {:tool_call, WardrikCore.ToolCall.t()} | {:step, String.t()}
  @type entry :: module() | {module(), term()}

  @type t() :: %__MODULE__{
          agent_id: String.t(),
          conversation: String.t() | nil,
          model: LLMDB.Model.t() | String.t(),
          step: step() | nil,
          messages: [ReqLLM.Message.t()],
          instructions: String.t() | nil,
          response: ReqLLM.Response.t() | {:ok, term()} | {:error, term()} | nil,
          capabilities: [entry()],
          credentials: entry() | nil,
          keys: entry() | nil,
          events: entry() | nil,
          tools: [WardrikCore.Tool.t()],
          middleware: [entry()],
          max_rounds: pos_integer() | :infinity,
          retries: WardrikCore.Retry.t(),
          principal: WardrikCore.Principal.t() | nil,
          timeout: timeout(),
          resume: WardrikCore.Resume.t() | nil,
          checkpoint: (map() -> :ok) | nil,
          call_started: (String.t() -> :ok) | nil,
          on_chunk: [(ReqLLM.StreamChunk.t() -> any())],
          private: map(),
          metadata: map(),
          span: WardrikCore.Span.t() | nil,
          attributes: map(),
          measurements: %{optional(term()) => number()},
          prices: %{optional(String.t()) => WardrikCore.price()},
          subagent: String.t() | nil
        }

  defstruct [
    :agent_id,
    :conversation,
    :model,
    :step,
    :response,
    :span,
    :resume,
    :checkpoint,
    :call_started,
    :principal,
    :credentials,
    :keys,
    :events,
    :instructions,
    messages: [],
    capabilities: [],
    tools: [],
    middleware: [],
    max_rounds: 25,
    retries: [],
    timeout: :infinity,
    on_chunk: [],
    private: %{},
    metadata: %{},
    attributes: %{},
    measurements: %{},
    prices: %{},
    subagent: nil
  ]

  def new(opts) do
    struct!(__MODULE__, opts)
  end

  @doc "Runs `fun` through the context's middleware. The first in the list runs outermost."
  @spec run(t(), WardrikCore.Middleware.next()) :: WardrikCore.Middleware.result()
  def run(%__MODULE__{middleware: middleware} = context, fun) do
    middleware
    |> Enum.reverse()
    |> Enum.reduce(fun, fn entry, next ->
      {module, opts} = entry(entry)
      &module.call(&1, next, opts)
    end)
    |> then(& &1.(context))
  end

  @doc """
  Sets an attribute on the current step, like an OpenTelemetry span attribute.

      Context.attribute(context, "gen_ai.tool.name", call.name)

  Use OpenTelemetry's names, or your own prefix.
  """
  @spec attribute(t(), String.t() | atom(), term()) :: t()
  def attribute(%__MODULE__{attributes: attributes} = context, key, value),
    do: %{context | attributes: Map.put(attributes, key, value)}

  @doc """
  Adds `amount` to the measurement `key`, such as tokens or dollars spent.

      Context.measure(context, :usd, 0.01)

  Measurements add up over the turn. Every model call measures `input_tokens`, `output_tokens`, and
  `usd` if the model has a price, or else counts `unpriced_calls`.
  """
  @spec measure(t(), term(), number()) :: t()
  def measure(%__MODULE__{measurements: measurements} = context, key, amount),
    do: %{context | measurements: Map.update(measurements, key, amount, &(&1 + amount))}

  @doc "Adds each of `measurements`, such as those `WardrikCore.evaluate/2` returns."
  @spec measure(t(), map()) :: t()
  def measure(%__MODULE__{} = context, measurements) do
    Enum.reduce(measurements, context, fn {key, amount}, context ->
      measure(context, key, amount)
    end)
  end

  @doc """
  Returns who the turn acts for: the sender of the latest message, or else the agent's own
  `principal`, or `nil`.
  """
  @spec acting_for(t()) :: WardrikCore.Principal.t() | nil
  def acting_for(%__MODULE__{messages: messages, principal: principal}) do
    messages
    |> Enum.reverse()
    |> Enum.find(fn message -> message.role == :user end)
    |> asked_by(principal)
  end

  defp asked_by(%{metadata: %{principal: %WardrikCore.Principal{} = asked}}, _agent), do: asked
  defp asked_by(_message, agent), do: agent

  @doc """
  Returns the labels in the turn's messages, or in `messages`, sorted and unique.

  `"outside"` marks content nobody on the agent's side wrote, such as a web page. A label stays
  until the history is cleared.
  """
  @spec labels(t() | [ReqLLM.Message.t()]) :: [String.t()]
  def labels(%__MODULE__{messages: messages}), do: labels(messages)

  def labels(messages) when is_list(messages),
    do: messages |> Enum.flat_map(&message_labels/1) |> Enum.uniq() |> Enum.sort()

  defp message_labels(%{metadata: %{labels: labels}}), do: labels
  defp message_labels(_message), do: []

  @doc "Returns the tool `call` names, or `nil`."
  @spec tool(t(), WardrikCore.ToolCall.t()) :: WardrikCore.Tool.t() | nil
  def tool(%__MODULE__{tools: tools}, %WardrikCore.ToolCall{name: name}),
    do: Enum.find(tools, &(&1.name == name))

  @doc "Returns a capability or middleware entry as `{module, opts}`. A bare module gets `[]`."
  @spec entry(entry()) :: {module(), term()}
  def entry({module, opts}) when is_atom(module), do: {module, opts}
  def entry(module) when is_atom(module), do: {module, []}

  @doc """
  Runs `fun` through the middleware as `step`, in a span of its own.

      Context.run(context, {:step, "summarize"}, &summarize/1)
  """
  @spec run(t(), step(), WardrikCore.Middleware.next()) :: WardrikCore.Middleware.result()
  def run(%__MODULE__{} = context, step, fun) do
    outer = Map.take(context, [:step, :on_chunk, :span, :attributes])

    case WardrikCore.Telemetry.span(context, step, &run(&1, fun)) do
      {:ok, context} -> {:ok, Map.merge(context, outer)}
      {:park, reason, context} -> {:park, reason, Map.merge(context, outer)}
      {:error, reason} -> {:error, reason}
    end
  end
end
