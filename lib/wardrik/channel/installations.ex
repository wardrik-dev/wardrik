defmodule Wardrik.Channel.Installations do
  @moduledoc """
  A behaviour for storing the workspaces a channel is added to, each with its token.

    * A channel takes one as `installations: {module, opts}`.
    * Without it, a channel given `token:` serves only that token's workspace.
    * Tokens are secrets. Store them as you store your others.
  """

  alias Wardrik.Channel.Installation
  alias Wardrik.Channel.Installations.Request

  @doc "Fetches the channel's installation in the request's `workspace`."
  @callback fetch(Request.t(), opts :: term()) :: {:ok, Installation.t()} | :error

  @doc "Returns the channel's installations whose `owner` is the request's."
  @callback owned(Request.t(), opts :: term()) :: [Installation.t()]

  @doc "Stores `installation`, replacing any with the same channel and workspace."
  @callback put(Installation.t(), opts :: term()) :: :ok | {:error, String.t()}

  @doc "Deletes the channel's installation in the request's `workspace`, if there is one."
  @callback delete(Request.t(), opts :: term()) :: :ok
end
