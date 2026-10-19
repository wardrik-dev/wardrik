defmodule WardrikDaemon.Secrets do
  @moduledoc """
  The deployment's secrets the daemon reads from the vault where its
  environment does not set them: `${NAME}` in `config.yaml`, which
  `WardrikDaemon.Config.load/1` reads through `named/2`, each from the vault
  it is handed first.

  A webhook trigger's `secret` is read by `for_agent/3` instead, as each
  request arrives, as a tool's credential is: the one the agent's owner
  holds, or a name the vault shares with every agent, and nothing else.

  A model provider's key, such as `ANTHROPIC_API_KEY`, is the deployment's
  secret of that name, which each model call reads where the environment
  does not set it; see `Wardrik.LLM.Key`. `wardrik vault put NAME` seals one.
  """

  @doc "The deployment's secret `name` in `vault`, or `nil` where it holds none it can read."
  @spec named(WardrikVault.t(), String.t()) :: String.t() | nil
  def named(vault, name), do: secret(vault, name, Wardrik.Resource.deployment())

  @doc """
  The secret `name` for the agent `id`, as `WardrikVault.held_by/3` finds
  it: what `vault` holds for its owner, else the deployment's secret or the
  node's environment variable where the vault shares the name; `nil` where
  neither does.
  """
  @spec for_agent(WardrikVault.t(), String.t(), Wardrik.AgentID.t()) :: String.t() | nil
  def for_agent(vault, name, %Wardrik.AgentID{} = id) do
    owner = Wardrik.Resource.owner(Wardrik.AgentID.resource(id))

    case WardrikVault.held_by(vault, name, owner) do
      :own -> secret(vault, name, owner)
      :shared -> named(vault, name) || System.get_env(name)
      :none -> nil
    end
  end

  @doc "Whether `name` is a model provider's key, such as `ANTHROPIC_API_KEY`."
  @spec key?(String.t()) :: boolean()
  def key?(name), do: name in Enum.map(ReqLLM.Providers.list(), &ReqLLM.Keys.env_var_name/1)

  defp secret(vault, name, owner) do
    case WardrikVault.lookup(vault, name, owner) do
      {:ok, :secret, secret} -> secret
      _grant_absent_or_unreadable -> nil
    end
  end
end
