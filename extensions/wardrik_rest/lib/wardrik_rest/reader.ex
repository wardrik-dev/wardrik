defmodule WardrikRest.Reader do
  @moduledoc """
  Reads an API's description into a `WardrikRest.Spec`.

  A source is `{module, opts}`: a module with this behaviour, and what it reads.
  `WardrikRest.Discovery` reads Google Discovery documents. Write one for another format to load
  its APIs the same way:

      defmodule MyApp.Described do
        @behaviour WardrikRest.Reader

        @impl true
        def read(opts), do: {:ok, %WardrikRest.Spec{...}}
      end

      WardrikRest.API.load({MyApp.Described, path: "priv/api.json"}, name: "my_api", ...)

  The spec's schemas are JSON Schema, and refer to its `types` as `%{"$ref" => name}`; each tool's
  schema is fitted from them. See `WardrikRest.Spec`.
  """

  alias WardrikRest.Spec

  @typedoc "A reader and its options."
  @type t() :: {module(), keyword()}

  @doc "Returns the spec, or why the description can't be read."
  @callback read(opts :: keyword()) :: {:ok, Spec.t()} | {:error, String.t()}

  @doc "Reads `source` with its reader."
  @spec read(t()) :: {:ok, Spec.t()} | {:error, String.t()}
  def read({module, opts}) when is_atom(module) and is_list(opts), do: module.read(opts)
end
