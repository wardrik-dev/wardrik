defmodule WardrikCore.Test.Echo do
  @moduledoc false
  @behaviour Wardrik.Capability

  @impl true
  def tools(_context, _opts) do
    [
      Wardrik.Tool.new!(
        name: "echo",
        description: "Echoes text",
        schema: [text: [type: :string]],
        run: fn args, _context -> {:ok, Map.get(args, :text, "")} end,
        annotations: [idempotent: true]
      )
    ]
  end
end

defmodule WardrikCore.Test.NeedsApproval do
  @moduledoc false
  @behaviour Wardrik.Format

  defstruct []

  @impl true
  def type, do: "test_needs_approval"

  @impl true
  def version, do: 1

  @impl true
  def dump(%__MODULE__{}), do: %{}

  @impl true
  def load(1, %{}), do: {:ok, %__MODULE__{}}
end

defmodule WardrikCore.Test.Spend do
  @moduledoc false
  @behaviour Wardrik.Format

  defstruct []

  @impl true
  def type, do: "test_spend"

  @impl true
  def version, do: 1

  @impl true
  def dump(%__MODULE__{}), do: %{}

  @impl true
  def load(1, %{}), do: {:ok, %__MODULE__{}}
end

defmodule WardrikCore.Test.Twin do
  @moduledoc false
  @behaviour Wardrik.Middleware

  defmodule Reason do
    @moduledoc false
    @behaviour Wardrik.Format

    @impl true
    def type, do: "test_needs_approval"

    @impl true
    def version, do: 1

    @impl true
    def dump(reason), do: reason

    @impl true
    def load(1, reason), do: {:ok, reason}
  end

  @impl true
  def formats, do: [Reason]

  @impl true
  def call(context, next, _opts), do: next.(context)
end

defmodule WardrikCore.Test.ParkTools do
  @moduledoc false
  @behaviour Wardrik.Middleware

  alias Wardrik.Context
  alias WardrikCore.Test.NeedsApproval

  @impl true
  def formats, do: [NeedsApproval]

  @impl true
  def call(
        %Context{
          step: {:tool_call, call},
          resume: %Wardrik.Resume{reason: %NeedsApproval{}, input: input}
        } = context,
        next,
        _opts
      ) do
    case Map.get(input, call.id) do
      :approve -> next.(context)
      {:deny, reason} -> {:error, reason}
      nil -> {:park, %NeedsApproval{}, context}
    end
  end

  def call(%Context{step: {:tool_call, _}} = context, _next, _opts),
    do: {:park, %NeedsApproval{}, context}

  def call(context, next, _opts), do: next.(context)
end

defmodule WardrikCore.Test.ParkGenerate do
  @moduledoc false
  @behaviour Wardrik.Middleware

  alias Wardrik.Context
  alias WardrikCore.Test.Spend

  @impl true
  def formats, do: [Spend]

  @impl true
  def call(
        %Context{step: :generate, resume: %Wardrik.Resume{reason: %Spend{}, input: :ok}} =
          context,
        next,
        _opts
      ),
      do: next.(context)

  def call(%Context{step: :generate} = context, _next, _opts), do: {:park, %Spend{}, context}
  def call(context, next, _opts), do: next.(context)
end

defmodule WardrikCore.Test.LLM do
  @moduledoc false

  def answer(text), do: response(ReqLLM.Context.assistant(text))
  def calling(calls), do: response(ReqLLM.Context.assistant("", tool_calls: calls))

  def call(id, name, args \\ %{}), do: ReqLLM.ToolCall.new(id, name, JSON.encode!(args))

  defp response(message),
    do: %ReqLLM.Response{id: "resp", model: "test", context: nil, message: message}
end
