defmodule Wardrik.Workspace.Spec do
  @moduledoc """
  What an agent's file tools reach: the `:store`, its `:own` mount, and `:shared` mounts.
  """

  alias Wardrik.Workspace.Mount
  alias Wardrik.Workspace.Path

  @enforce_keys [:store, :own]
  defstruct [:store, :own, shared: []]

  @type t() :: %__MODULE__{store: Wardrik.Store.t(), own: Mount.t(), shared: [Mount.t()]}

  @doc "Builds a spec from `Wardrik.Workspace`'s options: `:store`, `:tree` and `:shared`."
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      store: Keyword.fetch!(opts, :store),
      own: %Mount{tree: Keyword.fetch!(opts, :tree)},
      shared: Keyword.get(opts, :shared, [])
    }
  end

  @doc "Returns the mount `path` is in and the path within its tree, or `{:error, reason}`."
  @spec resolve(t(), term()) :: {:ok, Mount.t(), String.t()} | {:error, String.t()}
  def resolve(spec, path) do
    with {:ok, path} <- Path.normalize(path), do: mounted(spec, path)
  end

  @doc "Returns `path` as the agent sees it, prefixed with `shared/<name>/` for a shared mount."
  @spec shown(Mount.t(), String.t()) :: String.t()
  def shown(%Mount{name: nil}, path), do: path
  def shown(%Mount{name: name}, path), do: "shared/#{name}/#{path}"

  @doc "Returns every mount the spec reaches, its own first."
  @spec mounts(t()) :: [Mount.t()]
  def mounts(%__MODULE__{own: own, shared: shared}), do: [own | shared]

  defp mounted(spec, "shared/" <> rest) do
    [name | path] = String.split(rest, "/", parts: 2)

    case {Enum.find(spec.shared, &(&1.name == name)), path} do
      {%Mount{} = mount, [path]} -> {:ok, mount, path}
      _unshared -> {:error, "nothing is shared with you as shared/#{name}"}
    end
  end

  defp mounted(spec, path), do: {:ok, spec.own, path}
end
