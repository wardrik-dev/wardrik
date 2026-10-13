defmodule WardrikDaemon.Secrets do
  @moduledoc """
  The deployment's secrets the daemon reads from the vault where its
  environment does not set them: `${NAME}` in `config.yaml`, which
  `WardrikDaemon.Config.read/2` reads through `named/1`, and model providers'
  keys.

  A webhook trigger's `secret` is read by `for_agent/2` instead, as each
  request arrives, in the order a tool's credential is: the agent's user's,
  its org's, then the deployment's, and the environment last, so each org
  keeps its own.

  The environment comes first, and the deployment's secret `NAME` in the vault
  second, for every one of them. `wardrik vault put NAME` seals one.

  A provider's key is `ReqLLM.Keys.env_var_name/1` of it, such as
  `ANTHROPIC_API_KEY`. A tool's key is a credential it names, which the
  vault resolves for each call; see `WardrikVault`.

  ReqLLM reads its application config ahead of the environment, so a key from
  the vault is put there only where the environment does not set the name. It
  goes into application config and never into the environment, which the
  commands MCP servers run could inherit.

  `apply/0` gives every such key the vault holds as the daemon starts.
  `vault put` and `vault rm` of one place it, or clear it, with `place/2` on
  every node that runs a daemon, handing it the key: a node's copy of the
  store may not have the write yet.
  """

  @typedoc "Where a key is put: a key of ReqLLM's application config."
  @type setting() :: {:req_llm, atom()}

  @doc "The deployment's secret `name` in the vault, or `nil` where it holds none it can read."
  @spec named(String.t()) :: String.t() | nil
  def named(name), do: secret(name, nil)

  @doc """
  The secret `name` for the agent `id`: what the vault holds for its user,
  else its org, else the deployment, else the environment; `nil` where none
  does.
  """
  @spec for_agent(String.t(), Wardrik.AgentID.t()) :: String.t() | nil
  def for_agent(name, %Wardrik.AgentID{org: org, user: user}) do
    owners = if user, do: [{org, user}, org, nil], else: [org, nil]
    Enum.find_value(owners, &secret(name, &1)) || System.get_env(name)
  end

  defp secret(name, owner) do
    case WardrikVault.lookup(name, owner) do
      {:ok, :secret, secret} -> secret
      _grant_absent_or_unreadable -> nil
    end
  end

  @doc "The variables a key is read from, each with the settings it is put under."
  @spec variables() :: %{String.t() => [setting()]}
  def variables do
    Enum.group_by(
      ReqLLM.Providers.list(),
      &ReqLLM.Keys.env_var_name/1,
      &{:req_llm, ReqLLM.Keys.config_key(&1)}
    )
  end

  @doc "Whether `name` is a key `place/2` places, a model provider's."
  @spec key?(String.t()) :: boolean()
  def key?(name), do: Map.has_key?(variables(), name)

  @doc "Places every key the vault holds, as `place/2` does each."
  @spec apply() :: :ok
  def apply do
    variables = variables()

    for name <- WardrikVault.names(nil),
        Map.has_key?(variables, name),
        do: settle(name, named(name), variables[name])

    :ok
  end

  @doc """
  Places `secret` where the key `name` is read, unless the environment sets
  it; `nil` clears it there. A name that is no provider's key is placed
  nowhere.
  """
  @spec place(String.t(), String.t() | nil) :: :ok
  def place(name, secret) do
    case Map.fetch(variables(), name) do
      {:ok, settings} -> settle(name, secret, settings)
      :error -> :ok
    end
  end

  defp settle(name, secret, settings) do
    if System.get_env(name) == nil, do: Enum.each(settings, &put(&1, secret))
    :ok
  end

  defp put({:req_llm, key}, secret), do: Application.put_env(:req_llm, key, secret)
end
