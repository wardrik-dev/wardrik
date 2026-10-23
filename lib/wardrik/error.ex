defmodule Wardrik.Error do
  @moduledoc """
  Why an operation failed, as the protocol's `error`: its `type`, like `:not_found`, and a message a
  person reads.
  """

  defexception [:type, :message]

  @type type() ::
          :invalid_request
          | :unauthorized
          | :forbidden
          | :not_found
          | :conflict
          | :not_supported
          | :unavailable
          | :internal

  @type t() :: %__MODULE__{type: type(), message: String.t()}

  @doc "Returns an error of `type`, saying `message`."
  @spec new(type(), String.t()) :: t()
  def new(type, message), do: %__MODULE__{type: type, message: message}

  @doc "Returns `error` as the protocol's `error` body."
  @spec json(t()) :: map()
  def json(%__MODULE__{type: type, message: message}),
    do: %{"error" => %{"type" => Atom.to_string(type), "message" => message}}
end
