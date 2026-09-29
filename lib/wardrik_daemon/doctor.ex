defmodule WardrikDaemon.Doctor do
  @moduledoc """
  What `wardrik doctor` checks: that `config.yaml` reads, and that the store
  it names is there and keeps the store's contract, as `Wardrik.Store.check/1`
  looks at it. `bin/wardrik` runs it on a VM of its own, so it checks a daemon
  that does not start as well as one that runs.

      $ wardrik doctor
      ok    config  /home/me/.config/wardrik/config.yaml reads
      FAIL  store   the bucket wardrik at https://acct.r2.cloudflarestorage.com: the bucket answered 403 AccessDenied

  It exits with status 1 where a check fails.
  """

  alias WardrikDaemon.Config

  @typedoc "One check: whether it passed, what it looked at, and what it found."
  @type check() :: {:ok | :error, String.t(), String.t()}

  @doc "Runs the checks on the config directory, prints them, and stops the VM."
  @spec main() :: no_return()
  def main do
    :logger.set_primary_config(:level, :none)
    {:ok, _started} = Application.ensure_all_started([:req, :postgrex])
    checks = checks(Config.config_dir())
    IO.puts(report(checks))
    System.halt(if Enum.all?(checks, &(elem(&1, 0) == :ok)), do: 0, else: 1)
  end

  @doc "The checks, in order. A `config.yaml` that does not read is the only one."
  @spec checks(Path.t()) :: [check()]
  def checks(config_dir) do
    with {:ok, file} <- Config.file(config_dir),
         {:ok, settings} <- Config.read(file) do
      [{:ok, "config", "#{file} reads"}, store(settings)]
    else
      {:error, message} -> [{:error, "config", message}]
    end
  end

  defp store(settings) do
    {result, found} =
      settings |> Config.boot() |> Keyword.get(Wardrik.Store, []) |> Wardrik.Store.check()

    {result, "store", found}
  end

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
