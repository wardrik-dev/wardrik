defmodule WardrikProtocol do
  @moduledoc """
  Wardrik's wire format: events as CloudEvents, and operations as OpenAPI.

      schema = JSV.build!(WardrikProtocol.schema("run.started"))
      {:ok, _data} = JSV.validate(event["data"], schema)

      %{method: "post", path: "/v1/agents/{agent}/messages"} = WardrikProtocol.operation("agent.ask")
  """

  alias WardrikProtocol.Inline
  alias WardrikProtocol.Operations

  @dir Application.app_dir(:wardrik_protocol, "priv/v1")
  @files @dir |> Path.join("*.json") |> Path.wildcard() |> Enum.sort()
  @names @files |> Enum.map(&Path.basename(&1, ".json")) |> List.delete("openapi")
  @events Enum.filter(@names, &String.contains?(&1, "."))
  @document Operations.document(@dir)
  @operations Operations.build(@document)

  @typedoc """
  An operation from `openapi.json`.

    * `:id` - its `operationId`, as `"agent.ask"`.
    * `:summary` and `:description` - what it does.
    * `:method` and `:path` - its HTTP route.
    * `:action` - what the caller must be allowed to do.
    * `:effect` - `"read"`, `"change"` or `"destructive"`.
    * `:subject` - what it acts on: `"agent"`, `"agents"`, `"deployment"`, `"hook"` (a request
      that proves itself with a secret, not a caller) or `"channel"` (a chat app's request, which
      its channel verifies).
    * `:parameters` - which input fields go in the HTTP path or query.
    * `:input` - one schema for its parameters and body together.
    * `:status` - the HTTP status it returns on success.
    * `:output` - its output schema, or `nil`.
    * `:stream` - `true` if it can stream events.
  """
  @type operation() :: %{
          id: String.t(),
          summary: String.t(),
          description: String.t() | nil,
          method: String.t(),
          path: String.t(),
          action: String.t(),
          effect: String.t(),
          subject: String.t(),
          parameters: [%{name: String.t(), in: String.t()}],
          input: map(),
          status: pos_integer(),
          output: map() | nil,
          stream: boolean()
        }

  for file <- @files, do: @external_resource(file)

  @doc "Returns the directory of the schema files."
  @spec dir() :: Path.t()
  def dir, do: @dir

  @doc "Lists every event type, like `wardrik.run.started`."
  @spec types() :: [String.t()]
  def types, do: Enum.map(@events, &("wardrik." <> &1))

  @doc """
  Returns the `dataschema` for an event type.

      WardrikProtocol.dataschema("wardrik.run.started")
      #=> "urn:wardrik:schema:v1:run.started"

  Raises `FunctionClauseError` for an unknown type.
  """
  @spec dataschema(String.t()) :: String.t()
  def dataschema("wardrik." <> name) when name in @events, do: "urn:wardrik:schema:v1:" <> name

  @doc "Returns `true` if events of the type are sent as they happen and never stored."
  @spec live?(String.t()) :: boolean()
  def live?("wardrik." <> name) when name in @events,
    do: Map.get(schema(name), "x-wardrik-live", false)

  @doc """
  Returns the schema `name` with every `$ref` inlined.

  `name` is a file name in `dir/0` without `.json`, like `run.started`, `cloudevent` or `defs`.
  """
  @spec schema(String.t()) :: map()
  for name <- @names do
    def schema(unquote(name)), do: unquote(Macro.escape(Inline.schema(@dir, name)))
  end

  @doc "Returns the OpenAPI document, with every `$ref` to another schema file inlined."
  @spec openapi() :: map()
  def openapi, do: @document

  @doc "Lists every operation, ordered by path."
  @spec operations() :: [operation()]
  def operations, do: @operations

  @doc "Returns the operation with ID `id`, like `agent.ask`, or `nil`."
  @spec operation(String.t()) :: operation() | nil
  for %{id: id} = operation <- @operations do
    def operation(unquote(id)), do: unquote(Macro.escape(operation))
  end

  def operation(_id), do: nil

  @doc false
  def __mix_recompile__?,
    do: @dir |> Path.join("*.json") |> Path.wildcard() |> Enum.sort() != @files
end
