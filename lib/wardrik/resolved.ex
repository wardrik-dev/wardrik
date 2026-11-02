defmodule Wardrik.Resolved do
  @moduledoc """
  What an agent gets, as `c:Wardrik.Resolver.resolve/3` returns it.

      %Wardrik.Resolved{
        principal: %WardrikCore.Principal{id: "user_42"},
        policy: [deny: ["shell/*"]],
        defaults: %{"model" => "anthropic:claude-haiku-4-5"},
        servers: %{"github" => "acme:github"},
        notify: %{"ops" => "ops"}
      }

  An agent gets nothing it isn't given here: a name its definition uses that isn't in `:servers`
  or `:notify` reaches nothing, whatever else is started under that name.

  ## Fields

    * `:principal` - who the agent acts for. Its credentials and keys are this principal's.
      `nil` gives it none.
    * `:policy` - the `WardrikPolicy` the agent is held to, or its rules, or a list of them.
      Checked after the deployment's policy and before the agent's own.
    * `:policies` - named policies its definition may use, alongside the deployment's. A name the
      deployment already uses is refused.
    * `:defaults` - what its definition gets where it says nothing. Overrides the deployment's
      `:defaults`.
    * `:middleware` - middleware it runs after the deployment's, as `{module, opts}`.
    * `:servers` - the MCP servers its `tools` reach, by the name they use, as the server's
      `WardrikMCP` name. `servers/*` and `*` reach every one.
    * `:notify` - the notify targets its `notify` reaches, by the name it uses, as the name of a
      target in `:notify`, or the `Wardrik.Notify.key/2` of one added at runtime.
  """

  defstruct principal: nil,
            policy: nil,
            policies: %{},
            defaults: %{},
            middleware: [],
            servers: %{},
            notify: %{}

  @type t() :: %__MODULE__{
          principal: WardrikCore.Principal.t() | nil,
          policy: WardrikPolicy.t() | keyword() | map() | [WardrikPolicy.t() | map()] | nil,
          policies: %{optional(String.t()) => WardrikPolicy.t() | keyword() | map()},
          defaults: map(),
          middleware: [WardrikCore.Context.entry()],
          servers: %{optional(String.t()) => String.t()},
          notify: %{optional(String.t()) => String.t()}
        }
end
