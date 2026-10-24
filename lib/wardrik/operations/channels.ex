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

  @doc "Returns the options a channel's callbacks take: its own, with the instance and its name."
  @spec options(Wardrik.t(), String.t(), keyword()) :: keyword()
  def options(wardrik, name, opts), do: opts ++ [wardrik: wardrik.name, channel: name]

  defp headers(headers),
    do: Map.new(headers, fn {name, value} -> {String.downcase(name), value} end)
end
