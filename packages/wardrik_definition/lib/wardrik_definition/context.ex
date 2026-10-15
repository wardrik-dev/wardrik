defmodule WardrikDefinition.Context do
  @moduledoc """
  What a host lets its definitions name, and what it gives every agent, for
  `WardrikDefinition` to read a definition against.

      %WardrikDefinition.Context{
        org: "acme",
        orgs: ["acme", "globex"],
        tools: [WardrikBrave.WebSearch],
        servers: [github: [orgs: :all], books: [orgs: ["acme"]]],
        mcp: WardrikMCP,
        sources: [workers: WardrikHTTP.Workers, self: Wardrik.Catalog.Self, agents: Wardrik.Catalog.Agents],
        channels: [slack: :all],
        targets: [ops: {WardrikNotify.Webhook, url: "https://ops.example.com", orgs: :all}],
        policies: %{"careful" => policy},
        defaults: %{"idle_timeout" => 900},
        seams: [ledger: %Wardrik.Ledger.Store{}],
        config: [tool_prices: %{"web_search" => 0.005}],
        shares: [runbooks_share]
      }

    * `org` - the org of an agent file that names none
    * `orgs` - the orgs an agent may be in, or `:any`, the default
    * `tools` - the tools the host ships, each a module implementing
      `Wardrik.Tool`, named in a definition by its tool's name
    * `servers` - the MCP servers, by name, each with the `orgs` it serves,
      `:all` or a list, which a definition names as `server/*`
    * `mcp` - the tool source the servers' tools come through, such as
      `WardrikMCP`; with none, a definition names no server
    * `sources` - the tool sources a definition names as `name/*`, each a
      module implementing `Wardrik.Tool`'s `tools/1`, handed the agent's ID,
      such as `workers: WardrikHTTP.Workers` for the tool workers' tools,
      `self: Wardrik.Catalog.Self` for the agent's operations on itself, and
      `agents: Wardrik.Catalog.Agents` for those on the agents of its org
    * `channels` - the channels an agent may be offered in, by name, each
      with the orgs it serves
    * `targets` - the notify targets, as `WardrikNotify` takes them: each a
      name with its module and options, `orgs` among them
    * `policies` - the policies a definition may name, by name
    * `defaults` - definition keys every agent takes where its own
      definition says none: `idle_timeout`
    * `seams` - `Wardrik.Agent.Spec` options every agent gets, such as
      `ledger`
    * `config` - `Wardrik.LLM.Config` options every agent gets, such as
      `tool_prices`
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
            tools: [],
            servers: [],
            mcp: nil,
            sources: [],
            channels: [],
            targets: [],
            policies: %{},
            defaults: %{},
            seams: [],
            config: [],
            shares: [],
            triggers: %WardrikTrigger.Offered{},
            names: %{host: "the host", config: "the host", policies: "the host's policies"}

  @type orgs() :: :all | [String.t()]

  @type t() :: %__MODULE__{
          org: String.t(),
          orgs: :any | [String.t()],
          tools: [module()],
          servers: [{atom(), keyword()}],
          mcp: module() | nil,
          sources: [{atom(), module()}],
          channels: [{atom(), orgs()}],
          targets: WardrikNotify.targets(),
          policies: %{String.t() => WardrikPolicy.t()},
          defaults: %{String.t() => term()},
          seams: keyword(),
          config: keyword(),
          shares: [WardrikWorkspace.Share.t()],
          triggers: WardrikTrigger.Offered.t(),
          names: %{host: String.t(), config: String.t(), policies: String.t()}
        }
end
