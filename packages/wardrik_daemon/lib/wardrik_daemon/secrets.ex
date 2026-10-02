defmodule WardrikDaemon.Secrets do
  @moduledoc """
  The deployment's secrets the daemon reads from the vault where its
  environment does not set them: `${NAME}` in `config.yaml`, which
  `WardrikDaemon.Config.read/2` reads through `named/1`, model providers'
  keys, and the keys of the tools `:keys` names.

  The environment comes first, and the deployment's secret `NAME` in the vault
  second, for every one of them. `wardrik vault put NAME` seals one.

  A provider's key is `ReqLLM.Keys.env_var_name/1` of it, such as
  `ANTHROPIC_API_KEY`. A tool's is whatever `:keys` maps to the setting it
  reads its key from, as a release that reads the tool's key from the
  environment names it:

      config :wardrik_daemon, WardrikDaemon.Secrets,
        keys: %{"SEARCH_API_KEY" => {:my_app, MyApp.Search, :api_key}}

  ReqLLM reads its application config ahead of the environment, so a key from
  the vault is put there only where the environment does not set the name. It
  goes into application config and never into the environment, which the
  commands MCP servers run could inherit.

  `apply/0` gives every such key the vault holds as the daemon starts.
  `vault put` and `vault rm` of one place it, or clear it, with `place/2` on
  every node that runs a daemon, handing it the key: a node's copy of the
  store may not have the write yet.
  """

  @typedoc "Where a key is put: an application's key, or a key within an application's package settings."
  @type setting() :: {atom(), atom()} | {atom(), module(), atom()}

  @doc "The deployment's secret `name` in the vault, or `nil` where it holds none it can read."
  @spec named(String.t()) :: String.t() | nil
  def named(name) do
    case WardrikVault.lookup(name, nil) do
      {:ok, :secret, secret} -> secret
      _grant_absent_or_unreadable -> nil
    end
  end

  @doc "The variables a key is read from, each with the settings it is put under."
  @spec variables() :: %{String.t() => [setting()]}
  def variables do
    providers =
      Enum.group_by(
        ReqLLM.Providers.list(),
        &ReqLLM.Keys.env_var_name/1,
        &{:req_llm, ReqLLM.Keys.config_key(&1)}
      )

    tools =
      Map.new(
        Application.get_env(:wardrik_daemon, __MODULE__, [])[:keys] || %{},
        fn {name, setting} -> {name, [setting]} end
      )

    Map.merge(providers, tools, fn _name, mine, theirs -> mine ++ theirs end)
  end

  @doc "Whether `name` is a key `place/2` places, a provider's or a tool's."
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
  it; `nil` clears it there. A name that is no provider's or tool's key is
  placed nowhere.
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

  defp put({app, key}, secret), do: Application.put_env(app, key, secret)

  defp put({app, package, key}, secret),
    do:
      Application.put_env(
        app,
        package,
        Keyword.put(Application.get_env(app, package, []), key, secret)
      )
end
