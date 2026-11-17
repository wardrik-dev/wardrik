defmodule Wardrik.HTTP.MCP.Tool do
  @moduledoc """
  A tool `Wardrik.HTTP.MCP` serves: an operation, and the function that runs it for the caller.

      Wardrik.HTTP.MCP.Tool.new(WardrikProtocol.operation("agent.read"), fn input ->
        Wardrik.Scope.run(scope, "agent.read", input)
      end)

    * `:name` - the operation's ID with `_` for `.`, as `agent_read`.
    * `:title` - the operation's summary.
    * `:description` - its summary and description.
    * `:input` - its input, as JSON Schema.
    * `:effect` - `"read"`, `"change"` or `"destructive"`. It sets the tool's annotations.
    * `:run` - takes the arguments, and returns `{:ok, output}` or `{:error, %Wardrik.Error{}}`.
  """

  alias Wardrik.Error

  @enforce_keys [:name, :title, :description, :input, :effect, :run]
  defstruct @enforce_keys

  @typedoc "What a tool is made from: an operation's ID, summary, description, input and effect."
  @type operation() :: %{
          required(:id) => String.t(),
          required(:summary) => String.t(),
          required(:description) => String.t() | nil,
          required(:input) => map(),
          required(:effect) => String.t(),
          optional(atom()) => term()
        }

  @type t() :: %__MODULE__{
          name: String.t(),
          title: String.t(),
          description: String.t(),
          input: map(),
          effect: String.t(),
          run: (map() -> {:ok, term()} | {:error, Error.t()})
        }

  @doc "Returns the tool for `operation`, which `run` runs."
  @spec new(operation(), (map() -> {:ok, term()} | {:error, Error.t()})) :: t()
  def new(operation, run) do
    %__MODULE__{
      name: String.replace(operation.id, ".", "_"),
      title: operation.summary,
      description: build_description(operation),
      input: operation.input,
      effect: operation.effect,
      run: run
    }
  end

  @doc "Returns `tool` as `tools/list` lists it."
  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = tool) do
    annotations =
      tool.effect
      |> build_annotations()
      |> Map.put("title", tool.title)

    %{
      "name" => tool.name,
      "title" => tool.title,
      "description" => tool.description,
      "inputSchema" => tool.input,
      "annotations" => annotations
    }
  end

  @doc "Returns what a tool for `operation` says it does: its summary, then its description."
  @spec build_description(operation()) :: String.t()
  def build_description(%{summary: summary, description: nil}), do: summary <> "."

  def build_description(%{summary: summary, description: description}),
    do: summary <> ". " <> description

  defp build_annotations("read"),
    do: %{"readOnlyHint" => true, "idempotentHint" => true, "openWorldHint" => false}

  defp build_annotations("change"),
    do: %{"readOnlyHint" => false, "destructiveHint" => false, "openWorldHint" => false}

  defp build_annotations("destructive"),
    do: %{"readOnlyHint" => false, "destructiveHint" => true, "openWorldHint" => false}
end
