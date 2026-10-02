defmodule WardrikDaemon.Doctor do
  @moduledoc """
  What `wardrik doctor` checks, each a line:

    * `config` - that `config.yaml` reads, as the daemon reads it: a
      `${NAME}` this environment does not set is read from the vault, of a
      daemon that runs
    * `store` - that the store it names is there and keeps the store's
      contract, as `Wardrik.Store.check/1` looks at it
    * `vault` - that each vault key is one the vault can use, from
      `config.yaml`, `WARDRIK_VAULT_KEY` or the key file in the data home (see
      `WardrikDaemon.VaultKey`), and that there is one where OAuth providers or
      servers' credentials need it
    * `mcp NAME` - for each MCP server, that the program a command server
      runs is on this machine, and that the host an HTTP server is reached at
      answers
    * `agents` - that every agent file and policy reads, as the daemon reads
      them, a line for each that does not

  `bin/wardrik` runs it on a VM of its own, so it checks a daemon that does
  not start as well as one that runs. It cannot read the store from there, so
  it reads what the vault holds from a daemon that runs, as `bin/wardrik`
  reaches one; the secrets stay in doctor's VM. Where none runs, a name from
  the vault reads as itself, `${NAME}`, and doctor says it could not check.

      $ wardrik doctor
      ok    config      /home/me/.config/wardrik/config.yaml reads
      ok    store       on this node's disk, at /home/me/.local/share/wardrik/store
      ok    vault       1 key, which seals
      ok    mcp github  answers at api.githubcopilot.com:443; each user authorizes it
      FAIL  mcp files   runs npx, which is not on this machine's PATH
      ok    agents      2 agent files and 1 policy read

  It exits with status 1 where a check fails. Where `config.yaml` does not
  read, it is the only check.
  """

  alias WardrikDaemon.Agents
  alias WardrikDaemon.Config
  alias WardrikDaemon.VaultKey

  @connect_timeout :timer.seconds(5)

  @typedoc "One check: whether it passed, what it looked at, and what it found."
  @type check() :: {:ok | :error, String.t(), String.t()}

  @doc """
  Runs the checks on the config directory, with its settings applied as the
  daemon applies them, prints them, and stops the VM.
  """
  @spec main() :: no_return()
  def main do
    :logger.set_primary_config(:level, :none)
    {:ok, _started} = Application.ensure_all_started([:req, :postgrex, :ssl])
    dir = Config.config_dir()
    vault = daemon_vault()

    with {:ok, file} <- Config.file(dir),
         {:ok, settings, _from_vault} <- read(file, vault),
         do: Config.apply(settings)

    # Reading an agent file builds its tools, and a file naming every tool
    # names the tool workers, whose group the daemon starts. Here it starts
    # empty: a check is made with no worker connected.
    {:ok, _workers} = Supervisor.start_link([WardrikHTTP.Workers], strategy: :one_for_one)

    checks = checks(dir, vault)
    IO.puts(report(checks))
    System.halt(if Enum.all?(checks, &(elem(&1, 0) == :ok)), do: 0, else: 1)
  end

  defp daemon_vault do
    target = System.get_env("RELEASE_NODE", "")
    name = :"doctor-#{System.unique_integer([:positive])}-#{target}"

    with {:ok, _pid} <- Node.start(name, name_domain: name_domain(), hidden: true),
         {:ok, daemon} <- joined(daemon_node(target)) do
      &:erpc.call(daemon, WardrikDaemon.Secrets, :named, [&1])
    else
      _not_running -> nil
    end
  end

  defp joined(daemon) do
    # reach:disable-next-line unsafe_atom_creation -- the release's cookie, once per run
    true = Node.set_cookie(daemon, String.to_atom(System.get_env("RELEASE_COOKIE", "")))
    if Node.connect(daemon), do: {:ok, daemon}, else: :error
  end

  defp name_domain,
    do: if(System.get_env("RELEASE_DISTRIBUTION") == "name", do: :longnames, else: :shortnames)

  defp daemon_node(target) do
    if String.contains?(target, "@"),
      # reach:disable-next-line unsafe_atom_creation -- the release's node name, once per run
      do: String.to_atom(target),
      else: :"#{target}@#{node() |> Atom.to_string() |> String.split("@") |> List.last()}"
  end

  @doc """
  The checks, in order. `vault` answers the deployment's secret of a name, as
  a daemon that runs reads it, or is `nil` where none does.
  """
  @spec checks(Path.t(), (String.t() -> String.t() | nil) | nil) :: [check()]
  def checks(config_dir, vault \\ nil) do
    with {:ok, file} <- Config.file(config_dir),
         {:ok, settings, from_vault} <- read(file, vault) do
      [config(file, from_vault, vault), store(settings), vault(settings)] ++
        servers(settings) ++ agents(config_dir)
    else
      {:error, message} -> [{:error, "config", message}]
    end
  end

  defp read(file, vault) do
    doctor = self()

    lookup = fn name ->
      secret = if vault, do: vault.(name), else: "${#{name}}"
      if secret, do: send(doctor, {:from_vault, name})
      secret
    end

    case Config.read(file, vault: lookup) do
      {:ok, settings} -> {:ok, settings, from_vault([])}
      {:error, message} -> {:error, message <> unread(vault, from_vault([]))}
    end
  end

  defp from_vault(names) do
    receive do
      {:from_vault, name} -> from_vault([name | names])
    after
      0 -> names |> Enum.reverse() |> Enum.uniq()
    end
  end

  defp unread(nil, [_name | _rest] = names),
    do:
      ". It reads #{variables(names)} from the vault, which doctor reads only while the " <>
        "daemon runs, and checked it as written"

  defp unread(_vault, _names), do: ""

  defp config(file, [], _vault), do: {:ok, "config", "#{file} reads"}

  defp config(file, names, nil),
    do:
      {:ok, "config",
       "#{file} reads, with #{variables(names)} from the vault, which doctor reads only " <>
         "while the daemon runs"}

  defp config(file, names, _vault),
    do: {:ok, "config", "#{file} reads, with #{variables(names)} from the vault"}

  defp variables(names) do
    case Enum.map(names, &"${#{&1}}") do
      [only] ->
        only

      shown ->
        IO.iodata_to_binary([Enum.join(Enum.drop(shown, -1), ", "), " and ", List.last(shown)])
    end
  end

  defp store(settings) do
    {result, found} =
      settings
      |> Config.boot()
      |> Keyword.get(:wardrik, [])
      |> Keyword.get(Wardrik.Store, [])
      |> Wardrik.Store.check()

    {result, "store", found}
  end

  # -- vault -------------------------------------------------------------------

  # config.yaml's keys where it names any, those WARDRIK_VAULT_KEY gave the
  # release where it does not, and the key file in the data home where neither
  # gives one.
  defp vault(settings) do
    keys =
      Keyword.get(Keyword.get(settings, WardrikVault, []), :keys) || WardrikVault.Config.keys()

    if keys == [], do: key_file(settings), else: vault_keys(keys, settings)
  end

  defp key_file(settings) do
    file = VaultKey.file()

    case VaultKey.read(file) do
      {:ok, _key} -> {:ok, "vault", "1 key, from #{file}"}
      :none -> vault_keys([], settings)
      {:error, message} -> {:error, "vault", message}
    end
  end

  defp vault_keys(keys, settings) do
    case {Enum.reject(Enum.with_index(keys, 1), fn {key, _n} -> WardrikVault.key?(key) end), keys,
          needs_key(settings)} do
      {[{_key, n} | _rest], _keys, _needs} ->
        {:error, "vault",
         "key #{n} is not 32 bytes in base64; make one with openssl rand -base64 32"}

      {[], [], nil} ->
        {:ok, "vault", "no key, and nothing configured needs one"}

      {[], [], needs} ->
        {:error, "vault",
         "no key, and #{needs} needs one to seal what users authorize; wardrik vault put makes one, or set WARDRIK_VAULT_KEY, or vault.keys in config.yaml"}

      {[], [_one], _needs} ->
        {:ok, "vault", "1 key, which seals"}

      {[], keys, _needs} ->
        {:ok, "vault", "#{length(keys)} keys: the first seals, and any of them unseals"}
    end
  end

  defp needs_key(settings) do
    servers = settings |> Keyword.get(WardrikMCP, []) |> Keyword.get(:servers, [])

    cond do
      settings |> Keyword.get(WardrikOAuth, []) |> Keyword.get(:providers, []) != [] ->
        "oauth"

      credentialed = Enum.find(servers, fn {_ref, opts} -> opts[:credential] end) ->
        "mcp.#{elem(credentialed, 0)}'s credential"

      true ->
        nil
    end
  end

  # -- servers -----------------------------------------------------------------

  defp servers(settings) do
    providers =
      for {name, _provider} <-
            settings |> Keyword.get(WardrikOAuth, []) |> Keyword.get(:providers, []),
          do: to_string(name)

    for {ref, opts} <- settings |> Keyword.get(WardrikMCP, []) |> Keyword.get(:servers, []) do
      {result, found} = reach(Keyword.fetch!(opts, :transport))
      {result, "mcp #{ref}", found <> authorized(opts[:credential], providers)}
    end
  end

  # Where a server's credential comes from: the vault, where a user, an org
  # or the deployment may hold it, and an account each user connects where a
  # provider is named for it.
  defp authorized(nil, _providers), do: ""

  defp authorized(name, providers) do
    if name in providers,
      do: "; credential #{name}, from the vault, or an account each user connects",
      else: "; credential #{name}, from the vault"
  end

  defp reach({:stdio, opts}) do
    command = Keyword.fetch!(opts, :command)

    case System.find_executable(command) do
      nil -> {:error, "runs #{command}, which is not on this machine's PATH"}
      path -> {:ok, "runs #{command}, at #{path}"}
    end
  end

  defp reach({_http, opts}) do
    url = Keyword.fetch!(opts, :base_url)

    if String.contains?(url, "${"),
      do: {:ok, "reads its url from the vault, which doctor reads only while the daemon runs"},
      else: answers(url)
  end

  defp answers(url) do
    uri = URI.parse(url)
    where = "#{uri.host}:#{uri.port}"

    case connect(uri) do
      :ok -> {:ok, "answers at #{where}"}
      {:error, reason} -> {:error, "#{where} does not answer: #{describe(reason)}"}
    end
  end

  defp connect(%URI{scheme: "https", host: host, port: port}) do
    options = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: String.to_charlist(host),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    with {:ok, socket} <- :ssl.connect(String.to_charlist(host), port, options, @connect_timeout) do
      :ssl.close(socket)
    end
  end

  defp connect(%URI{host: host, port: port}) do
    with {:ok, socket} <- :gen_tcp.connect(String.to_charlist(host), port, [], @connect_timeout) do
      :gen_tcp.close(socket)
    end
  end

  defp describe(:nxdomain), do: "no such host"
  defp describe(:econnrefused), do: "the connection was refused"
  defp describe(:timeout), do: "no answer within #{div(@connect_timeout, 1000)} seconds"
  defp describe(reason), do: inspect(reason)

  # -- agents ------------------------------------------------------------------

  defp agents(config_dir) do
    {policies, agents} = Agents.read_files(config_dir)

    case for({path, {:error, message}} <- policies ++ agents, do: {path, message}) do
      [] -> [{:ok, "agents", read(length(agents), length(policies), config_dir)}]
      failed -> for {_path, message} <- failed, do: {:error, "agents", message}
    end
  end

  defp read(0, 0, config_dir), do: "no agent files in #{Path.join(config_dir, "agents")}"

  defp read(agents, 0, _dir), do: "#{count(agents, "agent file")} read"

  defp read(agents, policies, _dir),
    do: "#{count(agents, "agent file")} and #{count(policies, "policy", "policies")} read"

  defp count(n, one, many \\ nil)
  defp count(1, one, _many), do: "1 #{one}"
  defp count(n, one, many), do: "#{n} #{many || one <> "s"}"

  @doc "The checks, a line each."
  @spec report([check()]) :: String.t()
  def report(checks) do
    width = checks |> Enum.map(&String.length(elem(&1, 1))) |> Enum.max()

    Enum.map_join(checks, "\n", fn {result, name, found} ->
      Enum.join(
        [String.pad_trailing(mark(result), 4), String.pad_trailing(name, width), found],
        "  "
      )
    end)
  end

  defp mark(:ok), do: "ok"
  defp mark(:error), do: "FAIL"
end
