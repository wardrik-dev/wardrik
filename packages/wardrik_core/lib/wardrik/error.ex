defmodule Wardrik.Error do
  @moduledoc """
  Why an operation did not happen: its `type`, which a surface answers in its
  own terms, and a `message` a person reads.

  | Type | Means | HTTP |
  | --- | --- | --- |
  | `:unauthorized` | the caller's token has expired | `401` |
  | `:not_found` | no such thing, or none the caller reaches | `404` |
  | `:forbidden` | the caller reaches it, and may not do that to it | `403` |
  | `:invalid` | what was asked for does not read | `400` |
  | `:conflict` | it cannot happen as things stand | `409` |
  | `:gap` | events asked for have been dropped; `details` holds `oldest` | `410` |
  | `:unsupported` | the host does not offer it | `501` |
  | `:unavailable` | it could not happen now | `503` |
  | `:failed` | the run it waited on ended without answering; `details` holds `error` | — |
  | `:cancelled` | the run it waited on was stopped | — |
  | `:timeout` | the run it waited on had not ended in time, and carries on | — |

  `details` holds whatever else a surface may answer beside the message.

  The last three come only from `Wardrik.agent_await/3`, which the HTTP API
  does not offer.

  It is an exception, so a function that answers it in `{:error, error}` has
  a bang variant that raises it.
  """

  defexception [:type, :message, details: %{}]

  @type type() ::
          :unauthorized
          | :not_found
          | :forbidden
          | :invalid
          | :conflict
          | :gap
          | :unsupported
          | :unavailable
          | :failed
          | :cancelled
          | :timeout

  @type t() :: %__MODULE__{
          __exception__: true,
          type: type(),
          message: String.t(),
          details: map()
        }

  @doc "An error of `type`, saying `message`, with `details` beside it."
  @spec new(type(), String.t(), map()) :: t()
  def new(type, message, details \\ %{}) when is_atom(type) and is_binary(message),
    do: %__MODULE__{type: type, message: message, details: details}

  @doc "The error for the agent `id`, where none runs, or none the caller reaches."
  @spec no_agent(Wardrik.AgentAddress.t()) :: t()
  def no_agent(id), do: new(:not_found, "No agent runs under #{id}.")

  @doc "The error for events asked for before `oldest`, the first a log still keeps."
  @spec gap(pos_integer()) :: t()
  def gap(oldest) do
    new(
      :gap,
      "Events before #{oldest} have been dropped; read on after #{oldest - 1}.",
      %{"oldest" => oldest}
    )
  end
end
