defmodule Wardrik.Tokens do
  @moduledoc """
  The tokens a deployment's callers present, each carrying a
  `Wardrik.Grant`: making one, listing them, and revoking one.

  A host names the module once, as `Wardrik`'s `:tokens`, and the operations
  on tokens ask it:

      children = [{Wardrik, tokens: WardrikHTTP.Tokens}]

  | Operation | Callback |
  | --- | --- |
  | `Wardrik.Operations.CreateToken` | `create/3` |
  | `Wardrik.Operations.ListTokens` | `list/0` |
  | `Wardrik.Operations.RevokeToken` | `revoke/1` |

  Without a module each operation is `:unsupported`. They act on the
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
              {:ok, secret :: String.t(), token()} | {:error, String.t()}

  @doc "Every token, oldest first."
  @callback list() :: [token()]

  @doc "Stops the token `id` working: `{:error, :not_found}` where there is none."
  @callback revoke(id :: String.t()) :: :ok | {:error, :not_found}

  @module {__MODULE__, :module}

  @doc """
  Keeps `module`, or `nil` for none, as the host's. Answers `:ignore`, so
  `Wardrik` runs it as a child that starts nothing.
  """
  @spec configure(module() | nil) :: :ignore
  def configure(module) when is_atom(module) do
    :persistent_term.put(@module, module)
    :ignore
  end

  @doc "The host's module, or an `:unsupported` error where none was named."
  @spec module() :: {:ok, module()} | {:error, Error.t()}
  def module do
    case :persistent_term.get(@module, nil) do
      nil -> {:error, Error.new(:unsupported, "This server makes no tokens.")}
      module -> {:ok, module}
    end
  end
end
