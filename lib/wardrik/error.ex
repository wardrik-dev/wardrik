defmodule Wardrik.Error do
  @moduledoc """
  An operation's failure, as the protocol's `error`.

      %Wardrik.Error{type: :not_found, message: "No agent agt_01JF8X5RQ2."}

  `type` is one of `t:type/0`. `message` is for people to read.
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

  @doc "Returns an error of `type` with `message`."
  @spec new(type(), String.t()) :: t()
  def new(type, message), do: %__MODULE__{type: type, message: message}

  @doc """
  Returns `error` as the protocol's JSON error body.

      Wardrik.Error.json(Wardrik.Error.new(:not_found, "No agent agt_01JF8X5RQ2."))
      #=> %{"error" => %{"type" => "not_found", "message" => "No agent agt_01JF8X5RQ2."}}
  """
  @spec json(t()) :: map()
  def json(%__MODULE__{type: type, message: message}),
    do: %{"error" => %{"type" => Atom.to_string(type), "message" => message}}
end
