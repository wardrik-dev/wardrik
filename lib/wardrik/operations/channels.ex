defmodule Wardrik.Operations.Channels do
  @moduledoc "Passes chat apps' requests to Wardrik's channels."

  alias Wardrik.Error
  alias Wardrik.Scope

  @doc "Passes a chat app's request to the channel it names. Returns the channel's response."
  @spec deliver(Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def deliver(%Scope{wardrik: wardrik}, %{"channel" => name} = input) do
    case Map.fetch(wardrik.channels, name) do
      {:ok, {module, opts}} ->
        request = %{path: input["path"], body: input["body"], headers: headers(input["headers"])}
        response = module.request(request, options(wardrik, name, opts))

        {:ok,
         %{"status" => response.status, "headers" => response.headers, "body" => response.body}}

      :error ->
        {:error, Error.new(:not_found, "There's no channel #{name}.")}
    end
  end

  @doc """
  Returns the channel `name` as `{module, opts}`, or `:error` if there's none.

  `opts` are what the channel's callbacks take. See `options/3`.
  """
  @spec fetch(atom(), String.t()) :: {:ok, {module(), keyword()}} | :error
  def fetch(instance, name) do
    wardrik = Wardrik.Instance.fetch!(instance)

    with {:ok, {module, opts}} <- Map.fetch(wardrik.channels, name),
         do: {:ok, {module, options(wardrik, name, opts)}}
  end

  @doc """
  Returns the options a channel's callbacks take.

  They're the channel's own options, with each `{:secret, name}` replaced by the deployment's
  secret, plus:

    * `:server` - `Wardrik`, which runs its operations.
    * `:wardrik` - the instance's name.
    * `:events` - the event log.
    * `:vault` - the vault, or `nil` without `:keys`.
    * `:channel` - the channel's name.
    * `:store` - the store.
  """
  @spec options(Wardrik.t(), String.t(), keyword()) :: keyword()
  def options(wardrik, name, opts),
    do:
      Wardrik.Sealed.resolved(wardrik, "the channel #{name}", opts) ++
        [
          server: Wardrik,
          wardrik: wardrik.name,
          events: Wardrik.events(wardrik),
          vault: vault(wardrik),
          channel: name,
          store: wardrik.store
        ]

  defp vault(%Wardrik{keys: []}), do: nil
  defp vault(wardrik), do: Wardrik.vault(wardrik)

  defp headers(headers),
    do: Map.new(headers, fn {name, value} -> {String.downcase(name), value} end)
end
