defmodule WardrikDaemon.Setup.Machine do
  @moduledoc """
  What setup steps read: the environment `wardrik init` runs in, and Wardrik's directories.
  """

  import Bitwise

  alias WardrikDaemon.Dirs

  @enforce_keys [:env, :dirs]
  defstruct @enforce_keys

  @type t() :: %__MODULE__{env: %{String.t() => String.t()}, dirs: Dirs.t()}

  @doc "Returns the machine `env` and `dirs` describe."
  @spec new(%{String.t() => String.t()}, Dirs.t()) :: t()
  def new(env, %Dirs{} = dirs), do: %__MODULE__{env: env, dirs: dirs}

  @doc "Returns the path of the executable `name` on the environment's `PATH`, or `nil`."
  @spec executable(t(), String.t()) :: Path.t() | nil
  def executable(%__MODULE__{env: env}, name) do
    env
    |> Map.get("PATH", "")
    |> String.split(":", trim: true)
    |> Enum.map(&Path.join(&1, name))
    |> Enum.find(&executable?/1)
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> (mode &&& 0o111) != 0
      _missing -> false
    end
  end

  @doc "Returns `path` in the home directory, as `~/.claude`."
  @spec home(t(), Path.t()) :: Path.t()
  def home(%__MODULE__{env: env}, path), do: Path.join(Map.get(env, "HOME", "/"), path)

  @doc "Returns `config.yaml` as written, with `${NAME}`s unfilled. `%{}` without one."
  @spec config(t()) :: map()
  def config(%__MODULE__{dirs: dirs}) do
    case YamlElixir.read_from_file(Dirs.config(dirs, "config.yaml")) do
      {:ok, %{} = config} -> config
      _none -> %{}
    end
  end
end
