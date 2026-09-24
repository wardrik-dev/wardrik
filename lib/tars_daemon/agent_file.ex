defmodule TarsDaemon.AgentFile do
  @moduledoc """
  Reads an agent file, one in `agents/` under the config directory, into the
  `Tars.Agent.Spec` it writes.

      ---
      name: triage
      description: Watches the incident queue and says what needs an engineer.
      model: anthropic:claude-sonnet-5
      tools: [web_search, linear/*]
      org: acme
      user: jon
      timeout: 600
      ---
      You watch the incident queue. Summarise anything new, and say which
      issues need an engineer.

  The body after the frontmatter is the agent's system prompt, and a file
  with no frontmatter is all prompt. The fields a file shares with the agent
  files other tools read, `name`, `description`, `tools` and `model`, mean what
  they mean there.

  | Key | What it gives the agent |
  | --- | --- |
  | `name` | its name, and with `org` and `user` its key in the fleet. The file's name without `.md` when absent |
  | `description` | what it is for, as `tars status` shows it |
  | `model` | the model, as `provider:model`. `Tars.LLM.Config`'s default when absent |
  | `tools` | what it may call; see below |
  | `org`, `user` | who it works for |
  | `policy` | what its tool calls may do; see below |
  | `timeout` | how many seconds a turn may take |
  | `max_iterations` | how many rounds of tool calls a turn may make, or `infinity` |

  ## Tools

  `tools` lists what the agent may call, and an agent whose file lists none
  has none.

    * a tool the daemon ships, by name: #{Enum.map_join(["web_search", "deep_research", "run_lua"], ", ", &"`#{&1}`")}
    * `server/*`, every tool of an MCP server as `config.yaml` names it. A
      server's `only` and `except` narrow what it offers
    * `*`, every tool the daemon ships and every MCP server connected
    * a module implementing `Tars.Tool`

  ## Policy

  `policy` is one of

    * the name of a policy in `policies/` under the config directory:
      `policy: careful` for `policies/careful.yaml`
    * rules written in place, as a policy file writes them:

          policy:
            ask: [github/*]
            deny: [run_lua]

    * a module implementing `Tars.Policy`

  and without one every call the agent's tools allow may run. Rules, named or
  written in place, are a `TarsPolicy`, and the agent carries them: they are
  written to the store with it and decide its calls on any node. A policy with
  a `budget` limits what the agent spends on model calls too, parking it when
  the budget runs out until a person approves more.

  The agent is given the credentials `TarsOAuth` holds where a provider is
  configured, and `TarsVault`'s where the vault has a key.
  """

  alias Tars.Agent.Spec
  alias Tars.LLM.Config
  alias TarsPolicy.Pattern

  @shipped [TarsBrave.WebSearch, TarsResearch.Deep, TarsLua.Run]
  @keys ~w(name description model tools org user policy timeout max_iterations)

  @doc """
  Reads the spec of the agent `path` declares, with `policies` the policies in
  `policies/`, by name.
  """
  @spec read(Path.t(), %{String.t() => TarsPolicy.t()}) :: {:ok, Spec.t()} | {:error, String.t()}
  def read(path, policies \\ %{}) do
    with {:ok, text} <- File.read(path),
         {:ok, front, body} <- split(text),
         {:ok, fields} <- frontmatter(front) do
      build(path, fields, String.trim(body), policies)
    else
      {:error, reason} when is_atom(reason) -> {:error, "#{path}: #{:file.format_error(reason)}"}
      {:error, message} -> {:error, "#{path}: #{message}"}
    end
  catch
    {:invalid, message} -> {:error, "#{path}: #{message}"}
  end

  defp split("---\n" <> rest) do
    case String.split(rest, ~r/^---[ \t]*$\n?/m, parts: 2) do
      [front, body] -> {:ok, front, body}
      [_unclosed] -> {:error, "has frontmatter that is never closed with ---"}
    end
  end

  defp split(text), do: {:ok, "", text}

  defp frontmatter(front) do
    case YamlElixir.read_from_string(front) do
      {:ok, fields} when is_map(fields) -> {:ok, fields}
      {:ok, nil} -> {:ok, %{}}
      {:ok, _other} -> {:error, "has frontmatter that is not a set of keys"}
      {:error, error} -> {:error, "has frontmatter that is not YAML: #{Exception.message(error)}"}
    end
  end

  defp build(path, fields, body, policies) do
    case Map.keys(fields) -- @keys do
      [] -> :ok
      [key | _] -> invalid!("#{key} is not a setting; expected one of #{Enum.join(@keys, ", ")}")
    end

    config =
      [system: if(body == "", do: nil, else: body), tools: tools(fields)]
      |> put(:model_spec, fields["model"], &string!(&1, "model"))
      |> put(:max_iterations, fields["max_iterations"], &iterations!/1)
      |> Config.new()

    policy = policy(fields["policy"], policies)

    {:ok,
     Spec.new(
       name:
         optional_string!(fields["name"], "name") || path |> Path.basename() |> Path.rootname(),
       org: optional_string!(fields["org"], "org"),
       user: optional_string!(fields["user"], "user"),
       description: optional_string!(fields["description"], "description"),
       config: config,
       policy: policy,
       dispatch: budgeted(policy),
       timeout: fields["timeout"] && seconds!(fields["timeout"]),
       credentials: credentials()
     )}
  rescue
    error in [ArgumentError] -> {:error, Exception.message(error)}
  end

  defp put(opts, _key, nil, _cast), do: opts
  defp put(opts, key, value, cast), do: Keyword.put(opts, key, cast.(value))

  # -- tools and servers -----------------------------------------------------

  defp tools(%{"tools" => names}) when is_list(names),
    do: names |> Enum.flat_map(&tool!/1) |> Enum.uniq()

  defp tools(%{"tools" => _names}), do: invalid!("tools is a list")
  defp tools(_fields), do: []

  defp tool!("*"), do: @shipped ++ [{TarsMCP, :*}]

  defp tool!(name) when is_binary(name) do
    pattern = Pattern.parse!(name)

    cond do
      server = Pattern.server(pattern) ->
        [server!(server)]

      String.contains?(name, "/") ->
        [server, tool] = String.split(name, "/", parts: 2)

        invalid!(
          "tools names #{name}; name the whole server as #{server}/*, and list #{tool} " <>
            "in its only in config.yaml"
        )

      true ->
        [shipped!(name)]
    end
  end

  defp tool!(name), do: invalid!("tools names #{inspect(name)}, which is not a tool")

  defp shipped!(name) do
    case Map.fetch(Map.new(@shipped, &{&1.tool().name, &1}), name) do
      {:ok, module} -> module
      :error -> module!(name, :tool, 0, "a tool", "a tool the daemon ships")
    end
  end

  defp server!(name) do
    configured = Map.new(TarsMCP.Config.refs(), &{Atom.to_string(&1), &1})

    case Map.fetch(configured, name) do
      {:ok, ref} ->
        {TarsMCP, ref}

      :error ->
        invalid!(
          "tools names #{name}/*, but config.yaml configures no server #{name}" <>
            configured_servers(configured)
        )
    end
  end

  defp configured_servers(configured) when map_size(configured) == 0, do: ""

  defp configured_servers(configured),
    do:
      ["; it has ", Enum.map_join(configured, ", ", fn {name, _ref} -> name end)]
      |> IO.iodata_to_binary()

  # -- scalars ---------------------------------------------------------------

  # A policy with a budget is the agent's dispatch as well, so it sees every
  # model call the agent makes.
  defp budgeted({TarsPolicy, %TarsPolicy{budget: %TarsPolicy.Budget{}}} = policy), do: policy
  defp budgeted(_policy), do: nil

  defp policy(nil, _policies), do: nil

  defp policy(name, policies) when is_binary(name) do
    case Map.fetch(policies, name) do
      {:ok, policy} -> {TarsPolicy, policy}
      :error -> module!(name, :authorize, 2, "a policy", "a policy in policies/")
    end
  end

  defp policy(fields, _policies) when is_map(fields) do
    case TarsPolicy.decode(fields) do
      {:ok, policy} -> {TarsPolicy, policy}
      {:error, message} -> invalid!("policy " <> message)
    end
  end

  defp policy(_value, _policies),
    do: invalid!("policy is the name of a policy, rules, or a module")

  defp module!(name, function, arity, what, known) do
    module = Module.safe_concat([name])

    if Code.ensure_loaded?(module) and function_exported?(module, function, arity),
      do: module,
      else: invalid!("#{name} is not #{what}")
  rescue
    ArgumentError -> invalid!("names #{name}, which is neither #{known} nor a module")
  end

  defp seconds!(seconds) when is_integer(seconds) and seconds > 0, do: :timer.seconds(seconds)
  defp seconds!(_seconds), do: invalid!("timeout is a whole number of seconds")

  defp iterations!(n) when is_integer(n) and n > 0, do: n
  defp iterations!("infinity"), do: :infinity
  defp iterations!(_n), do: invalid!("max_iterations is a whole number, or infinity")

  defp string!(value, _key) when is_binary(value), do: value
  defp string!(_value, key), do: invalid!("#{key} is a string")

  defp optional_string!(nil, _key), do: nil

  defp optional_string!(value, _key) when is_binary(value) or is_integer(value),
    do: to_string(value)

  defp optional_string!(_value, key), do: invalid!("#{key} is a string")

  defp credentials do
    cond do
      TarsOAuth.Config.configured?() -> TarsOAuth
      TarsVault.ready?() -> TarsVault
      true -> nil
    end
  end

  defp invalid!(message), do: throw({:invalid, message})
end
