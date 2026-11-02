defmodule WardrikDaemon.CLI.Context do
  @moduledoc """
  What every command runs with: directories, environment, orgs, terminal, and `--json`.
  """

  alias WardrikDaemon.CLI.Terminal
  alias WardrikDaemon.Client
  alias WardrikDaemon.CLIToken
  alias WardrikDaemon.Dirs

  @enforce_keys [:dirs, :env, :org, :terminal, :program]
  defstruct @enforce_keys ++ [orgs: [], json?: false]

  @type t() :: %__MODULE__{
          dirs: Dirs.t(),
          env: %{String.t() => String.t()},
          org: String.t(),
          orgs: [String.t()],
          terminal: Terminal.t(),
          program: String.t(),
          json?: boolean()
        }

  @doc "Returns the context for the environment `env`."
  @spec new(%{String.t() => String.t()}) :: t()
  def new(env) do
    dirs = Dirs.new(env)
    config = config(dirs)

    %__MODULE__{
      dirs: dirs,
      env: env,
      org: org(config),
      orgs: orgs(config),
      terminal: Terminal.new(env),
      program: Map.get(env, "WARDRIK_PROGRAM", "wardrik")
    }
  end

  @doc "Writes `answer` as JSON if the command was given `--json`. Otherwise calls `shown` with it."
  @spec show(t(), term(), (term() -> term())) :: :ok
  def show(%__MODULE__{json?: true}, answer, _shown), do: IO.puts(JSON.encode!(answer))

  def show(_cx, answer, shown) do
    shown.(answer)
    :ok
  end

  @doc "Writes `said` once a change is done, or the answer as JSON if the command was given `--json`."
  @spec done(t(), term(), Owl.Data.t()) :: :ok
  def done(cx, answer, said),
    do: show(cx, answer || %{"ok" => true}, fn _answer -> puts(cx, said) end)

  @doc "Writes `data` to the command's terminal."
  @spec puts(t(), Owl.Data.t()) :: :ok
  def puts(cx, data), do: Terminal.puts(cx.terminal, data)

  @doc "Runs the operation `id` on the daemon. Returns its answer, or the reason it failed."
  @spec call(t(), String.t(), map()) :: {:ok, map() | nil} | {:error, String.t()}
  def call(cx, id, input) do
    with {:ok, client} <- client(cx), do: called(Client.run(client, id, input))
  end

  @doc "Returns an operation's answer, with its error as a message."
  @spec called({:ok, term()} | Client.error()) :: {:ok, term()} | {:error, String.t()}
  def called({:ok, answer}), do: {:ok, answer}
  def called({:error, _type, message}), do: {:error, message}

  @doc "Returns the client that reaches the daemon: from `WARDRIK_URL` and `WARDRIK_TOKEN` if both are set, or from `cli_token`."
  @spec client(t()) :: {:ok, Client.t()} | {:error, String.t()}
  def client(%__MODULE__{env: %{"WARDRIK_URL" => url, "WARDRIK_TOKEN" => secret}}),
    do: {:ok, %Client{url: url, secret: secret}}

  def client(cx) do
    case CLIToken.read(Dirs.data_home(cx.dirs, "cli_token")) do
      {:ok, %{url: url, secret: secret}} ->
        {:ok, %Client{url: url, secret: secret}}

      :error ->
        {:error,
         "The daemon hasn't started here yet, so there's no token to reach it with. Start it with `#{cx.program} start`."}
    end
  end

  @doc "Returns the ID of agent `name`: `triage` in the deployment's org, or `growth/triage`."
  @spec agent(t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def agent(cx, name) do
    {org, name} =
      case String.split(name, "/", parts: 2) do
        [org, name] -> {org, name}
        [name] -> {cx.org, name}
      end

    case call(cx, "agents.find", %{"owner" => org, "name" => name}) do
      {:ok, %{"agents" => [%{"id" => id}]}} -> {:ok, id}
      {:ok, %{"agents" => []}} -> {:error, "There's no agent #{name} in #{org}."}
      {:error, why} -> {:error, why}
    end
  end

  @doc "Returns the IDs of the agents `names` names, as `agent/2` finds each."
  @spec agents(t(), [String.t()]) :: {:ok, [String.t()]} | {:error, String.t()}
  def agents(cx, names) do
    found = Enum.map(names, &agent(cx, &1))

    case Enum.find(found, &match?({:error, _why}, &1)) do
      nil -> {:ok, for({:ok, id} <- found, do: id)}
      error -> error
    end
  end

  @doc "Returns each agent's name by ID: `name` in the deployment's org, `org/name` in another."
  @spec names(t()) :: %{String.t() => map()}
  def names(cx) do
    for org <- [cx.org | cx.orgs],
        {:ok, %{"agents" => agents}} <- [call(cx, "agents.find", %{"owner" => org})],
        agent <- agents,
        into: %{},
        do: {agent["id"], Map.put(agent, "shown", shown(cx, agent))}
  end

  defp shown(%{org: org}, %{"org" => org, "name" => name}), do: name
  defp shown(_cx, %{"org" => org, "name" => name}), do: org <> "/" <> name

  @doc "Puts the `--conversation` of `flags` in `input`, if it's set."
  @spec conversation(map(), map()) :: map()
  def conversation(input, flags), do: put(input, "conversation", flags[:conversation])

  @doc "Returns the owner `flags` name: `--org`, or `--user` in the deployment's org, or else `default`."
  @spec owner(t(), map(), String.t()) :: String.t()
  def owner(cx, flags, default \\ "deployment")
  def owner(_cx, %{org: org}, _default), do: org
  def owner(cx, %{user: user}, _default), do: "#{cx.org}/@#{String.trim_leading(user, "@")}"
  def owner(_cx, _flags, default), do: default

  @doc "Puts `value` in `map` under `key`, unless it's `nil`."
  @spec put(map(), String.t(), term()) :: map()
  def put(map, _key, nil), do: map
  def put(map, key, value), do: Map.put(map, key, value)

  defp config(dirs) do
    case YamlElixir.read_from_file(Dirs.config(dirs, "config.yaml")) do
      {:ok, %{} = config} -> config
      _none -> %{}
    end
  end

  defp org(%{"org" => org}) when is_binary(org), do: org
  defp org(_config), do: "default"

  defp orgs(%{"orgs" => %{} = orgs}),
    do: orgs |> Map.keys() |> Enum.reject(&(&1 == "*")) |> Enum.sort()

  defp orgs(_config), do: []
end
