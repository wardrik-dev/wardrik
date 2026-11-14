defmodule WardrikCore.Format do
  @moduledoc """
  How a kind of value is kept as JSON, so a release reads what an earlier one wrote.

      defmodule MyApp.Theme do
        @behaviour WardrikCore.Format

        @impl true
        def version, do: 2

        @impl true
        def dump(%{name: name, dark: dark}), do: %{"name" => name, "dark" => dark}

        @impl true
        def load(2, %{"name" => name, "dark" => dark}), do: {:ok, %{name: name, dark: dark}}
        def load(1, name) when is_binary(name), do: {:ok, %{name: name, dark: false}}
      end

    * Bump `c:version/0` when `c:dump/1` changes shape, and keep a `c:load/2` clause for each
      earlier version.
    * A value written by a later release, with a version above this one's, isn't read.

  `Wardrik.Store` keeps a scope's values in the format it names. An agent keeps its park reasons
  and private data in the formats its middleware and capabilities declare, each by its
  `c:type/0`. See `WardrikCore.Middleware`.
  """

  @typedoc "What JSON holds: maps with string keys, lists, strings, numbers, booleans and `nil`."
  @type json() :: %{String.t() => json()} | [json()] | String.t() | number() | boolean() | nil

  @doc "The version `c:dump/1` writes."
  @callback version() :: pos_integer()

  @doc "Returns `value` as JSON."
  @callback dump(value :: term()) :: json()

  @doc "Returns the value `json` holds, written at `version`, which is at most `c:version/0`."
  @callback load(version :: pos_integer(), json()) :: {:ok, term()} | {:error, String.t()}

  @doc """
  The name the value is kept by where it sits beside values of other formats, as
  `"tool_approval"`. Unique among an agent's formats.
  """
  @callback type() :: String.t()

  @optional_callbacks type: 0
end
