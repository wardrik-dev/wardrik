defprotocol Wardrik.Tokens do
  @moduledoc """
  The tokens a deployment's callers present, each carrying a
  `Wardrik.Grant`: making one, listing them, and revoking one.

  A host names the value once, as the `:tokens` of its `Wardrik.Host`, and
  the operations on tokens ask it. The value carries what its
  implementation needs, such as the store it keeps them in:

      Wardrik.Host.new(tokens: %WardrikHTTP.Tokens{store: store})

  | Operation | Function |
  | --- | --- |
  | `Wardrik.Operations.CreateToken` | `create/3` |
  | `Wardrik.Operations.ListTokens` | `list/1` |
  | `Wardrik.Operations.RevokeToken` | `revoke/2` |

  A host that makes none has `Wardrik.Tokens.None`, whose functions answer
  `:unsupported`, and so does each operation. They act on the
  deployment, so only a caller whose grant reaches every agent takes them;
  see `Wardrik.Deployment`.
  """

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
  Makes a token named `name` carrying the `:grant` `opts` name, acting for
  `:for`, a `Wardrik.Principal`, or for itself where `nil`: its secret,
  answered this once, and the token.
  """
  @spec create(t(), String.t(), grant: Grant.t(), for: Principal.t() | nil) ::
          {:ok, secret :: String.t(), token()} | {:error, String.t()} | :unsupported
  def create(tokens, name, opts)

  @doc "Every token, oldest first."
  @spec list(t()) :: [token()] | :unsupported
  def list(tokens)

  @doc "Stops the token `id` working: `{:error, :not_found}` where there is none."
  @spec revoke(t(), String.t()) :: :ok | {:error, :not_found} | :unsupported
  def revoke(tokens, id)
end
