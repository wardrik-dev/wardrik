defmodule WardrikDaemon.SSH do
  @moduledoc """
  Serves the TUI over SSH, once the config directory holds keys to let in and
  the build has a TUI to serve.

  With an `ssh/authorized_keys` file in the config directory, in OpenSSH's
  format, the daemon listens on port 2222 on loopback, and a client holding a
  key in the file may connect under the names the file lists it for: those
  its `principals` option gives, or else the name its comment gives before
  any `@`, as `jon@laptop` gives `jon`:

      ssh -p 2222 jon@localhost

      principals="jon,ana" ssh-ed25519 AAAAC3Nza... ana@desk
      ssh-ed25519 AAAAC3Nza... jon@laptop

  The file is read at every login, so a key added or removed counts from the
  next connection on, with no restart. The host key is generated the first time
  the daemon listens, in `ssh/` under the data directory, and kept; the
  directory and the key are this user's alone, however they were left.

  Each connection is a session of the `:entrypoint` the application
  environment names, given the deployment's org and the daemon's
  `Wardrik.Host`, and the name is who it is for. `config/config.exs` names
  the TUI's, which starts agents through the host's `Wardrik.Definition`, as
  every surface does:

      config :wardrik_daemon, WardrikDaemon.SSH, entrypoint: {WardrikTUI.SSH, []}

  Nothing else in the daemon names the TUI, so a build without it names no
  entrypoint and serves nothing, and says so where keys are there to let in.
  `termite_ssh`, which listens, is an optional dependency like the TUI's own:
  the Hex package leaves the TUI out, and the release carries both.

  `config.yaml` moves it:

      ssh:
        port: 2222
        ip: 0.0.0.0     # every interface; loopback unless set

  A listener that cannot listen, on a port another process holds, logs why,
  leaves the daemon running without it, and tries again every five seconds.
  Several nodes of a cluster on one machine share one port this way: the
  first to start serves it, and when that node stops another takes it over.
  """

  use GenServer

  require Logger

  # Only reached where an entrypoint is named, which a build with the TUI,
  # and so with termite_ssh and the :ssh it brings, does.
  @compile {:no_warn_undefined, [Termite.SSH, :ssh_file]}

  @host_key "ssh_host_rsa_key"

  @doc """
  The listener for a daemon whose config lives in `config_dir` and whose data
  lives in `data_dir`, as `settings` place it, whose sessions run on `host`:
  none where `config_dir` holds no `ssh/authorized_keys`, or where `settings`
  names no `:entrypoint`.
  """
  @spec children(Path.t(), Path.t(), Wardrik.Host.t(), keyword()) :: [{module(), keyword()}]
  def children(
        config_dir,
        data_dir,
        host,
        settings \\ Application.get_env(:wardrik_daemon, __MODULE__, [])
      ) do
    keys = Path.join([config_dir, "ssh", "authorized_keys"])

    case {File.exists?(keys), Keyword.fetch(settings, :entrypoint)} do
      {false, _entrypoint} ->
        []

      {true, :error} ->
        Logger.warning("SSH is not served: #{keys} lets keys in, but this build has no TUI")
        []

      {true, {:ok, entrypoint}} ->
        [
          {__MODULE__,
           name: __MODULE__,
           port: Keyword.get(settings, :port, 2222),
           ip: Keyword.get(settings, :ip, {127, 0, 0, 1}),
           auth: {:public_key, fn user, key -> authorized?(keys, user, key) end},
           system_dir: host_key!(Path.join(data_dir, "ssh")),
           entrypoint: entrypoint(entrypoint, host)}
        ]
    end
  end

  # A session finds an agent named without an org in the deployment's, and
  # runs what it asks on the daemon's host.
  defp entrypoint({module, opts}, host),
    do:
      {module,
       opts |> Keyword.put_new(:org, WardrikDaemon.Config.org()) |> Keyword.put(:host, host)}

  @retry :timer.seconds(5)

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  @doc """
  Starts the process that holds the listener `Termite.SSH` runs, listening
  where it can and trying again every `:retry` milliseconds where it cannot.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    # A listener that cannot listen exits with why, linked to this process.
    Process.flag(:trap_exit, true)
    {retry, opts} = Keyword.pop(opts, :retry, @retry)
    {:ok, listen({:waiting, opts, retry}, :first)}
  end

  @impl true
  def handle_info(:listen, {:waiting, _opts, _retry} = state),
    do: {:noreply, listen(state, :again)}

  def handle_info(:listen, state), do: {:noreply, state}
  def handle_info({:EXIT, listener, reason}, {:serving, listener}), do: {:stop, reason, nil}
  def handle_info({:EXIT, _process, _reason}, state), do: {:noreply, state}

  defp listen({:waiting, opts, retry} = state, attempt) do
    case Termite.SSH.start_link(opts) do
      {:ok, listener} ->
        if attempt == :again, do: Logger.info("SSH is served on port #{opts[:port]} now")
        {:serving, listener}

      {:error, reason} ->
        if attempt == :first do
          Logger.warning(
            "SSH is not served: port #{opts[:port]} on #{:inet.ntoa(opts[:ip])} could not be " <>
              "listened on: #{inspect(reason)}. It is tried again every #{div(retry, 1000)}s"
          )
        end

        Process.send_after(self(), :listen, retry)
        state
    end
  end

  @doc """
  Whether `key` may log in as `user` by the OpenSSH `authorized_keys` file
  at `path`: where the file lists it for that name, by its `principals`
  option, or else by its comment.
  """
  @spec authorized?(Path.t(), String.t() | charlist(), term()) :: boolean()
  def authorized?(path, user, key) do
    case File.read(path) do
      {:ok, contents} ->
        Enum.any?(:ssh_file.decode(contents, :auth_keys), fn {listed, attrs} ->
          listed == key and to_string(user) in names(attrs)
        end)

      {:error, _reason} ->
        false
    end
  end

  # The decoder splits a key's options at every comma, quoted or not.
  defp names(attrs) do
    options = attrs |> Keyword.get(:options, []) |> Enum.map_join(",", &to_string/1)

    case Regex.run(~r/(?:^|,)principals="([^"]*)"/, options) do
      [_option, names] -> String.split(names, ",", trim: true)
      nil -> commented(attrs |> Keyword.get(:comment, "") |> to_string())
    end
  end

  defp commented(comment) do
    case String.split(comment, "@") do
      ["" | _host] -> []
      [name | _host] -> [name]
    end
  end

  # The key is written inside a directory only this user can enter, and moved
  # into place whole once it is.
  defp host_key!(dir) do
    path = Path.join(dir, @host_key)
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)

    unless File.exists?(path) do
      key = :public_key.generate_key({:rsa, 3072, 65_537})
      written = path <> ".new"

      File.write!(
        written,
        :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
      )

      File.chmod!(written, 0o600)
      File.rename!(written, path)
      Logger.info("Generated an SSH host key at #{path}")
    end

    File.chmod!(path, 0o600)
    dir
  end
end
