defmodule Wardrik.Tokens do
  @moduledoc """
  The tokens a deployment's callers present, each carrying a
  `Wardrik.Grant`: making one, listing them, and revoking one.

  A host names the module once, as the `:tokens` of its `Wardrik.Host`, and
  the operations on tokens ask it:

      Wardrik.Host.new(tokens: WardrikHTTP.Tokens)

  | Operation | Callback |
  | --- | --- |
  | `Wardrik.Operations.CreateToken` | `create/3` |
  | `Wardrik.Operations.ListTokens` | `list/0` |
  | `Wardrik.Operations.RevokeToken` | `revoke/1` |

  A host that makes none has `Wardrik.Tokens.None`, whose callbacks answer
  `:unsupported`, and so does each operation. They act on the
  deployment, so only a caller whose grant reaches every agent takes them;
  see `Wardrik.Deployment`.
  """

  alias Wardrik.Error
  alias Wardrik.Grant
  alias Wardrik.Principal

  @typedoc "A token as the host keeps it; never its secret."
  @type token() :: %{
          required(:id) => String.t(),
          required(:name) => String.t(),
          required(:grant) => Grant.t(),
          required(:principal) => Principal.t() | nil,
          required(:created_at) => DateTime.t(),
          optional(atom()) => term()
        }

  @doc """
  Makes a token named `name` carrying `grant`, acting for `for`, or for
  itself where `nil`: its secret, answered this once, and the token.
  """
  @callback create(name :: String.t(), grant :: Grant.t(), for :: Principal.t() | nil) ::
              {:ok, secret :: String.t(), token()} | {:error, String.t()} | :unsupported

  @doc "Every token, oldest first."
  @callback list() :: [token()] | :unsupported

  @doc "Stops the token `id` working: `{:error, :not_found}` where there is none."
  @callback revoke(id :: String.t()) :: :ok | {:error, :not_found} | :unsupported

  @doc "The error each operation answers where the host makes no tokens."
  @spec unsupported() :: Error.t()
  def unsupported, do: Error.new(:unsupported, "This server makes no tokens.")
end
