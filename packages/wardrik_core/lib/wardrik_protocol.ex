defmodule WardrikProtocol do
  @moduledoc """
  The JSON Schemas of what Wardrik sends and takes: each event's data, the
  CloudEvent that carries it, and the HTTP API's resources.

  Each schema is a file in `priv/v1` whose `$id` is
  `urn:wardrik:schema:v1:<file name>`:

    * `<noun>.<verb>.json` - the data of a CloudEvent of type
      `wardrik.<noun>.<verb>`, and its `dataschema`
    * `cloudevent.json` - the envelope every event travels in
    * `defs.json` - the types events and resources share, under `$defs`
    * `input_<operation>.json` - what an operation of `Wardrik.Catalog` takes,
      by its name with `_` for `.`, such as `input_agent_trigger_set.json`
    * the rest - one per HTTP API resource, such as `agent.json`

  Beside them, `priv/openapi.json` is the HTTP API whole, in OpenAPI 3.1:
  every route, what it takes and what it answers, each a `$ref` to the
  schemas above (`openapi/0`). `priv/openapi.bundled.json` is the same with
  every schema in it, for a client generator; see `WardrikProtocol.OpenAPI`.

  `WardrikProtocol.Resolver` finds them by `$id` for JSV:

      root = JSV.build!(%{"$ref" => "urn:wardrik:schema:v1:agent"}, resolver: WardrikProtocol.Resolver)
      {:ok, _} = JSV.validate(agent, root)
  """

  alias WardrikProtocol.Inline

  @glob "../../priv/v1" |> Path.expand(__ENV__.file) |> Path.join("*.json")
  @files @glob |> Path.wildcard() |> Enum.sort()

  for file <- @files, do: @external_resource(file)

  @doc "Where the schemas are as files, for a reader that takes them from disk rather than by `$id`."
  @spec dir() :: Path.t()
  def dir, do: Application.app_dir(:wardrik_core, "priv/v1")

  @doc "Where `openapi.json` is, whose `$ref`s name the schemas in `dir/0` as `v1/<file name>`."
  @spec openapi() :: Path.t()
  def openapi, do: Application.app_dir(:wardrik_core, "priv/openapi.json")

  @doc """
  The schema `name`, such as `"input_agent_trigger_set"`, whole: each `$ref`
  to another of the protocol's schemas, or to a type of `defs.json`, is put
  in its place, so a reader that follows no `$id`, as a model reading a
  tool's parameters, has all of it. The schemas are read into this module
  when it compiles, and it compiles again when one changes.
  """
  @spec schema(String.t()) :: map()
  for file <- @files, name = Path.basename(file, ".json") do
    def schema(unquote(name)), do: unquote(Macro.escape(Inline.schema(Path.dirname(file), name)))
  end

  # Compiles again when a schema is added or removed, as well as changed.
  @doc false
  def __mix_recompile__?, do: @glob |> Path.wildcard() |> Enum.sort() != @files
end
