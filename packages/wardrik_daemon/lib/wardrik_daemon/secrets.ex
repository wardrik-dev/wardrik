defmodule WardrikDaemon.Secrets do
  @moduledoc """
  The deployment's secrets the daemon reads from the vault where its
  environment does not set them: `${NAME}` in `config.yaml`, which
  `WardrikDaemon.Config.load/1` reads through `named/2`, each from the vault
  it is handed first.

  A webhook trigger's `secret` is read by `for_agent/3` instead, as each
  request arrives, in the order a tool's credential is: the agent's user's,
  its org's, then the deployment's, and the environment last, so each org
  keeps its own.

  A model provider's key, such as `ANTHROPIC_API_KEY`, is the deployment's
  secret of that name, which each model call reads where the environment
  does not set it; see `Wardrik.LLM.Key`. `wardrik vault put NAME` seals one.
  """

  @doc "The deployment's secret `name` in `vault`, or `nil` where it holds none it can read."
  @spec named(WardrikVault.t(), String.t()) :: String.t() | nil
  def named(vault, name), do: secret(vault, name, nil)

  @doc """
  The secret `name` for the agent `id`: what `vault` holds for its user,
  else its org, else the deployment, else the environment; `nil` where none
  does.
  """
  @spec for_agent(WardrikVault.t(), String.t(), Wardrik.AgentID.t()) :: String.t() | nil
  def for_agent(vault, name, %Wardrik.AgentID{org: org, user: user}) do
    owners = if user, do: [{org, user}, org, nil], else: [org, nil]
    Enum.find_value(owners, &secret(vault, name, &1)) || System.get_env(name)
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
