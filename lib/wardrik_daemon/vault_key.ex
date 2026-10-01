defmodule WardrikDaemon.VaultKey do
  @moduledoc """
  The vault's key where nothing else gives it one: `vault_key` in the data
  home, `~/.local/share/wardrik/vault_key`, or `/data/vault_key` in the Docker
  image, readable by the daemon's user alone.

  `vault.keys` in `config.yaml`, and `WARDRIK_VAULT_KEY`, come first: the file
  is read only where neither names a key. The daemon reads it as it starts,
  into `WardrikVault`'s settings and never into its environment, so no command
  an MCP server runs can inherit it.

  Nothing makes it as the daemon boots. `wardrik vault put` asks to, the first
  time it finds the vault with no key, and every node it reaches reads it
  then, with no restart. The nodes of a cluster on one machine share the data
  home, and so the key; a node on another host needs a copy, as it needs the
  cookie, or `vault.keys`.

  The file sits beside the store, so anyone who can read both can read the
  secrets. A deployment that keeps them apart gives the vault a key of its own.
  """

  alias WardrikDaemon.Config

  @doc "Where the key is kept, in the data home `data_dir`."
  @spec file(Path.t()) :: Path.t()
  def file(data_dir \\ Config.data_dir()), do: Path.join(data_dir, "vault_key")

  @doc """
  Gives the vault the key in `data_dir`'s file, where nothing else gave it one:
  `:ok` where the vault has a key now, `:none` where the file is not there,
  and why where it holds no key the vault can use.

  The file is made readable by its owner alone each time it is read, as the
  cookie is.
  """
  @spec load(Path.t()) :: :ok | :none | {:error, String.t()}
  def load(data_dir \\ Config.data_dir()) do
    if WardrikVault.Config.configured?() do
      :ok
    else
      with {:ok, key} <- read(file(data_dir)) do
        settings = Application.get_env(:wardrik, WardrikVault, [])
        Application.put_env(:wardrik, WardrikVault, Keyword.put(settings, :keys, [key]))
      end
    end
  end

  @doc """
  Makes a key in `data_dir`'s file, unless one is there, and answers the file.

  Two nodes making one at once agree on it: each writes a file of its own and
  links it into place, which only the first manages, and both read that one.
  """
  @spec make(Path.t()) :: {:ok, Path.t()} | {:error, String.t()}
  def make(data_dir \\ Config.data_dir()) do
    path = file(data_dir)

    with :none <- read(path),
         :ok <- write(path, WardrikVault.generate_key()),
         :none <- read(path) do
      {:error, "#{path} could not be linked into place"}
    else
      {:ok, _key} -> {:ok, path}
      {:error, message} -> {:error, message}
    end
  end

  @doc "The key in `path`, `:none` where there is no file, and why where it holds none."
  @spec read(Path.t()) :: {:ok, String.t()} | :none | {:error, String.t()}
  def read(path) do
    case File.read(path) do
      {:ok, text} ->
        _ = File.chmod(path, 0o600)
        key = String.trim(text)

        if WardrikVault.key?(key),
          do: {:ok, key},
          else:
            {:error,
             "#{path} holds no key the vault can use: 32 bytes in base64, as openssl rand -base64 32 makes"}

      {:error, :enoent} ->
        :none

      {:error, reason} ->
        {:error, "#{path}: #{:file.format_error(reason)}"}
    end
  end

  defp write(path, key) do
    fresh = "#{path}.#{System.pid()}.#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(fresh, "", [:exclusive]),
         :ok <- File.chmod(fresh, 0o600),
         :ok <- File.write(fresh, key <> "\n") do
      # Refused where another node linked its key first, which is the one read.
      _ = File.ln(fresh, path)
      _ = File.rm(fresh)
      :ok
    else
      {:error, reason} -> {:error, "#{path} could not be written: #{:file.format_error(reason)}"}
    end
  end
end
