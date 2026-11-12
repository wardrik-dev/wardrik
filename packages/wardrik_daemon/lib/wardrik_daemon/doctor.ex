defmodule WardrikDaemon.Doctor do
  @moduledoc """
  Checks what the daemon reads, running or not.

      $ wardrik doctor
      ok    env            /home/me/.config/wardrik/env sets 3 variables
      ok    config         /home/me/.config/wardrik/config.yaml reads
      ok    vault          1 key from /home/me/.local/share/wardrik/vault_key, which seals
      ok    mcp github     answers at api.githubcopilot.com:443
      FAIL  mcp notes      runs npx, which isn't on this machine's PATH
      ok    agents         2 agent files and 1 policy read

    * It can't open a running daemon's store, so a `${NAME}` only the vault holds goes unchecked.
    * If `config.yaml` doesn't read, nothing after it is checked.
  """

  alias WardrikDaemon.Config
  alias WardrikDaemon.Dirs
  alias WardrikDaemon.EnvFile

  @typedoc "One check: whether it passed, what it looked at, and what it found."
  @type check() :: {:ok | :warn | :fail, String.t(), String.t()}

  @connect_timeout 5_000

  @doc """
  Runs every check on the files the environment `env` points at.

  ## Options

    * `:req_options` - merged into each request a channel's check makes.
  """
  @spec run(%{String.t() => String.t()}, keyword()) :: [check()]
  def run(env, opts \\ []) do
    dirs = Dirs.new(env)
    env = EnvFile.load(dirs.env_file, env)

    case Config.read(dirs, env, &unchecked/1) do
      {:ok, config} ->
        [env(dirs), configured(dirs, env, config) | checks(config, dirs, env, opts)]

      {:error, why} ->
        [env(dirs), {:fail, "config", why}]
    end
  end

  @doc "Prints `checks`, a line each. Returns how many failed."
  @spec print([check()]) :: non_neg_integer()
  def print(checks) do
    Enum.each(lines(checks), &IO.puts(Owl.Data.untag(&1)))
    failed(checks)
  end

  @doc "Returns `checks` as lines, each labelled in colour by how it went."
  @spec lines([check()]) :: [Owl.Data.t()]
  def lines(checks) do
    width =
      checks |> Enum.map(fn {_status, name, _found} -> String.length(name) end) |> Enum.max()

    for {status, name, found} <- checks,
        do: [label(status), "  ", String.pad_trailing(name, width), "  ", found]
  end

  @doc "Returns how many of `checks` failed."
  @spec failed([check()]) :: non_neg_integer()
  def failed(checks), do: Enum.count(checks, &match?({:fail, _name, _found}, &1))

  defp label(:ok), do: Owl.Data.tag("ok  ", :green)
  defp label(:warn), do: Owl.Data.tag("warn", :yellow)
  defp label(:fail), do: Owl.Data.tag("FAIL", :red)

  defp unchecked(name), do: {:ok, "${#{name}}"}

  @doc "Returns `count` of `thing`, as `1 key` or `2 keys`."
  @spec counted(non_neg_integer(), String.t()) :: String.t()
  def counted(1, thing), do: "1 #{thing}"
  def counted(count, "policy"), do: "#{count} policies"
  def counted(count, thing), do: "#{count} #{thing}s"

  defp checks(config, dirs, env, opts) do
    [storage(config, dirs), vault(config, dirs, env), brave(config)] ++
      Enum.map(config.mcp, &mcp/1) ++
      Enum.map(config.harnesses, &harness/1) ++
      Enum.map(config.checkouts, &checkout/1) ++
      Enum.map(config.channels, &channel(&1, Keyword.get(opts, :req_options, []))) ++
      oauth(config) ++
      Enum.map(config.warnings, &{:warn, "config", &1}) ++
      WardrikDaemon.Doctor.Agents.check(config, dirs) ++
      assistant(config, dirs)
  end

  # An assistant.md from an older init lacks tools init gives now. A file that doesn't read is
  # the agents check's to report.
  defp assistant(config, dirs) do
    path = Dirs.config(dirs, "agents/assistant.md")

    with {:ok, _agent, definition} <- WardrikDaemon.AgentFile.read(path, config),
         missing when missing != [] <-
           WardrikDaemon.CLI.Init.assistant_tools() -- List.wrap(definition["tools"]) do
      [
        {:warn, "assistant",
         "#{path} doesn't give #{Enum.join(missing, ", ")}, which wardrik init gives now. Add them to its tools to let it answer questions, set things up and check how things run."}
      ]
    else
      [] -> [{:ok, "assistant", "#{path} has every tool wardrik init gives"}]
      {:error, _why} -> []
    end
  end

  defp env(%Dirs{env_file: path}) do
    case File.stat(path) do
      {:error, :enoent} ->
        {:ok, "env", "#{path} isn't there, so nothing is set from it"}

      {:ok, %File.Stat{mode: mode}} when Bitwise.band(mode, 0o077) != 0 ->
        {:fail, "env", "#{path} can be read by others; chmod 600 it"}

      {:ok, _stat} ->
        env_lines(path)
    end
  end

  defp env_lines(path) do
    case EnvFile.unread(path) do
      [] -> {:ok, "env", "#{path} sets #{map_size(EnvFile.load(path, %{}))} variables"}
      lines -> {:fail, "env", "#{path} sets no variable on line #{Enum.join(lines, ", ")}"}
    end
  end

  defp configured(dirs, env, _config) do
    path = Dirs.config(dirs, "config.yaml")

    case Enum.reject(Config.sealable(dirs), &Map.has_key?(env, &1)) do
      [] -> {:ok, "config", "#{path} reads"}
      names -> {:ok, "config", "#{path} reads; the vault must hold #{Enum.join(names, ", ")}"}
    end
  end

  defp vault(config, dirs, env) do
    case keys(config, dirs, env) do
      nil ->
        {:ok, "vault",
         "no key yet; the daemon makes #{Dirs.data_home(dirs, "vault_key")} as it starts"}

      {from, keys} ->
        sealing(from, keys)
    end
  end

  defp keys(%Config{keys: [_ | _] = keys}, _dirs, _env), do: {"config.yaml", keys}
  defp keys(_config, _dirs, %{"WARDRIK_VAULT_KEY" => key}), do: {"WARDRIK_VAULT_KEY", [key]}

  defp keys(_config, dirs, _env) do
    path = Dirs.data_home(dirs, "vault_key")

    case File.read(path) do
      {:ok, key} -> {path, [String.trim(key)]}
      {:error, _reason} -> nil
    end
  end

  defp sealing(from, keys) do
    if length(Wardrik.Vault.Sealed.decode_keys(keys)) == length(keys),
      do: {:ok, "vault", "#{counted(length(keys), "key")} from #{from}, which seals"},
      else: {:fail, "vault", "a key from #{from} isn't 32 bytes of base64"}
  end

  defp storage(%Config{storage: nil}, dirs),
    do: {:ok, "storage", "keeps everything on this node's disk, under #{dirs.data}"}

  defp storage(%Config{storage: {:postgres, url}}, _dirs) do
    %URI{host: host, port: port, path: path} = URI.parse(url)
    where = "#{host}:#{port || 5432}#{path}"

    case reachable(host, port || 5432) do
      :ok -> {:ok, "storage", "keeps everything in Postgres at #{where}"}
      {:error, why} -> {:fail, "storage", "Postgres at #{where} doesn't answer: #{why}"}
    end
  end

  defp storage(%Config{storage: {:s3, opts}}, _dirs) do
    where = "the bucket #{opts[:bucket]} at #{opts[:endpoint]}"
    %URI{host: host, port: port} = URI.parse(opts[:endpoint])

    case reachable(host, port) do
      :ok -> {:ok, "storage", "keeps everything in #{where}"}
      {:error, why} -> {:fail, "storage", "#{where} doesn't answer: #{why}"}
    end
  end

  defp brave(%Config{brave: nil}),
    do:
      {:warn, "brave",
       "config.yaml gives web_search no key. A key sealed with `wardrik vault put BRAVE_API_KEY --for api_key` works too, and this check can't see the vault"}

  defp brave(_config), do: {:ok, "brave", "web_search has a key"}

  defp harness({name, opts}) do
    command = Keyword.fetch!(opts, :command)

    if System.find_executable(command),
      do: {:ok, "harness #{name}", "runs #{command}"},
      else: {:fail, "harness #{name}", "runs #{command}, which isn't on this machine's PATH"}
  end

  defp checkout({name, opts}) do
    path = Keyword.fetch!(opts, :path)
    base = Keyword.fetch!(opts, :base)

    case System.cmd("git", ["-C", path, "rev-parse", "--verify", base], stderr_to_stdout: true) do
      {_head, 0} ->
        {:ok, "checkout #{name}", "#{path} is a git repository; new work starts from #{base}"}

      {_output, _status} ->
        {:fail, "checkout #{name}", "#{path} isn't a git repository with #{base}"}
    end
  end

  defp mcp({name, opts}), do: mcp(name, Keyword.fetch!(opts, :transport))

  defp mcp(name, {:stdio, opts}) do
    command = Keyword.fetch!(opts, :command)

    if System.find_executable(command),
      do: {:ok, "mcp #{name}", "runs #{command}"},
      else: {:fail, "mcp #{name}", "runs #{command}, which isn't on this machine's PATH"}
  end

  defp mcp(name, {:streamable_http, opts}) do
    %URI{host: host, port: port} = URI.parse(Keyword.fetch!(opts, :url))

    case reachable(host, port) do
      :ok -> {:ok, "mcp #{name}", "answers at #{host}:#{port}"}
      {:error, why} -> {:fail, "mcp #{name}", "doesn't answer at #{host}:#{port}: #{why}"}
    end
  end

  defp reachable(host, port) do
    case :gen_tcp.connect(to_charlist(host), port, [], @connect_timeout) do
      {:ok, socket} -> :gen_tcp.close(socket)
      {:error, reason} -> {:error, :inet.format_error(reason)}
    end
  end

  defp channel({name, {adapter, opts}}, req_options) do
    with how when is_binary(how) <- taking(opts),
         {:ok, reached} <- reached(adapter, opts, req_options) do
      {:ok, "channel #{name}", Enum.join([how, reached, members(opts[:identities])], "; ")}
    else
      nil ->
        {:fail, "channel #{name}",
         "takes nothing from Slack; give it signing_secret or app_token"}

      {:error, why} ->
        {:fail, "channel #{name}", why}
    end
  end

  defp reached(adapter, opts, req_options) do
    cond do
      Enum.any?([opts[:token], opts[:app_token]], &sealed?/1) ->
        {:ok, "its tokens are checked as the daemon starts, since the vault holds them"}

      Code.ensure_loaded?(adapter) and function_exported?(adapter, :check, 1) ->
        adapter.check(Keyword.put(opts, :req_options, req_options))

      true ->
        {:ok, "its tokens aren't checked"}
    end
  end

  defp sealed?(value), do: is_binary(value) and String.starts_with?(value, "${")

  defp taking(opts) do
    cond do
      opts[:app_token] -> "takes Slack's events over Socket Mode"
      opts[:signing_secret] -> "takes Slack's events over HTTP"
      true -> nil
    end
  end

  defp members({_module, opts}) do
    mapped = "#{counted(map_size(opts[:members]), "member")} mapped to users"
    domains = for {domain, org} <- opts[:domains], do: "#{domain} members to #{org}"
    Enum.join([mapped | domains] ++ ["others refused"], ", ")
  end

  defp oauth(%Config{oauth: nil}), do: []

  defp oauth(config) do
    providers = config.oauth[:providers]

    if providers != [] and Enum.all?(providers, fn {_name, opts} -> opts[:flow] == :device end),
      do: [{:ok, "oauth", "signs people in with a device code, which needs no callback"}],
      else: [callback(Config.base_url(config))]
  end

  defp callback(base_url) do
    case Req.get(base_url <> "/v1/openapi.json", retry: false, receive_timeout: @connect_timeout) do
      {:ok, %Req.Response{status: 200}} ->
        {:ok, "oauth", "#{base_url}/oauth reaches the daemon"}

      _unreached ->
        {:fail, "oauth", "#{base_url}/oauth doesn't reach a running daemon; check base_url"}
    end
  end
end
