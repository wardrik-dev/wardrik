defprotocol Wardrik.Connections do
  @moduledoc """
  The accounts people and orgs connect, such as a GitHub sign-in: which
  ones a deployment offers, who holds each, and connecting or forgetting
  one before any agent asks for it.

  A host names the value once, as the `:connections` of its
  `Wardrik.Host`, and the operations on connections ask it, whichever
  surface they came from. The value carries what its implementation needs,
  such as the vault it keeps accounts in:

      Wardrik.Host.new(connections: WardrikOAuth.connections(oauth, vault))

  | Operation | Function |
  | --- | --- |
  | `Wardrik.Operations.ReadConnections` | `list/2` |
  | `Wardrik.Operations.Connect` | `connect/4` |
  | `Wardrik.Operations.Disconnect` | `disconnect/3` |

  A host that offers none has `Wardrik.Connections.None`, whose functions
  answer `:unsupported`, and so does each operation.

  An owner is a person in their org, `{org, user}`, or an org, as
  `Wardrik.Credential` resolves credentials for them: a person's call takes
  their own, then their org's, then the deployment's. The operations name
  an owner by the `Wardrik.AgentID.Prefix` of the agents it owns, so a
  grant reaches a person's connections where it reaches their agents;
  `Wardrik.Connections.Owner` finds it.
  """

  @typedoc "A person in their org, or an org."
  @type owner() :: {String.t(), String.t()} | String.t()

  @typedoc "Who holds a connection for an owner: them, their org, the deployment, or nobody."
  @type held_by() :: :person | :org | :deployment | nil

  @typedoc "A connection the deployment offers, and who holds it."
  @type connection() :: %{provider: String.t(), held_by: held_by()}

  @doc "The connections the deployment offers `owner`, and who holds each; never a value."
  @spec list(t(), owner()) :: [connection()] | :unsupported
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
