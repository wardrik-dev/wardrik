defmodule WardrikDefinition.Context do
  @moduledoc """
  What a host lets its definitions name beyond the tools, sources and
  runtimes its `Wardrik.Host` holds, and what it gives every agent, for
  `Wardrik.Definition` to read a definition against.

      %WardrikDefinition.Context{
        org: "acme",
        orgs: ["acme", "globex"],
        ceilings: %{"*" => "base", "acme" => "acme-ceiling"},
        servers: [github: [], books: [serves: [Wardrik.Resource.parse!("acme/*")]]],
        mcp: WardrikMCP,
        policies: %{"careful" => policy},
        defaults: %{"idle_timeout" => 900},
        shares: [runbooks_share]
      }

    * `org` - the org of an agent file that names none
    * `orgs` - the orgs an agent may be in, or `:any`, the default
    * `ceilings` - the policy each org's agents are held to ahead of their
      own, by org, `"*"` for every org's; each a name in `policies`
    * `servers` - the MCP servers, by name, each with the patterns it
      `serves`, every agent's unless it says, which a definition names as
      `server/*`. A definition names one its owner added, as the host's
      `Wardrik.Servers` lists them, as `server/*` too, and one its owner has
      not added yet offers nothing until they do. With
      `Wardrik.Servers.None`, a definition names only these
    * `mcp` - the tool source the servers' tools come through, such as
      `WardrikMCP`; with none, a definition names no server
    * `policies` - the policies a definition may name, by name
    * `defaults` - what an agent is given where nothing else says: the
      `idle_timeout` and `retries` of one whose definition sets none,
      applied as it is read, and the definition of one started with none
    * `shares` - the trees the deployment lets agents beyond their owners
      mount, as `WardrikWorkspace.Share`s
    * `triggers` - the trigger sources and webhook verifiers a definition's
      triggers may name, as `WardrikTrigger.Offered` finds them; this
      package's own by default
    * `names` - how the messages a definition that does not read gives name
      the host, its settings and its policies
  """

  defstruct org: "default",
            orgs: :any,
            ceilings: %{},
            servers: [],
            mcp: nil,
            policies: %{},
            defaults: %{},
            shares: [],
            triggers: %WardrikTrigger.Offered{},
            names: %{host: "the host", config: "the host", policies: "the host's policies"}

  @type t() :: %__MODULE__{
          org: String.t(),
          orgs: :any | [String.t()],
          ceilings: %{String.t() => String.t()},
          servers: [{atom(), keyword()}],
          mcp: module() | nil,
          policies: %{String.t() => WardrikPolicy.t()},
          defaults: %{String.t() => term()},
          shares: [WardrikWorkspace.Share.t()],
          triggers: WardrikTrigger.Offered.t(),
          names: %{host: String.t(), config: String.t(), policies: String.t()}
        }
end
