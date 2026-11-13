defmodule WardrikDaemon.Dirs do
  @moduledoc """
  The directories the daemon uses. Each environment variable moves one.

  | Variable | Default | Holds |
  | --- | --- | --- |
  | `WARDRIK_CONFIG_DIR` | `~/.config/wardrik` | `config.yaml`, `agents/`, `policies/` |
  | `WARDRIK_DATA_DIR` | `~/.local/share/wardrik/store` | the store |
  | `WARDRIK_DATA_HOME` | `~/.local/share/wardrik` | `vault_key`, `cli_token` |
  | `WARDRIK_STATE_DIR` | `~/.local/state/wardrik` | logs |
  | `WARDRIK_ENV_FILE` | `env` in the config directory | extra environment variables |

  The defaults follow `XDG_CONFIG_HOME`, `XDG_DATA_HOME` and `XDG_STATE_HOME`.
  """

  @enforce_keys [:config, :data, :data_home, :state, :env_file]
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          config: Path.t(),
          data: Path.t(),
          data_home: Path.t(),
          state: Path.t(),
          env_file: Path.t()
        }

  @doc "Returns the directories `env`, a map of environment variables, names."
  @spec new(%{String.t() => String.t()}) :: t()
  def new(env) do
    config = env["WARDRIK_CONFIG_DIR"] || wardrik(env, "XDG_CONFIG_HOME", ".config")
    data_home = env["WARDRIK_DATA_HOME"] || wardrik(env, "XDG_DATA_HOME", ".local/share")

    %__MODULE__{
      config: config,
      data: env["WARDRIK_DATA_DIR"] || Path.join(data_home, "store"),
      data_home: data_home,
      state: env["WARDRIK_STATE_DIR"] || wardrik(env, "XDG_STATE_HOME", ".local/state"),
      env_file: env["WARDRIK_ENV_FILE"] || Path.join(config, "env")
    }
  end

  @doc "Returns the path of `name` in the config directory, as `agents` or `config.yaml`."
  @spec config(t(), String.t()) :: Path.t()
  def config(%__MODULE__{config: config}, name), do: Path.join(config, name)

  @doc "Returns the path of `name` in the data home, as `cli_token`."
  @spec data_home(t(), String.t()) :: Path.t()
  def data_home(%__MODULE__{data_home: data_home}, name), do: Path.join(data_home, name)

  defp wardrik(env, variable, fallback) do
    env
    |> xdg(variable, fallback)
    |> Path.join("wardrik")
  end

  defp xdg(env, variable, fallback),
    do: env[variable] || Path.join(env["HOME"] || System.user_home!(), fallback)
end
