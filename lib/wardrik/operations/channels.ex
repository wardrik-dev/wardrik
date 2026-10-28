defmodule Wardrik.Operations.Channels do
  @moduledoc "Hands what chat apps send to the channels the Wardrik runs."

  alias Wardrik.Error
  alias Wardrik.Scope

  @doc "Hands a chat app's request to the channel it names, and answers what the channel says."
  @spec deliver(Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def deliver(%Scope{wardrik: wardrik}, %{"channel" => name} = input) do
    case Map.fetch(wardrik.channels, name) do
      {:ok, {module, opts}} ->
        request = %{path: input["path"], body: input["body"], headers: headers(input["headers"])}
        response = module.request(options(wardrik, name, opts), request)

        {:ok,
         %{"status" => response.status, "headers" => response.headers, "body" => response.body}}

      :error ->
        {:error, Error.new(:not_found, "There's no channel #{name}.")}
    end
  end

  @doc """
  Returns the channel the Wardrik `instance` runs as `name`: its module, and the options its
  callbacks take. Returns `:error` where it runs none by that name.
  """
  @spec fetch(atom(), String.t()) :: {:ok, {module(), keyword()}} | :error
  def fetch(instance, name) do
    wardrik = Wardrik.Instance.fetch!(instance)

    with {:ok, {module, opts}} <- Map.fetch(wardrik.channels, name),
         do: {:ok, {module, options(wardrik, name, opts)}}
  end

  @doc """
  Returns the options a channel's callbacks take: its own, each `{:secret, name}` read from the
  deployment's secrets, with the server that runs its operations, the instance, its events and
  vault, its name and the store.
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
