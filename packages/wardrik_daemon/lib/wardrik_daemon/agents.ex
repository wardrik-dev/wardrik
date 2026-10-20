defmodule WardrikDaemon.Agents do
  @moduledoc """
  The agents `agents/` in the config directory declares, one per `*.md`
  file, under the policies `policies/` declares, one per `*.yaml` or `*.yml`
  file. See `WardrikDaemon.AgentFile` and `WardrikDaemon.PolicyFile` for
  what each says.

  It is the `WardrikDefinition.Contexts` of the daemon's definitions,
  `definitions/1`: every definition, a file's or one the HTTP API sent, is
  read under the context `config.yaml` gives, with the policies the store
  keeps, so every node reads the same ones, holding its agent to those
  `config.yaml` holds the agent's org to. `wardrik reload`, as
  `Wardrik.deployment_reload/2` does, reads the files on the node it is
  asked of, in one pass, through `reload/1`: the policies first, kept in the
  store, then each agent file's `Wardrik.Definition`. So every node of a
  deployment keeps `agents/` and `policies/` alike, as a release does. The
  daemon reads them so as it starts.

  An agent a file declares starts as anything asks it; one awake takes what
  its file says now as the files are read, and keeps its conversation. A
  file that does not read is reported by `files/1`, and by `wardrik status`,
  and leaves what it declared as it was. An agent naming a policy that does
  not read does not read either. A definition a file declared that no file
  declares any more is retired: its agent stops, its triggers are cleared
  and its definition forgotten, and it keeps its conversation, so a file
  that declares it again brings it back as it was. `wardrik agent rm`
  removes it for good. An agent the HTTP API defined is read again under the
  policies read, and no file touches it.

  ## Defaults

  `config.yaml`'s `defaults` is what an agent is given where nothing else
  says: an agent nothing defines starts from them, and `write/2` writes a
  file from them, as `wardrik agent spawn --file` asks.
  """

  alias Wardrik.Agent.Spec
  alias Wardrik.AgentID
  alias Wardrik.Definition
  alias Wardrik.Definitions
  alias Wardrik.Resource
  alias WardrikDaemon.AgentFile
  alias WardrikDaemon.Config
  alias WardrikDaemon.PolicyFile

  @policies :policies

  @enforce_keys [:store, :config, :context]
  defstruct [:store, :config, :context, audit: Wardrik.Audit]

  @typedoc """
  The daemon's agents: definitions kept in `:store`, read under `:config`,
  and `:audit` the `Wardrik.Audit` log changes to them are recorded in.
  """
  @type t() :: %__MODULE__{
          store: WardrikStore.t(),
          config: WardrikDaemon.Config.t(),
          context: WardrikDefinition.Context.t(),
          audit: GenServer.name()
        }

  @typedoc "What one file reads into: the spec or policy it writes, or why it writes neither."
  @type file() :: {Path.t(), {:ok, Spec.t() | WardrikPolicy.t()} | {:error, String.t()}}

  @doc """
  The daemon's agents, kept in `:store` and read under `:config`. `:audit`
  is the log of `Wardrik.Host.audit/1`, `Wardrik.Audit` unless given.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    config = Keyword.fetch!(opts, :config)

    %__MODULE__{
      store: Keyword.fetch!(opts, :store),
      config: config,
      context: AgentFile.context(config),
      audit: Keyword.get(opts, :audit, Wardrik.Audit)
    }
  end

  @doc "The daemon's definitions: kept in its store, and read under it."
  @spec definitions(t()) :: Definitions.t()
  def definitions(%__MODULE__{} = agents), do: %Definitions{store: agents.store, contexts: agents}

  @doc "The agents of the daemon `host` runs: the contexts of its definitions."
  @spec of(Wardrik.Host.t()) :: t()
  def of(host), do: Wardrik.Host.definitions(host).contexts

  @doc """
  Reads the policy and agent files again, on this node: keeps the policies
  in the store, and answers each agent file with the definition it reads
  into under them on `:host`, and each file that does not read with why, as
  `Wardrik.Definitions.reload/2` asks.
  """
  @spec reload(t(), host: Wardrik.Host.t()) ::
          [{Path.t(), {:ok, Definition.t()} | {:error, String.t()}}]
  def reload(%__MODULE__{} = agents, opts) do
    {policy_files, agent_files} = read_files(agents.config, opts)
    policies = for {_path, {:ok, policy}} <- policy_files, into: %{}, do: {policy.name, policy}
    {:ok, _vsn} = WardrikStore.put(agents.store, @policies, "policies", policies)

    for({path, {:error, message}} <- policy_files, do: {path, {:error, message}}) ++
      for {path, read} <- agent_files, do: {path, definition_of(read)}
  end

  defp definition_of({:ok, definition, _spec}), do: {:ok, definition}
  defp definition_of(unread), do: unread

  @doc """
  The context the definitions of the agents `owner` owns are read under:
  what `config.yaml` says, with the policies the store keeps, as the last
  reading of `policies/` put them, holding them to those `config.yaml`
  holds their org to.
  """
  @spec context(t(), Resource.t()) :: WardrikDefinition.Context.t()
  def context(%__MODULE__{context: context, store: store, config: config}, owner) do
    policies = WardrikStore.get(store, @policies, "policies") || %{}
    held(%{context | policies: policies}, config, owner)
  end

  defp held(context, config, owner),
    do: %{context | held: Map.get(Config.held(config), Resource.org(owner), context.held)}

  @doc """
  What each file reads into now, on `:host`: the policies, then the agents,
  each in the order of their names.
  """
  @spec files(t(), host: Wardrik.Host.t()) :: [file()]
  def files(%__MODULE__{config: config}, opts) do
    {policy_files, agent_files} = read_files(config, opts)
    policy_files ++ for {path, read} <- agent_files, do: {path, spec_of(read)}
  end

  defp spec_of({:ok, _definition, spec}), do: {:ok, spec}
  defp spec_of(unread), do: unread

  @doc "The config directory the files are read from."
  @spec dir(t()) :: Path.t()
  def dir(%__MODULE__{config: config}), do: config.config_dir

  @doc "`config.yaml`'s `defaults`, as the file writes them, or none."
  @spec defaults(t()) :: map()
  def defaults(%__MODULE__{context: context}), do: context.defaults

  defp defaulted(agents, key, opts) do
    context = context(agents, Resource.owner(AgentID.resource(key)))

    with {:ok, definition} <-
           Definition.read(defaults(agents), id: key, source: :defaults, context: context),
         do: Definition.spec(definition, context: context, host: Keyword.fetch!(opts, :host))
  end

  @doc """
  Writes `agents/NAME.md`, or `agents/USER-NAME.md` for a user's agent, for
  the agent `key`, from `config.yaml`'s `defaults`, with its org and user
  where they are not the deployment's: the path it wrote. The file is
  written only once the defaults are known to make an agent under the key
  on `:host`, and never over one that is there, which is a conflict saying
  what it declares.
  """
  @spec write(t(), AgentID.t(), host: Wardrik.Host.t()) ::
          {:ok, Path.t()} | {:error, String.t()} | {:error, :conflict, String.t()}
  def write(%__MODULE__{} = agents, %AgentID{} = key, opts) do
    path = Path.join([dir(agents), "agents", file_name(key) <> ".md"])

    with :ok <- untaken(agents, path, opts),
         {:ok, _spec} <- created(agents, key, opts),
         :ok <- written(path, AgentFile.text(created_fields(agents, key))),
         do: {:ok, path}
  end

  defp untaken(agents, path, opts) do
    cond do
      not File.exists?(path) ->
        :ok

      other = Enum.find_value(WardrikDaemon.declared(files(agents, opts)), &declaring(&1, path)) ->
        {:error, :conflict, "#{shown(path)} is there already, and declares #{other}."}

      true ->
        {:error, :conflict,
         "#{shown(path)} is there already, and is kept as it is: wardrik reload reads it, " <>
           "and wardrik status says why where it does not."}
    end
  end

  defp declaring({key, {path, _spec}}, path), do: key
  defp declaring(_declared, _path), do: nil

  defp created(agents, key, opts) do
    case defaulted(agents, key, opts) do
      {:ok, spec} ->
        {:ok, spec}

      {:error, message} ->
        {:error, "config.yaml's defaults do not make an agent for #{key}: #{message}"}
    end
  end

  defp written(path, text) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, text, [:exclusive]) do
      :ok
    else
      {:error, reason} ->
        {:error, "#{shown(path)} could not be written: #{:file.format_error(reason)}"}
    end
  end

  # Each person's agent has a file of its own, as every person's assistant.
  defp file_name(%AgentID{user: nil, name: name}), do: name
  defp file_name(%AgentID{user: user, name: name}), do: "#{user}-#{name}"

  # The name where the file's is not the agent's, the org and user where
  # they are not the deployment's own, then the defaults every new agent is
  # written with.
  defp created_fields(agents, %AgentID{org: org, user: user, name: name} = key) do
    named = if file_name(key) != name, do: [{"name", name}], else: []

    named =
      if org != WardrikDaemon.Config.org(agents.config), do: named ++ [{"org", org}], else: named

    named = if user, do: named ++ [{"user", user}], else: named
    defaults = defaults(agents)

    named ++
      for key <- Definition.default_keys() -- ["idle_timeout"],
          Map.has_key?(defaults, key),
          do: {key, defaults[key]}
  end

  defp shown(path), do: Path.join("agents", Path.basename(path))

  @doc """
  What the policy and agent files under `config`'s directory read into on
  `:host`, without starting anything: each policy file's policy, and each
  agent file's definition with the spec it writes, or the message saying
  why it does not read.
  """
  @spec read_files(WardrikDaemon.Config.t(), host: Wardrik.Host.t()) ::
          {[{Path.t(), {:ok, WardrikPolicy.t()} | {:error, String.t()}}],
           [{Path.t(), {:ok, Definition.t(), Spec.t()} | {:error, String.t()}}]}
  def read_files(%WardrikDaemon.Config{config_dir: dir} = config, opts) do
    host = Keyword.fetch!(opts, :host)
    context = AgentFile.context(config)
    policy_files = dir |> read("policies/*.{yaml,yml}", &PolicyFile.read/1) |> once_each()
    policies = for {_path, {:ok, policy}} <- policy_files, into: %{}, do: {policy.name, policy}
    context = %{context | policies: policies}
    {policy_files, read(dir, "agents/*.md", &agent(context, config, host, &1))}
  end

  defp agent(context, config, host, path) do
    with {:ok, definition} <- AgentFile.parse(context, path) do
      context = held(context, config, Resource.owner(AgentID.resource(definition.id)))

      case Definition.spec(definition, context: context, host: host) do
        {:ok, spec} -> {:ok, definition, spec}
        {:error, message} -> {:error, "#{path}: #{message}"}
      end
    end
  end

  # careful.yaml and careful.yml would both be the policy careful; the first by
  # name is read, and the other reported.
  defp once_each(files) do
    {files, _seen} =
      Enum.map_reduce(files, %{}, fn
        {path, {:ok, %{name: name}}} = file, seen ->
          case Map.fetch(seen, name) do
            {:ok, first} ->
              {{path, {:error, "#{path}: policy #{name} is already #{Path.basename(first)}"}},
               seen}

            :error ->
              {file, Map.put(seen, name, path)}
          end

        file, seen ->
          {file, seen}
      end)

    files
  end

  defp read(dir, pattern, read) do
    dir
    |> Path.join(pattern)
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&{&1, contained(&1, read)})
  end

  defp contained(path, read) do
    read.(path)
  catch
    kind, reason ->
      {:error, "#{path}: " <> String.trim_leading(Exception.format_banner(kind, reason), "** ")}
  end
end

defimpl WardrikDefinition.Contexts, for: WardrikDaemon.Agents do
  defdelegate context(agents, owner), to: WardrikDaemon.Agents
  defdelegate reload(agents, opts), to: WardrikDaemon.Agents
end
