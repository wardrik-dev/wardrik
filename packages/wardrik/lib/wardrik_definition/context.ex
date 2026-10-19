defmodule WardrikDefinition.Context do
  @moduledoc """
  What a host lets its definitions name beyond the tools, sources and
  runtimes its `Wardrik.Host` holds, and what it gives every agent, for
  `Wardrik.Definition` to read a definition against.

      %WardrikDefinition.Context{
        org: "acme",
        orgs: ["acme", "globex"],
        held: ["base"],
        policies: %{"base" => base, "careful" => careful},
        defaults: %{"idle_timeout" => 900},
        shares: [runbooks_share]
      }

    * `org` - the org of an agent file that names none
    * `orgs` - the orgs an agent may be in, or `:any`, the default
    * `held` - the policies the owner's agents are held to ahead of their
      own, each a name in `policies` or a `WardrikPolicy` with a name of its
      own; the budget of each is the org's, which every agent of the org
      spends from together
    * `policies` - the policies a definition may name, by name
    * `defaults` - what an agent is given where nothing else says: the
      `idle_timeout` and `retries` of one whose definition sets none,
      applied as it is read, and the definition of one started with none
    * `shares` - the trees the deployment lets agents beyond their owners
      mount, as `WardrikWorkspace.Share`s
    * `triggers` - the trigger sources and webhook verifiers a definition's
      triggers may name, as a `WardrikTrigger.Offered`; this package's own by
      default
    * `names` - how the messages a definition that does not read gives name
      the host, its settings and its policies
  """

  defstruct org: "default",
            orgs: :any,
            held: [],
            policies: %{},
            defaults: %{},
            shares: [],
            triggers: %WardrikTrigger.Offered{},
            names: %{host: "the host", config: "the host", policies: "the host's policies"}

  @type t() :: %__MODULE__{
          org: String.t(),
          orgs: :any | [String.t()],
          held: [String.t() | WardrikPolicy.t()],
          policies: %{String.t() => WardrikPolicy.t()},
          defaults: %{String.t() => term()},
          shares: [WardrikWorkspace.Share.t()],
          triggers: WardrikTrigger.Offered.t(),
          names: %{host: String.t(), config: String.t(), policies: String.t()}
        }
end
