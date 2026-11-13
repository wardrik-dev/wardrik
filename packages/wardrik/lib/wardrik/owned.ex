defmodule Wardrik.Owned do
  @moduledoc """
  What owners hold, by kind and name: OAuth apps, MCP servers and notify targets.

  An owner is a name the host gives, as `"acme"`, `"acme/@jon"` or `"deployment"`. Wardrik
  keys records by it and never reads it. The host's authorizer decides who may act for an owner,
  and who may use what another owner holds.

    * A record is reached by its reference, which `reference/2` makes from its owner and name.
      A reference is only looked up, never taken apart.
    * `"deployment"` holds what the deployment declares in its options. Those are read only.
  """

  alias Wardrik.Authorizer
  alias WardrikCore.Principal

  @scope "wardrik_owned"
  @deployment "deployment"

  @doc "Returns the owner that holds what the deployment declares: `\"deployment\"`."
  @spec deployment() :: String.t()
  def deployment, do: @deployment

  @doc """
  Returns the reference of `owner`'s `name`, unique among records of a kind.

      Wardrik.Owned.reference("acme/@jon", "linear")
      #=> "acme%2F%40jon:linear"
  """
  @spec reference(String.t(), String.t()) :: String.t()
  def reference(owner, name), do: URI.encode_www_form(owner) <> ":" <> name

  @doc "Returns the record of `kind` at `reference`, or `nil`."
  @spec get(Wardrik.t(), String.t(), String.t()) :: map() | nil
  def get(wardrik, kind, reference) do
    wardrik
    |> store()
    |> Wardrik.Store.get(kind <> "/" <> reference)
  end

  @doc "Keeps `record`, which has `:owner` and `:name`, in place of any with its reference."
  @spec put(Wardrik.t(), String.t(), map()) :: :ok | {:error, term()}
  def put(wardrik, kind, %{owner: owner, name: name} = record) do
    store = store(wardrik)
    with {:ok, _vsn} <- Wardrik.Store.put(store, path(kind, owner, name), record), do: :ok
  end

  @doc "Deletes `owner`'s `name` of `kind`."
  @spec delete(Wardrik.t(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def delete(wardrik, kind, owner, name) do
    wardrik
    |> store()
    |> Wardrik.Store.delete(path(kind, owner, name))
  end

  @doc "Returns what `owner` holds of `kind`."
  @spec own(Wardrik.t(), String.t(), String.t()) :: [map()]
  def own(wardrik, kind, owner),
    do: entries(wardrik, kind <> "/" <> reference(owner, ""))

  @doc "Returns what every owner holds of `kind`."
  @spec all(Wardrik.t(), String.t()) :: [map()]
  def all(wardrik, kind), do: entries(wardrik, kind <> "/")

  @doc """
  Returns the one of `candidates`, all of one name, that `principal` uses: its own, else the one
  another owner lets it use, else the deployment's. `nil` if it may use none, and
  `{:error, owners}` when more than one other owner's would do.

  Using another owner's is `action` on `{resource, owner}`, as the authorizer decides.
  """
  @spec chosen(Wardrik.t(), Principal.t(), [map()], {String.t(), atom()}) ::
          map() | nil | {:error, [String.t()]}
  def chosen(wardrik, %Principal{id: id} = principal, candidates, use) do
    case Enum.find(candidates, &(&1.owner == id)) do
      nil -> others(wardrik, principal, candidates, use)
      own -> own
    end
  end

  defp others(wardrik, principal, candidates, use) do
    {deployment, others} =
      candidates
      |> Enum.filter(&usable?(wardrik, principal, &1, use))
      |> Enum.split_with(&(&1.owner == @deployment))

    case others do
      [one] -> one
      [] -> List.first(deployment)
      several -> {:error, Enum.map(several, & &1.owner)}
    end
  end

  @doc "Returns whether `principal` may use `record`, which another owner may hold."
  @spec usable?(Wardrik.t(), Principal.t(), map(), {String.t(), atom()}) :: boolean()
  def usable?(_wardrik, %Principal{id: id}, %{owner: id}, _use), do: true

  def usable?(wardrik, principal, %{owner: owner}, {action, resource}) do
    scope = %{Wardrik.as(wardrik.name, principal) | wardrik: wardrik}
    Authorizer.authorize(scope, action: action, resource: {resource, owner}) == :ok
  end

  defp entries(wardrik, prefix) do
    store = store(wardrik)
    for {_path, record, _vsn} <- Wardrik.Store.entries(store, prefix), do: record
  end

  defp path(kind, owner, name), do: kind <> "/" <> reference(owner, name)

  defp store(wardrik),
    do: Wardrik.Store.scope(wardrik.store, @scope, format: Wardrik.Store.Format.Term)
end
