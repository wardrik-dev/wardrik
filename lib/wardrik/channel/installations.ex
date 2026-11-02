defmodule Wardrik.Channel.Installations do
  @moduledoc """
  A behaviour for storing the workspaces a channel is added to, each with its token.

  Pass an implementation to a channel as `installations: {module, opts}`. Each callback takes a
  `Wardrik.Channel.Installations.Request`, or the installation to keep, then `opts`. The host then keeps
  workspaces with its own records. A channel given `token:` instead serves only the workspace that
  token reaches.

  Tokens are secrets. Store them as you store your others.
  """

  alias Wardrik.Channel.Installation
  alias Wardrik.Channel.Installations.Request

  @doc "Fetches the channel's installation in the request's `workspace`."
  @callback fetch(Request.t(), opts :: term()) :: {:ok, Installation.t()} | :error

  @doc "Returns the channel's installations whose owner is the request's `owner`, exactly."
  @callback owned(Request.t(), opts :: term()) :: [Installation.t()]

  @doc "Stores `installation`, replacing any with the same channel and workspace."
  @callback put(Installation.t(), opts :: term()) :: :ok | {:error, String.t()}

  @doc "Deletes the channel's installation in the request's `workspace`. Returns `:ok` if there is none."
  @callback delete(Request.t(), opts :: term()) :: :ok
end
