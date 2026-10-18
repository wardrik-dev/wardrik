defprotocol Wardrik.Servers do
  @moduledoc """
  The MCP servers orgs and people add for their own agents, as they run:
  which ones an owner has, adding one, and removing one.

  A host names the value once, as the `:servers` of its `Wardrik.Host`, and
  the functions of `Wardrik` on servers ask it, whichever surface they came
  from:

      Wardrik.Host.new(servers: %WardrikMCP.Servers{store: store, oauth: oauth, vault: vault})

  | `Wardrik` | Function |
  | --- | --- |
  | `servers_list/2` | `list/2` |
  | `servers_add/3` | `add/3` |
  | `servers_remove/3` | `remove/3` |

  An owner is the `Wardrik.AgentID.Prefix` of the agents a server serves: an
  org's own, `acme/`, or a person's, `acme/@jon/`. A server one owner adds
  is named by a `Wardrik.Servers.Key` and serves that owner's agents alone.

  A host that offers none has `Wardrik.Servers.None`, whose functions answer
  `:unsupported`, and so does each of those.
  """

  alias Wardrik.AgentID.Prefix

  @doc "The servers `owner` added."
  @spec list(t(), Prefix.t()) :: [Wardrik.Servers.Server.t()] | :unsupported
  def list(servers, owner)

  @doc """
  Adds the server `:name` for `owner`, from `:fields` as a request gave
  them, as `:by` asked: `{:ok, :connected}` where its agents can call it
  now, or the link where someone signs in to it first.
  """
  @spec add(t(), Prefix.t(),
          name: String.t(),
          fields: map(),
          by: Wardrik.Principal.t() | nil
        ) ::
          {:ok, :connected}
          | {:ok, Wardrik.Call.Ask.link()}
          | {:error, Wardrik.Error.t()}
          | :unsupported
  def add(servers, owner, opts)

  @doc "Removes `owner`'s server `:name`, and stops every connection to it."
  @spec remove(t(), Prefix.t(), name: String.t(), by: Wardrik.Principal.t() | nil) ::
          :ok | {:error, Wardrik.Error.t()} | :unsupported
  def remove(servers, owner, opts)
end
