defprotocol Wardrik.Tokens do
  @moduledoc """
  The tokens a deployment's callers present, each a `Wardrik.Token` kept
  as a `Wardrik.Tokens.Entry`: making one, listing them, and revoking one.

  A host names the value once, as the `:tokens` of its `Wardrik.Host`, and
  the functions of `Wardrik` on tokens ask it. The value carries what its
  implementation needs, such as the store it keeps them in:

      Wardrik.Host.new(tokens: %WardrikHTTP.Tokens{store: store})

  | `Wardrik` | Function |
  | --- | --- |
  | `tokens_create/4` | `create/3` |
  | `tokens_list/1` | `list/1` |
  | `tokens_revoke/2` | `revoke/2` |

  A host that makes none has `Wardrik.Tokens.None`, whose functions answer
  `:unsupported`, and so does each of those. They act on the deployment,
  so only a token allowing them on every agent takes them.
  """

  alias Wardrik.Tokens.Entry

  @doc """
  Keeps the `:token` `opts` name, under the name `name`: the entry, with
  the secret that presents it, answered this once.
  """
  @spec create(t(), String.t(), token: Wardrik.Token.t()) ::
          {:ok, Entry.t()} | {:error, String.t()} | :unsupported
  def create(tokens, name, opts)

  @doc "Every token, oldest first, none with its secret."
  @spec list(t()) :: [Entry.t()] | :unsupported
  def list(tokens)

  @doc "Stops the token `id` working: `{:error, :not_found}` where there is none."
  @spec revoke(t(), String.t()) :: :ok | {:error, :not_found} | :unsupported
  def revoke(tokens, id)
end
