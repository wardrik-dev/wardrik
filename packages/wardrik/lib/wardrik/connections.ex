defmodule Wardrik.Connections do
  @moduledoc """
  The accounts people and orgs connect, such as a GitHub sign-in: which
  ones a deployment offers, who holds each, and connecting or forgetting
  one before any agent asks for it.

  A host names the module once, as `Wardrik`'s `:connections`, and the
  operations on connections ask it, whichever surface they came from:

      children = [{Wardrik, connections: WardrikOAuth.Connections}]

  | Operation | Callback |
  | --- | --- |
  | `Wardrik.Operations.ReadConnections` | `list/1` |
  | `Wardrik.Operations.Connect` | `connect/3` |
  | `Wardrik.Operations.Disconnect` | `disconnect/2` |

  Without a module each operation is `:unsupported`.

  An owner is a person in their org, `{org, user}`, or an org, as
  `Wardrik.Credential` resolves credentials for them: a person's call takes
  their own, then their org's, then the deployment's. The operations name
  an owner by the `Wardrik.AgentID.Prefix` of the agents it owns, so a
  grant reaches a person's connections where it reaches their agents.
  """

  alias Wardrik.AgentID.Prefix
  alias Wardrik.Caller
  alias Wardrik.Error
  alias Wardrik.Principal

  @typedoc "A person in their org, or an org."
  @type owner() :: {String.t(), String.t()} | String.t()

  @typedoc "Who holds a connection for an owner: them, their org, the deployment, or nobody."
  @type held_by() :: :person | :org | :deployment | nil

  @typedoc "A connection the deployment offers, and who holds it."
  @type connection() :: %{provider: String.t(), held_by: held_by()}

  @doc "The connections the deployment offers `owner`, and who holds each; never a value."
  @callback list(owner()) :: [connection()]

  @doc """
  Connects `provider` for `owner`, as `by` asked: `{:ok, :held}` where they
  hold it already, else where they authorize it, as `Wardrik.Credential`'s
  links are. `{:error, :not_found}` is for a provider the deployment does
  not offer.
  """
  @callback connect(provider :: String.t(), owner(), by :: Principal.t() | nil) ::
              {:ok, :held} | {:ok, Wardrik.Call.Ask.link()} | {:error, term()}

  @doc "Forgets `owner`'s `provider`: `{:error, :not_found}` where they hold none."
  @callback disconnect(provider :: String.t(), owner()) :: :ok | {:error, term()}

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
      nil -> {:error, Error.new(:unsupported, "This server offers no connections.")}
      module -> {:ok, module}
    end
  end

  @doc """
  The prefix of the owner `caller` asks about: `:person` for their own,
  within their org, or `:org` for their org's. A caller's org is the one
  its grant reaches, and its person the user its grant is for, else the
  user it acts as.
  """
  @spec owner(Caller.t(), :person | :org) :: {:ok, Prefix.t()} | {:error, Error.t()}
  def owner(%Caller{grant: grant} = caller, whose) do
    case {Prefix.org(grant.scope), whose} do
      {nil, _whose} ->
        {:error,
         Error.new(
           :invalid,
           "This caller reaches every org, and connections belong to one; use a token for an org"
         )}

      {org, :org} ->
        {:ok, Prefix.new!(org: org)}

      {org, :person} ->
        case Prefix.user(grant.scope) || user(caller.principal) do
          nil ->
            {:error,
             Error.new(
               :invalid,
               "This caller acts for no person; ask for the org's connections with owner=org"
             )}

          user ->
            {:ok, Prefix.new!(org: org, user: user)}
        end
    end
  end

  @doc """
  The operation `module` asks for, about the owner `caller` asks about, as
  `owner/2` finds it, with `fields` beside.
  """
  @spec request(module(), Caller.t(), :person | :org, keyword()) ::
          {:ok, struct()} | {:error, Error.t()}
  def request(module, caller, whose, fields \\ []) do
    with {:ok, owner} <- owner(caller, whose),
         do: {:ok, struct!(module, [owner: owner] ++ fields)}
  end

  defp user(nil), do: nil
  defp user(principal), do: if(Principal.type(principal) == :user, do: Principal.id(principal))

  @doc "The owner whose agents are under `prefix`."
  @spec owner_of(Prefix.t()) :: owner()
  def owner_of(prefix) do
    case {Prefix.org(prefix), Prefix.user(prefix)} do
      {org, nil} when is_binary(org) -> org
      {org, user} -> {org, user}
    end
  end

  @doc "The prefix of the agents `owner` owns: `nil`, the deployment's, is every agent."
  @spec prefix(owner() | nil) :: Prefix.t()
  def prefix(nil), do: Prefix.all()
  def prefix({org, user}), do: Prefix.new!(org: org, user: user)
  def prefix(org) when is_binary(org), do: Prefix.new!(org: org)
end
