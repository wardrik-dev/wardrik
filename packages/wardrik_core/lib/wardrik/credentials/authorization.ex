# reach:disable-for-this-file behaviour_candidate -- park reasons share Wardrik.Format's callbacks
defmodule Wardrik.Credentials.Authorization do
  @moduledoc """
  A sign-in a person must finish before a call can run.

  A call waits on one when `Wardrik.Credentials.fetch/2` has no token yet. Show the person its
  `url`, then resume the turn once they've signed in.
  """

  @behaviour Wardrik.Format

  alias WardrikCore.Stored.Message

  @enforce_keys [:url, :credential]
  defstruct [:url, :credential, :principal]

  @type t() :: %__MODULE__{
          url: String.t(),
          credential: String.t(),
          principal: Wardrik.Principal.t() | nil
        }

  @impl Wardrik.Format
  def type, do: "authorization"

  @impl Wardrik.Format
  def version, do: 1

  @impl Wardrik.Format
  def dump(%__MODULE__{} = authorization) do
    %{
      "url" => authorization.url,
      "credential" => authorization.credential,
      "principal" => authorization.principal && Message.principal(authorization.principal)
    }
  end

  @impl Wardrik.Format
  def load(1, %{"url" => url, "credential" => credential, "principal" => principal}) do
    principal = principal && Message.read_principal(principal)
    {:ok, %__MODULE__{url: url, credential: credential, principal: principal}}
  end
end
