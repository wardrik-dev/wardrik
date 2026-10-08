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
    * the rest - one per HTTP API resource, such as `agent.json`

  `WardrikProtocol.Resolver` finds them by `$id` for JSV:

      root = JSV.build!(%{"$ref" => "urn:wardrik:schema:v1:agent"}, resolver: WardrikProtocol.Resolver)
      {:ok, _} = JSV.validate(agent, root)
  """

  @doc "Where the schemas are as files, for a reader that takes them from disk rather than by `$id`."
  @spec dir() :: Path.t()
  def dir, do: Application.app_dir(:wardrik_protocol, "priv/v1")
end
