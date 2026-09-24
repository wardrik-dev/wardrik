defmodule TarsDaemon.SSH do
  @moduledoc """
  Serves the TUI over SSH, once the config directory holds keys to let in.

  With an `ssh/authorized_keys` file in the config directory, in OpenSSH's
  format, the daemon listens on port 2222 on loopback, and a client holding any
  key in the file may connect, under any user name:

      ssh -p 2222 jon@localhost

  Each connection is a `TarsTUI.SSH` session, and the name is who it is for.
  The file is read at every login, so a key added or removed counts from the
  next connection on, with no restart. The host key is generated the first time
  the daemon listens, in `ssh/` under the data directory, and kept; the
  directory and the key are this user's alone, however they were left.

  `config.yaml` moves it:

      ssh:
        port: 2222
        ip: 0.0.0.0     # every interface; loopback unless set

  A listener that cannot listen, on a port another process holds, logs why and
  leaves the daemon running without it.
  """

  require Logger

  @host_key "ssh_host_rsa_key"

  @doc """
  The listener for a daemon whose config lives in `config_dir` and whose data
  lives in `data_dir`, or none where `config_dir` holds no `ssh/authorized_keys`.
  """
  @spec children(Path.t(), Path.t()) :: [{module(), keyword()}]
  def children(config_dir, data_dir) do
    keys = Path.join([config_dir, "ssh", "authorized_keys"])

    if File.exists?(keys) do
      settings = Application.get_env(:tars, __MODULE__, [])
      system_dir = host_key!(Path.join(data_dir, "ssh"))

      [
        {__MODULE__,
         name: __MODULE__,
         port: Keyword.get(settings, :port, 2222),
         ip: Keyword.get(settings, :ip, {127, 0, 0, 1}),
         auth: {:public_key, fn _user, key -> authorized?(keys, key) end},
         system_dir: system_dir,
         entrypoint: {TarsTUI.SSH, []}}
      ]
    else
      []
    end
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  @doc "Starts the listener `Termite.SSH` runs, or `:ignore` where it cannot listen."
  @spec start_link(keyword()) :: GenServer.on_start() | :ignore
  def start_link(opts) do
    case Termite.SSH.start_link(opts) do
      {:error, reason} ->
        Logger.error(
          "SSH is not served: port #{opts[:port]} on #{:inet.ntoa(opts[:ip])} could not be " <>
            "listened on: #{inspect(reason)}"
        )

        :ignore

      started ->
        started
    end
  end

  @doc "Whether `key` is among those the OpenSSH `authorized_keys` file at `path` lists."
  @spec authorized?(Path.t(), term()) :: boolean()
  def authorized?(path, key) do
    case File.read(path) do
      {:ok, contents} ->
        Enum.any?(:ssh_file.decode(contents, :auth_keys), fn {listed, _attrs} -> listed == key end)

      {:error, _reason} ->
        false
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
