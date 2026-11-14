# reach:disable-for-this-file behaviour_candidate -- park reasons share WardrikCore.Format's callbacks
defmodule WardrikCore.Authorization do
  @moduledoc """
  A sign-in a person must finish before a call can run.

  A call waits on one when `WardrikCore.Credentials.fetch/2` has no token yet. Show the person its
  `url`, then resume the turn once they've signed in.
  """

  @behaviour WardrikCore.Format

  alias WardrikCore.Stored.Message

  @enforce_keys [:url, :credential]
  defstruct [:url, :credential, :principal]

  @type t() :: %__MODULE__{
          url: String.t(),
          credential: String.t(),
          principal: WardrikCore.Principal.t() | nil
        }

  @impl WardrikCore.Format
  def type, do: "authorization"

  @impl WardrikCore.Format
  def version, do: 1

  @impl WardrikCore.Format
  def dump(%__MODULE__{} = authorization) do
    %{
      "url" => authorization.url,
      "credential" => authorization.credential,
      "principal" => authorization.principal && Message.principal(authorization.principal)
    }
  end

  @impl WardrikCore.Format
  def load(1, %{"url" => url, "credential" => credential, "principal" => principal}) do
    principal = principal && Message.read_principal(principal)
    {:ok, %__MODULE__{url: url, credential: credential, principal: principal}}
  end
end
