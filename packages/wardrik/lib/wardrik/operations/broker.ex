defmodule Wardrik.Operations.Broker do
  @moduledoc false

  alias Wardrik.Error
  alias Wardrik.Scope

  @doc "Takes a signed change from the deployment's credential broker."
  @spec deliver(Scope.t(), map()) :: {:ok, nil} | {:error, Error.t()}
  def deliver(%Scope{wardrik: instance}, %{"body" => body, "headers" => headers}) do
    request = %{
      body: body,
      headers: Map.new(headers, fn {header, value} -> {String.downcase(header), value} end)
    }

    wardrik = Wardrik.Instance.fetch!(instance)

    case Wardrik.Credentials.Broker.deliver(wardrik, request, DateTime.utc_now()) do
      :ok -> {:ok, nil}
      {:error, _reason} -> {:error, Error.new(:not_found, "There's no credential broker here.")}
    end
  end
end
