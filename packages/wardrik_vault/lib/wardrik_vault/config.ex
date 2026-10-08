defmodule WardrikVault.Config do
  @moduledoc """
  The settings `WardrikVault` was started with, which every seal, unseal and
  resolve reads.

  They come as the options of `WardrikVault.start_link/1`, which keeps them in
  `:persistent_term` under `{WardrikVault, :settings}`, and are the defaults,
  with no key, where the vault was never started.
  """

  @key {WardrikVault, :settings}
  @defaults [keys: [], grants: nil, environment: []]

  @doc "Every setting, as the vault was last started with them."
  @spec settings() :: keyword()
  def settings, do: :persistent_term.get(@key, @defaults)

  @doc false
  @spec put(keyword()) :: :ok
  def put(opts) do
    :persistent_term.put(@key, Keyword.validate!(opts, @defaults))
  end

  @doc "The base64-encoded keys, the first of which seals."
  @spec keys() :: [String.t()]
  def keys, do: settings() |> Keyword.fetch!(:keys) |> List.wrap()

  @doc "The `WardrikVault.Grants` module that renews and asks for grants, or `nil`."
  @spec grants() :: module() | nil
  def grants, do: Keyword.fetch!(settings(), :grants)

  @doc "The credential names read from the node's environment where the vault holds none."
  @spec environment() :: [String.t()]
  def environment, do: Keyword.fetch!(settings(), :environment)

  @doc "Whether a key is configured at all. `WardrikVault.ready?/0` says whether it is usable."
  @spec configured?() :: boolean()
  def configured?, do: keys() != []
end
