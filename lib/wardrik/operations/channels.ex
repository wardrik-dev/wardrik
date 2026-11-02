defmodule Wardrik.Operations.Channels do
  @moduledoc false

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
  Returns the channel `name` as `{module, opts}`, or `:error`. See `options/3`.
  """
  @spec fetch(atom(), String.t()) :: {:ok, {module(), keyword()}} | :error
  def fetch(instance, name) do
    wardrik = Wardrik.Instance.fetch!(instance)

    with {:ok, {module, opts}} <- Map.fetch(wardrik.channels, name),
         do: {:ok, {module, options(wardrik, name, opts)}}
  end

  @doc """
  Returns the channel's options with secrets read, plus `:server`, `:wardrik`, `:events`,
  `:vault`, `:channel` and `:store`.
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

  defp vault(%Wardrik{vault_keys: []}), do: nil
  defp vault(wardrik), do: Wardrik.vault(wardrik)

  defp headers(headers),
    do: Map.new(headers, fn {name, value} -> {String.downcase(name), value} end)
end
