defmodule Wardrik.Resolved do
  @moduledoc """
  What an agent gets, as `c:Wardrik.Resolver.resolve/2` returns it.

      %Wardrik.Resolved{
        principal: %WardrikCore.Principal{id: "user_42"},
        policy: [deny: ["shell/*"]],
        defaults: %{"model" => "anthropic:claude-haiku-4-5"},
        servers: %{"github" => "acme:github"},
        notify: %{
          "ops" => "ops",
          "alerts" => {Wardrik.Notify.Webhook, url: "https://hooks.acme.test", secret: secret}
        },
        channels: %{"slack" => "T0123"},
        workspaces: %{"agt_runbooks" => :read}
      }

  An agent reaches nothing that isn't named here.

  ## Fields

    * `:principal` - who it works for. Its credentials are theirs. `nil` gives it none.
    * `:policy` - a policy, its rules, or a list. Checked between Wardrik's and the agent's own.
    * `:policies` - named policies its definition may use, beside Wardrik's.
    * `:defaults` - what its definition gets where it says nothing.
    * `:middleware` - run after Wardrik's, as `{module, opts}`.
    * `:servers` - MCP servers by the name its `tools` use, to the `Wardrik.MCP` name.
    * `:notify` - targets by the name its `notify` uses, to a `:notify` target or `{module, opts}`.
    * `:channels` - the workspace each channel posts its notices in, by channel name.
    * `:workspaces` - other agents' workspaces it may mount, `:read` or `:write`.
  """

  defstruct principal: nil,
            policy: nil,
            policies: %{},
            defaults: %{},
            middleware: [],
            servers: %{},
            notify: %{},
            channels: %{},
            workspaces: %{}

  @type t() :: %__MODULE__{
          principal: WardrikCore.Principal.t() | nil,
          policy: Wardrik.Policy.t() | keyword() | map() | [Wardrik.Policy.t() | map()] | nil,
          policies: %{optional(String.t()) => Wardrik.Policy.t() | keyword() | map()},
          defaults: map(),
          middleware: [WardrikCore.Context.entry()],
          servers: %{optional(String.t()) => String.t()},
          notify: notify(),
          channels: %{optional(String.t()) => String.t()},
          workspaces: %{optional(String.t()) => :read | :write}
        }

  @typedoc "Notify targets by the name an agent's definition uses."
  @type notify() :: %{optional(String.t()) => notify_target()}

  @typedoc "The name of a target in Wardrik's `:notify`, or a target of your app's own."
  @type notify_target() :: String.t() | {module(), keyword()}
end
