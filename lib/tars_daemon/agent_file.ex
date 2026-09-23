defmodule TarsDaemon.AgentFile do
  @moduledoc """
  One agent, written as a file in `agents/` under the config directory.

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
  | `policy` | a module implementing `Tars.Policy` |
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

  The agent is given the credentials `TarsOAuth` holds where a provider is
  configured, and `TarsVault`'s where the vault has a key.
  """

  alias Tars.Fleet
  alias Tars.LLM.Config

  @enforce_keys [:name, :key, :path, :opts]
  defstruct [:name, :key, :path, :opts, :description]

  @typedoc "An agent file read: its agent's name, key and description, and what `Tars.Fleet.spawn/2` takes."
  @type t() :: %__MODULE__{
          name: String.t(),
          key: String.t(),
          path: Path.t(),
          opts: keyword(),
          description: String.t() | nil
        }

  @shipped [TarsBrave.WebSearch, TarsResearch.Deep, TarsLua.Run]
  @keys ~w(name description model tools org user policy timeout max_iterations)

  @doc "Reads the agent `path` declares."
  @spec read(Path.t()) :: {:ok, t()} | {:error, String.t()}
  def read(path) do
    with {:ok, text} <- File.read(path),
         {:ok, front, body} <- split(text),
         {:ok, fields} <- frontmatter(front) do
      build(path, fields, String.trim(body))
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

  defp build(path, fields, body) do
    case Map.keys(fields) -- @keys do
      [] -> :ok
      [key | _] -> invalid!("#{key} is not a setting; expected one of #{Enum.join(@keys, ", ")}")
    end

    config =
      [system: if(body == "", do: nil, else: body), tools: tools(fields)]
      |> put(:model_spec, fields["model"], &string!(&1, "model"))
      |> put(:max_iterations, fields["max_iterations"], &iterations!/1)
      |> Config.new()

    opts =
      [config: config]
      |> put(:policy, fields["policy"], &policy!/1)
      |> put(:timeout, fields["timeout"], &seconds!/1)
      |> put(:credentials, credentials(), & &1)

    name = optional_string!(fields["name"], "name") || path |> Path.basename() |> Path.rootname()

    key =
      Fleet.key(name,
        org: optional_string!(fields["org"], "org"),
        user: optional_string!(fields["user"], "user")
      )

    {:ok,
     %__MODULE__{
       name: name,
       key: key,
       path: path,
       opts: opts,
       description: optional_string!(fields["description"], "description")
     }}
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
    case String.split(name, "/", parts: 2) do
      [server, "*"] ->
        [server!(server)]

      [server, tool] ->
        invalid!(
          "tools names #{name}; name the whole server as #{server}/*, and list #{tool} " <>
            "in its only in config.yaml"
        )

      [name] ->
        [shipped!(name)]
    end
  end

  defp tool!(name), do: invalid!("tools names #{inspect(name)}, which is not a tool")

  defp shipped!(name) do
    case Map.fetch(Map.new(@shipped, &{&1.tool().name, &1}), name) do
      {:ok, module} -> module
      :error -> module!(name, :tool, 0, "a tool")
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

  defp policy!(name) when is_binary(name), do: module!(name, :authorize, 2, "a policy")
  defp policy!(_name), do: invalid!("policy is a module name")

  defp module!(name, function, arity, what) do
    module = Module.safe_concat([name])

    if Code.ensure_loaded?(module) and function_exported?(module, function, arity),
      do: module,
      else: invalid!("#{name} is not #{what}")
  rescue
    ArgumentError ->
      invalid!("names #{name}, which is neither a module nor #{what} the daemon ships")
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
