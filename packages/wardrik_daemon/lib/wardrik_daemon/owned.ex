defmodule WardrikDaemon.Owned do
  @moduledoc false

  alias WardrikDaemon.Owners

  @doc "Returns the path `owner`'s `name` of `kind` is kept at."
  @spec path(String.t(), String.t(), String.t()) :: String.t()
  def path(kind, owner, name), do: prefix(kind, owner) <> name

  @doc "Returns what `owner` added of `kind`."
  @spec own(Wardrik.Store.t(), String.t(), String.t()) :: [term()]
  def own(store, kind, owner),
    do: for({_path, item, _vsn} <- Wardrik.Store.entries(store, prefix(kind, owner)), do: item)

  @doc """
  Returns what `owner`'s agents reach of `kind`, nearest first. See `WardrikDaemon.Owners.chain/1`.
  """
  @spec along(Wardrik.Store.t(), String.t(), String.t()) :: [term()]
  def along(store, kind, owner), do: Enum.flat_map(Owners.chain(owner), &own(store, kind, &1))

  @doc "Returns every owner's `kind`."
  @spec all(Wardrik.Store.t(), String.t()) :: [term()]
  def all(store, kind),
    do: for({_path, item, _vsn} <- Wardrik.Store.entries(store, kind <> "/"), do: item)

  @doc "Returns `listed`, the nearest of each `\"name\"` alone."
  @spec nearest([map()]) :: [map()]
  def nearest(listed), do: Enum.uniq_by(listed, & &1["name"])

  defp prefix(kind, owner), do: kind <> "/" <> URI.encode_www_form(owner) <> "/"
end
