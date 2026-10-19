defmodule Wardrik.LLM.Error do
  @moduledoc """
  Why a model call failed, as its client reports it: the HTTP status the
  provider answered with, `nil` where none did, as for a connection that
  dropped; how many seconds it asked to be left before the next try, where
  it said; and what happened.

  `Wardrik.LLM.Retry.Backoff` decides whether to ask again from `status`
  and `retry_after` alone.
  """

  defexception [:status, :retry_after, message: "the model call failed"]

  @type t() :: %__MODULE__{
          status: non_neg_integer() | nil,
          retry_after: non_neg_integer() | nil,
          message: String.t()
        }
end
