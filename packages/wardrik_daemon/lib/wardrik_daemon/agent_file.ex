defmodule WardrikDaemon.AgentFile do
  @moduledoc """
  Reads an agent file, one in `agents/` under the config directory, into the
  `Wardrik.Definition` it writes, under the context `context/1` builds, from
  which `Wardrik.Definition.spec/3` builds the `Wardrik.Agent.Spec` it
  writes on the daemon's host, naming the tools and sources
  `WardrikDaemon.attach/2` attaches, the MCP servers `config.yaml`
  configures among them. The [Agent files](agent-files.md) guide is every
  key a file takes, for whoever writes one.

  A file names tools and policies by name, never a module. Rules a policy
  writes, named or in place, are a `WardrikPolicy`, which the agent carries
  as its hooks: they are written to the store with it and decide its calls
  on any node.

  The agent resolves the credentials its tools name from `WardrikVault` as
  its owner holds them, its user's or, for an agent that works for nobody,
  its org's, and the deployment's only where `vault.shared` names them; its
  owner connects an account through `WardrikOAuth` where a provider is named
  for one it does not hold.

  ## Over HTTP

  The body of `PUT /v1/agents/{id}` is read under the same context, with
  the policies `WardrikDaemon.Agents` keeps, into a definition whose source
  is the token that sent it. `WardrikProtocol`'s `agent_definition.json` is its
  schema; the ID gives the agent's `name`, `org` and `user`. A definition's
  `tools` and `policy` name what the daemon ships or configures, never a
  module, and its `workspace` shares only the trees the scope of the token
  that sent it covers.

  `wardrik init` writes the front door's file; see `WardrikDaemon.CLI.Init`.
  """

  alias Wardrik.Agent.Spec
  alias Wardrik.Definition
  alias WardrikDaemon.Config

  @doc """
  What a definition may name here beyond the host's tools and sources, as
  `Wardrik.Definition` reads it: the orgs `config` declares and its
  `defaults`. A reading under the policies in `policies/` puts them, by
  name, as the context's `:policies`, and one for an org's agents the
  policies `config` holds the org to as its `:held`; see
  `WardrikDaemon.Agents.context/2`.
  """
  @spec context(Config.t()) :: WardrikDefinition.Context.t()
  def context(%Config{} = config) do
    %WardrikDefinition.Context{
      org: Config.org(config),
      orgs: Config.orgs(config),
      policies: %{},
      defaults: config |> Config.section(WardrikDaemon.Agents) |> Keyword.get(:defaults, %{}),
      shares: config |> Config.section(WardrikWorkspace) |> Keyword.get(:shared, []),
      names: %{host: "the daemon", config: "config.yaml", policies: "policies/"}
    }
  end

  @doc """
  An agent file with `fields` as its frontmatter, in the order given, and
  `prompt` after it, or a short one; see `Wardrik.Definition.text/2`.
  """
  @spec text([{String.t(), term()}]) :: String.t()
  @spec text([{String.t(), term()}], String.t()) :: String.t()
  def text(fields), do: Definition.text(fields)
  def text(fields, prompt), do: Definition.text(fields, prompt)

  @doc """
  Reads the spec of the agent `path` declares, under `context`, whose
  `:policies` are the policies in `policies/`, by name, on `:host`.
  """
  @spec read(WardrikDefinition.Context.t(), Path.t(), host: Wardrik.Host.t()) ::
          {:ok, Spec.t()} | {:error, String.t()}
  def read(context, path, opts) do
    with {:ok, definition} <- parse(context, path) do
      case Definition.spec(definition, definition.id,
             context: context,
             host: Keyword.fetch!(opts, :host)
           ) do
        {:ok, spec} -> {:ok, spec}
        {:error, message} -> {:error, "#{path}: #{message}"}
      end
    end
  end

  @doc """
  The `Wardrik.Definition` the agent file `path` writes, read under
  `context`: its frontmatter, with its body as `instructions`, for the
  agent its `name`, `org` and `user` name.
  """
  @spec parse(WardrikDefinition.Context.t(), Path.t()) ::
          {:ok, Definition.t()} | {:error, String.t()}
  def parse(context, path) do
    name = path |> Path.basename() |> Path.rootname()

    with {:ok, text} <- File.read(path),
         {:ok, id, fields} <- Definition.parse(text, name, context),
         {:ok, definition} <-
           Definition.read(fields, id: id, source: {:file, path}, context: context) do
      {:ok, definition}
    else
      {:error, reason} when is_atom(reason) -> {:error, "#{path}: #{:file.format_error(reason)}"}
      {:error, message} -> {:error, "#{path}: #{message}"}
    end
  end
end
