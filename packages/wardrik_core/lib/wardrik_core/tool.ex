defmodule WardrikCore.Tool do
  @moduledoc """
  A tool an agent may call.

      WardrikCore.Tool.new!(
        name: "order_status",
        description: "Say where an order is.",
        schema: [order_id: [type: :string, required: true]],
        run: fn %{order_id: id}, _context -> {:ok, MyApp.Orders.status(id)} end,
        annotations: [read_only: true]
      )

  ## Return values

  `run` takes the checked arguments and the `WardrikCore.Context`. It returns:

    * `{:ok, answer}` or `{:error, reason}`.
    * `{:ok, answer, context}` or `{:error, reason, context}`, such as with a cost measured.
    * `{:park, reason}` - waits for a person.

  An answer can carry labels, such as `"outside"` for text from a stranger:

      {:ok, %ReqLLM.ToolResult{output: page, metadata: %{labels: ["outside"]}}}

  ## Annotations

    * `:read_only` - it changes nothing.
    * `:destructive` - what it changes can't be undone.
    * `:idempotent` - a call is safe to repeat.
    * `:open_world` - it reaches outside your systems, such as the web.
    * `:timeout` - how long a call may take, in milliseconds.
    * `:resources` - what a call acts on, as `fn args -> [args["path"]] end`.
    * `:labels` - labels every answer carries.

  A `read_only` or `idempotent` call is retried, and repeated after a crash. Any other call lost in
  a crash parks as `:in_doubt`.
  """
  use WardrikCore.Private
  alias WardrikCore.Context
  alias WardrikCore.ToolCall

  @type answer ::
          {:ok, term()}
          | {:ok, term(), Context.t()}
          | {:error, term()}
          | {:error, term(), Context.t()}
          | {:park, term()}

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          schema: keyword() | map(),
          run: (map(), Context.t() -> answer()),
          annotations: %{optional(atom()) => term()},
          private: map(),
          req_llm: ReqLLM.Tool.t()
        }

  @enforce_keys [:name, :description, :run, :req_llm]
  defstruct [:name, :description, :run, :req_llm, schema: [], annotations: %{}, private: %{}]

  @doc """
  Builds a tool. Raises if a required option is missing.

  ## Options

    * `:name` - required.
    * `:description` - required. What the model reads to decide when to call it.
    * `:run` - required. A function of the arguments and the context.
    * `:schema` - the arguments, as a NimbleOptions keyword list or a JSON Schema map. `[]` by
      default.
    * `:annotations` - see above.
  """
  @spec new!(keyword()) :: t()
  def new!(opts) do
    {annotations, opts} = Keyword.pop(opts, :annotations, [])
    tool = __MODULE__ |> struct!(Keyword.put(opts, :req_llm, nil)) |> annotate(annotations)

    req_llm =
      ReqLLM.Tool.new!(
        name: tool.name,
        description: tool.description,
        parameter_schema: tool.schema,
        callback: fn _args -> {:error, :run_by_wardrik_core} end
      )

    %{tool | req_llm: req_llm}
  end

  @doc "Adds `annotations`, such as `read_only: true`. Replaces any with the same key."
  @spec annotate(t(), keyword() | map()) :: t()
  def annotate(%__MODULE__{annotations: annotations} = tool, new),
    do: %{tool | annotations: Map.merge(annotations, Map.new(new))}

  @doc "Returns the annotation `key`, or `default` if the tool doesn't set it."
  @spec annotation(t(), atom(), term()) :: term()
  def annotation(%__MODULE__{annotations: annotations}, key, default \\ nil),
    do: Map.get(annotations, key, default)

  @doc "Returns whether a call to the tool is safe to repeat: it's `read_only` or `idempotent`."
  @spec repeatable?(t()) :: boolean()
  def repeatable?(%__MODULE__{} = tool),
    do: annotation(tool, :read_only) == true or annotation(tool, :idempotent) == true

  @doc """
  Runs the tool `call` names, after checking its arguments. Returns `{:error, reason}` if there's no
  such tool or the arguments don't match.
  """
  @spec call([t()], ToolCall.t(), Context.t()) :: answer()
  def call(tools, %ToolCall{} = call, %Context{} = context) do
    with %__MODULE__{} = tool <-
           Enum.find(tools, {:error, "Unknown tool: #{call.name}"}, &(&1.name == call.name)),
         {:ok, args} <- validate(tool, call.arguments) do
      tool.run.(args, context)
    end
  end

  defp validate(%__MODULE__{schema: schema}, args) when is_map(schema),
    do: ReqLLM.Schema.validate(args, schema)

  defp validate(%__MODULE__{req_llm: req_llm}, args),
    do: ReqLLM.Tool.validate_input(req_llm, args)
end
