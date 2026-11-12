defmodule WardrikWeb.SettingPage do
  @moduledoc false

  # The dashboard's settings pages, in navigation order. Each is on when the router's `:settings`
  # names a module for its key.

  @enforce_keys [:key, :path, :label, :lead, :behaviour]
  defstruct [:key, :path, :label, :lead, :behaviour, noun: nil]

  @type t() :: %__MODULE__{
          key: atom(),
          path: String.t(),
          label: String.t(),
          lead: String.t(),
          behaviour: module(),
          noun: String.t() | nil
        }

  @pages [
    %{
      key: :servers,
      path: "servers",
      label: "MCP servers",
      noun: "server",
      behaviour: WardrikWeb.Settings,
      lead:
        "MCP servers that agents can use. To give an agent a server's tools, add name/* to the agent's tools."
    },
    %{
      key: :secrets,
      path: "secrets",
      label: "Secrets",
      noun: "secret",
      behaviour: WardrikWeb.Settings,
      lead:
        "Secrets, like API keys, that agents and MCP servers use. Their values are never shown."
    },
    %{
      key: :notify_targets,
      path: "notify",
      label: "Notify targets",
      noun: "notify target",
      behaviour: WardrikWeb.Settings,
      lead:
        "Webhooks that get a notice when an agent parks, fails or finishes. An agent sends to a target when its definition sets notify to the target's name."
    },
    %{
      key: :oauth_apps,
      path: "oauth",
      label: "OAuth apps",
      noun: "OAuth app",
      behaviour: WardrikWeb.Settings,
      lead:
        "OAuth apps that people use to connect their accounts, such as Google or GitHub. Agents then call the service as the person who connected."
    },
    %{
      key: :connections,
      path: "connections",
      label: "Connections",
      behaviour: WardrikWeb.Connections,
      lead:
        "Your accounts on other services, such as Google or GitHub. When you connect an account, agents can call that service as you."
    }
  ]

  @doc "Returns every settings page."
  @spec all() :: [t()]
  def all, do: Enum.map(@pages, &struct!(__MODULE__, &1))

  @doc "Returns the settings page for `key`."
  @spec fetch!(atom()) :: t()
  def fetch!(key),
    do: Enum.find(all(), &(&1.key == key)) || raise(ArgumentError, "no page #{key}")

  @doc "Returns the keys the router's `:settings` takes."
  @spec keys() :: [atom()]
  def keys, do: Enum.map(@pages, & &1.key)
end
