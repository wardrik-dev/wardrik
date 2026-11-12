defmodule WardrikDaemon.CLI.Occupant do
  @moduledoc false

  # A Wardrik node already running on this machine under the node name a new daemon would take,
  # and what to tell someone about it.

  @enforce_keys [:pid, :root, :env]
  defstruct @enforce_keys ++ [service?: false]

  @type t() :: %__MODULE__{
          pid: String.t(),
          root: String.t(),
          env: %{String.t() => String.t()},
          service?: boolean()
        }

  # The variables that move a daemon's config, keys and store, and so the CLI that reaches it.
  @moved ~w(HOME XDG_CONFIG_HOME XDG_DATA_HOME WARDRIK_CONFIG_DIR WARDRIK_DATA_HOME
            WARDRIK_DATA_DIR WARDRIK_ENV_FILE)

  @doc "Returns the node running here under `RELEASE_NODE`'s name in `env`, if there is one."
  @spec find(%{String.t() => String.t()}) :: t() | nil
  def find(env) do
    if System.find_executable("ps") do
      {ps, 0} = System.cmd("ps", ["-eo", "pid=,args="])

      with {pid, root} <- running(ps, Map.get(env, "RELEASE_NODE", "wardrik@localhost")),
           do: %__MODULE__{pid: pid, root: root, env: environ(pid), service?: service?(pid)}
    end
  end

  # Whether it's the systemd user service `wardrik service install` made.
  defp service?(pid) do
    System.find_executable("systemctl") != nil and
      match?(
        {^pid, 0},
        "systemctl"
        |> System.cmd(~w(--user show --property MainPID --value wardrik), stderr_to_stdout: true)
        |> then(fn {out, status} -> {String.trim(out), status} end)
      )
  end

  @doc "Returns the pid and release root of the node named `node` in `ps`'s output."
  @spec running(String.t(), String.t()) :: {String.t(), String.t()} | nil
  def running(ps, node) do
    named = ~r/\s-s?name #{Regex.escape(node)}(\s|$)/

    ps
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      with true <- line =~ "beam" and line =~ named,
           [_line, pid, root] <- Regex.run(~r/^\s*(\d+)\s.*\s-root (\S+)/, line),
           do: {pid, root},
           else: (_other -> nil)
    end)
  end

  # Where there's no /proc, as on macOS, its environment is unknown.
  defp environ(pid) do
    case File.read("/proc/#{pid}/environ") do
      {:ok, environ} -> parsed(environ)
      {:error, _unreadable} -> %{}
    end
  end

  @doc "Returns the variables of an environment as `/proc/PID/environ` holds them."
  @spec parsed(binary()) :: %{String.t() => String.t()}
  def parsed(environ) do
    for pair <- String.split(environ, <<0>>, trim: true),
        [name, value] <- [String.split(pair, "=", parts: 2)],
        into: %{},
        do: {name, value}
  end

  @doc """
  Returns what to tell someone about `occupant`, for the CLI run with `env` as `program`.
  `reachable?` is whether that CLI reaches it.
  """
  @spec told(t(), %{String.t() => String.t()}, String.t(), boolean()) :: String.t()
  def told(occupant, env, program, reachable?) do
    """
    Another Wardrik service is running here, from #{occupant.root} (pid #{occupant.pid}).
      Use it:      #{use(occupant, env, program, reachable?)}
      Replace it:  #{replace(occupant, program, reachable?)}, then #{program} init again\
    """
  end

  defp use(_occupant, _env, program, true), do: "#{program} status. It read what init wrote."

  defp use(%{env: started}, _env, program, false) when started == %{},
    do: "#{program} status, with the environment it was started with"

  defp use(occupant, env, program, false) do
    moved =
      for name <- @moved,
          value <- [occupant.env[name]],
          value not in [nil, env[name]],
          do: "#{name}=#{quoted(value)} "

    "#{moved}#{program} status"
  end

  defp quoted(value) do
    if value =~ ~r"^[\w@%+=:,./-]+$",
      do: value,
      else: "'" <> String.replace(value, "'", ~S('\'')) <> "'"
  end

  defp replace(%{service?: true}, _program, _reachable?),
    do: "systemctl --user stop wardrik"

  defp replace(_occupant, program, true), do: "#{program} stop"
  defp replace(occupant, _program, false), do: "kill #{occupant.pid}"
end
