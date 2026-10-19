defmodule WardrikChannel.Test.Defined do
  @moduledoc """
  A test's host, its definitions kept in the suite's store and read under
  the context `fields` give, and the agents it defines there.
  """

  alias Wardrik.Definitions

  @doc "A host reading definitions under `Wardrik.context(fields)`, with `opts` among its own."
  def host(fields \\ [], opts \\ []),
    do: Wardrik.new([store: Wardrik.Test.store(), context: Wardrik.context(fields)] ++ opts)

  @doc "Keeps the definition `fields` write for `id` on `host`, as the host wrote it."
  def define(host, id, fields) do
    definitions = Wardrik.Host.definitions(host)

    {:ok, definition} =
      Wardrik.Definition.read(fields,
        id: id,
        source: :defaults,
        context: Definitions.context(definitions, id)
      )

    :ok = Definitions.put(definitions, definition)
    id
  end
end
