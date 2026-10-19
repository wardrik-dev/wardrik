defprotocol Wardrik.Connections do
  @moduledoc """
  The accounts people and orgs connect, such as a GitHub sign-in: which
  ones a deployment offers, who holds each, and connecting or forgetting
  one before any agent asks for it.

  A host names the value once, as the `:connections` of its
  `Wardrik.Host`, and the functions of `Wardrik` on connections ask it,
  whichever surface they came from. The value carries what its implementation needs,
  such as the vault it keeps accounts in:

      Wardrik.Host.new(connections: WardrikOAuth.connections(oauth, vault))

  | `Wardrik` | Function |
  | --- | --- |
  | `connections_list/2` | `list/2` |
  | `connections_connect/3` | `connect/4` |
  | `connections_disconnect/3` | `disconnect/3` |

  A host that offers none has `Wardrik.Connections.None`, whose functions
  answer `:unsupported`, and so does each of those.

  An owner is a namespace, as `Wardrik.Resource` names one: a person in
  their org, `acme/@jon`, or an org, `acme`. A connection is connected for
  them where they hold it, which is what a call of an agent they own would
  use, as `Wardrik.Credential` resolves it. Nothing falls back from a
  person to their org.
  """

  @typedoc "A person in their org, or an org, as the namespace `Wardrik.Resource` names."
  @type owner() :: Wardrik.Resource.t()

  @doc "The connections the deployment offers `owner`, and whether they hold each; never a value."
  @spec list(t(), owner()) :: [Wardrik.Connections.Connection.t()] | :unsupported
  def list(connections, owner)

  @doc """
  Connects `provider` for `owner`, as `:by` asked, a `Wardrik.Principal` or
  `nil`: `{:ok, :held}` where they
  hold it already, else where they authorize it, as `Wardrik.Credential`'s
  links are. `{:error, :not_found}` is for a provider the deployment does
  not offer.
  """
  @spec connect(t(), String.t(), owner(), by: Wardrik.Principal.t() | nil) ::
          {:ok, :held} | {:ok, Wardrik.Call.Ask.link()} | {:error, term()} | :unsupported
  def connect(connections, provider, owner, opts)

  @doc "Forgets `owner`'s `provider`: `{:error, :not_found}` where they hold none."
  @spec disconnect(t(), String.t(), owner()) :: :ok | {:error, term()} | :unsupported
  def disconnect(connections, provider, owner)
end
