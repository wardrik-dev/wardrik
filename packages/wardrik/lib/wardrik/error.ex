defmodule Wardrik.Error do
  @moduledoc """
  Why an operation did not happen: its `type`, which a surface answers in its
  own terms, and a `message` a person reads.

  | Type | Means | HTTP |
  | --- | --- | --- |
  | `:not_found` | no such thing, or none the caller reaches | `404` |
  | `:forbidden` | the caller reaches it, and may not do that to it | `403` |
  | `:invalid` | what was asked for does not read | `400` |
  | `:conflict` | it cannot happen as things stand | `409` |
  | `:gap` | events asked for have been dropped; `details` holds `oldest` | `410` |
  | `:unsupported` | the host does not offer it | `501` |
  | `:unavailable` | it could not happen now | `503` |

  `details` holds whatever else a surface may answer beside the message.
  """

  @enforce_keys [:type, :message]
  defstruct [:type, :message, details: %{}]

  @type type() ::
          :not_found | :forbidden | :invalid | :conflict | :gap | :unsupported | :unavailable

  @type t() :: %__MODULE__{type: type(), message: String.t(), details: map()}

  @doc "An error of `type`, saying `message`, with `details` beside it."
  @spec new(type(), String.t(), map()) :: t()
  def new(type, message, details \\ %{}) when is_atom(type) and is_binary(message),
    do: %__MODULE__{type: type, message: message, details: details}
end
