defmodule WardrikDaemon.AgentFile do
  @moduledoc """
  Reads an agent file, one in `agents/` under the config directory, into the
  `WardrikDaemon.Definition` it writes, and builds the `Wardrik.Agent.Spec`
  a definition writes. The [Agent files](agent-files.md) guide is every key
  a file takes, for whoever writes one.

  In Elixir, `tools` may also name a module implementing `Wardrik.Tool`, and
  `policy` a module implementing `Wardrik.Hook`. Rules a policy writes, named
  or in place, are a `WardrikPolicy`, which the agent carries as its hooks:
  they are written to the store with it and decide its calls on any node.

  The agent resolves the credentials its tools name from `WardrikVault` as
  its owner holds them, its user's or, for an agent that works for nobody,
  its org's, and the deployment's only where `vault.shared` names them; its
  owner connects an account through `WardrikOAuth` where a provider is named
  for one it does not hold. It records every tool call in
  `Wardrik.Ledger.Store`, so a turn lost part way through runs no call twice.

  ## Over HTTP

  `define/3` reads the body of `PUT /v1/agents/{id}` into a definition, for
  `WardrikHTTP` through `WardrikDaemon.Agents`, and `spec/3` builds its spec
  as it does a file's. `wardrik_protocol`'s `agent_definition.json` is its
  schema; the ID gives the agent's `name`, `org` and `user`.
  `put_trigger/4` and `delete_trigger/2` change one trigger in a definition
  kept, for the triggers routes. A definition's `tools` and `policy` name
  what the daemon ships or configures, never a module, and its `workspace`
  shares only the trees the scope of the token that sent it covers.

  `wardrik init` writes the front door's file; see `WardrikDaemon.CLI.Init`.
  """

  alias Wardrik.Agent.Spec
  alias Wardrik.AgentID
  alias WardrikDaemon.Config
  alias WardrikDaemon.Definition

  @shipped [WardrikBrave.WebSearch, WardrikResearch.Deep, WardrikLua.Run]

  @doc """
  What a definition may name here, as `WardrikDefinition` reads it: the orgs
  `config` declares, the tools the daemon ships, and the MCP servers,
  channels and notify targets `config` configures, and its `defaults`. A reading under the policies in
  `policies/` puts them, by name, as the context's `:policies`.
  """
  @spec context(Config.t()) :: WardrikDefinition.Context.t()
  def context(%Config{} = config) do
    %WardrikDefinition.Context{
      org: Config.org(config),
      orgs: Config.orgs(config),
      tools: @shipped,
      servers: config |> Config.section(WardrikMCP) |> Keyword.get(:servers, []),
      mcp: WardrikMCP,
      sources: [
        workers: WardrikHTTP.Workers,
        self: Wardrik.Catalog.Self,
        agents: Wardrik.Catalog.Agents
      ],
      channels: config |> Config.section(WardrikChannel) |> Keyword.get(:orgs, []),
      targets: config |> Config.section(WardrikNotify) |> Keyword.get(:targets, []),
      policies: %{},
      defaults: config |> Config.section(WardrikDaemon.Agents) |> Keyword.get(:defaults, %{}),
      seams: [ledger: %Wardrik.Ledger.Store{}],
      config: [
        tool_prices: config |> Config.section(__MODULE__) |> Keyword.get(:tool_prices, %{})
      ],
      shares: config |> Config.section(WardrikWorkspace) |> Keyword.get(:shared, []),
      triggers: config.triggers,
      names: %{host: "the daemon", config: "config.yaml", policies: "policies/"}
    }
  end

  @doc """
  An agent file with `fields` as its frontmatter, in the order given, and
  `prompt` after it, or a short one; see `WardrikDefinition.text/2`.
  """
  @spec text([{String.t(), term()}]) :: String.t()
  @spec text([{String.t(), term()}], String.t()) :: String.t()
  def text(fields), do: WardrikDefinition.text(fields)
  def text(fields, prompt), do: WardrikDefinition.text(fields, prompt)

  @doc """
  Reads the spec of the agent `path` declares, under `context`, whose
  `:policies` are the policies in `policies/`, by name.
  """
  @spec read(WardrikDefinition.Context.t(), Path.t()) :: {:ok, Spec.t()} | {:error, String.t()}
  def read(context, path) do
    with {:ok, definition} <- parse(context, path) do
      case spec(context, definition, definition.id) do
        {:ok, spec} -> {:ok, spec}
        {:error, message} -> {:error, "#{path}: #{message}"}
      end
    end
  end

  @doc """
  The `WardrikDaemon.Definition` the agent file `path` writes: its frontmatter,
  with its body as `instructions`, for the agent its `name`, `org` and `user`
  name. What its settings say is checked as `spec/3` builds a spec from it.
  """
  @spec parse(WardrikDefinition.Context.t(), Path.t()) ::
          {:ok, Definition.t()} | {:error, String.t()}
  def parse(context, path) do
    name = path |> Path.basename() |> Path.rootname()

    with {:ok, text} <- File.read(path),
         {:ok, id, fields} <- WardrikDefinition.parse(text, name, context) do
      {:ok, %Definition{id: id, fields: fields, source: {:file, Path.basename(path)}}}
    else
      {:error, reason} when is_atom(reason) -> {:error, "#{path}: #{:file.format_error(reason)}"}
      {:error, message} -> {:error, "#{path}: #{message}"}
    end
  end

  @doc """
  The `WardrikDaemon.Definition` the definition `:fields` sent to the HTTP API
  writes for the agent `id`, sent by a token holding `:grant`, or by none for
  `config.yaml`'s `defaults`. What its settings say is checked as `spec/3`
  builds a spec from it, the trees its workspace shares against the grant's
  scope among them.
  """
  @spec define(WardrikDefinition.Context.t(), AgentID.t(),
          fields: map(),
          grant: Wardrik.Grant.t() | nil
        ) :: {:ok, Definition.t()} | {:error, String.t()}
  def define(context, %AgentID{} = id, opts) do
    fields = Keyword.fetch!(opts, :fields)

    with :ok <- WardrikDefinition.accept(id, fields, context),
         do: {:ok, %Definition{id: id, fields: fields, source: {:api, opts[:grant]}}}
  end

  @doc """
  Reads the definition `:fields` sent to the HTTP API for the agent `id`
  into its spec, as `define/3` and `spec/3` do, sent by no token.
  """
  @spec definition(WardrikDefinition.Context.t(), AgentID.t(), fields: map()) ::
          {:ok, Spec.t()} | {:error, String.t()}
  def definition(context, %AgentID{} = id, opts) do
    with {:ok, definition} <- define(context, id, fields: Keyword.fetch!(opts, :fields)),
         do: spec(context, definition, id)
  end

  @doc """
  The spec `definition` writes for the agent `id`, under `context` as
  `read/2` takes it; see `WardrikDefinition.spec/5`.
  """
  @spec spec(WardrikDefinition.Context.t(), Definition.t(), AgentID.t()) ::
          {:ok, Spec.t()} | {:error, String.t()}
  def spec(context, %Definition{id: owner, fields: fields, source: source}, %AgentID{} = id),
    do: WardrikDefinition.spec(fields, owner, id, context, source)

  @doc """
  Where the notices of `definition`'s agent go, whether a file or the HTTP
  API wrote it, to the targets `config.yaml`'s `notify` keeps for its org;
  see `WardrikDefinition.route/3`.
  """
  @spec route(WardrikDefinition.Context.t(), Definition.t()) ::
          {:ok, WardrikNotify.Route.t()} | :none | {:error, String.t()}
  def route(context, %Definition{id: id, fields: fields}),
    do: WardrikDefinition.route(fields, id, context)

  @doc "The definition as the HTTP API writes one; see `WardrikDefinition.fields/1`."
  @spec fields(Definition.t()) :: map()
  def fields(%Definition{fields: fields}), do: WardrikDefinition.fields(fields)

  @doc "The triggers `definition` lists, read under `context`; see `WardrikDefinition.triggers/2`."
  @spec triggers(WardrikDefinition.Context.t(), Definition.t()) :: [WardrikTrigger.trigger()]
  def triggers(context, %Definition{fields: fields}),
    do: WardrikDefinition.triggers(fields, context)

  @doc """
  `definition` with the trigger `name` set to the `:trigger` `opts` name,
  read under `context`; see `WardrikDefinition.put_trigger/3`.
  """
  @spec put_trigger(WardrikDefinition.Context.t(), Definition.t(), String.t(), trigger: map()) ::
          {:ok, Definition.t(), :created | :changed, WardrikTrigger.trigger()}
          | {:error, String.t()}
  def put_trigger(context, %Definition{fields: fields} = definition, name, opts) do
    given = Keyword.fetch!(opts, :trigger)

    with {:ok, fields, status, trigger} <-
           WardrikDefinition.put_trigger(fields, name, trigger: given, context: context),
         do: {:ok, %{definition | fields: fields}, status, trigger}
  end

  @doc "`definition` without the trigger `name`, or `{:error, :not_found}` where it has none."
  @spec delete_trigger(Definition.t(), String.t()) ::
          {:ok, Definition.t()} | {:error, :not_found}
  def delete_trigger(%Definition{fields: fields} = definition, name) do
    with {:ok, fields} <- WardrikDefinition.delete_trigger(fields, name),
         do: {:ok, %{definition | fields: fields}}
  end

  @doc "The channels a definition's fields offer its agent in, by name."
  @spec channels(map()) :: [String.t()]
  def channels(fields), do: WardrikDefinition.channels(fields)
end
