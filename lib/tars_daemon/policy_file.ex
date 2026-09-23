defmodule TarsDaemon.PolicyFile do
  @moduledoc """
  Reads a policy file, one in `policies/` under the config directory, into the
  `TarsPolicy` it writes. The file's name is the policy's: `policies/careful.yaml`
  is `careful`, and an agent file names it as `policy: careful`.

      allow: [web_search, linear/*]
      ask:
        github/create_*: This opens an issue on GitHub.
      deny: [run_lua]
      default: allow

  See `TarsPolicy` for what the rules say.
  """

  @doc "Reads the policy `path` writes."
  @spec read(Path.t()) :: {:ok, TarsPolicy.t()} | {:error, String.t()}
  def read(path) do
    name = path |> Path.basename() |> Path.rootname()

    with {:ok, text} <- File.read(path),
         {:ok, fields} <- yaml(text),
         {:ok, policy} <- TarsPolicy.decode(fields, name) do
      {:ok, policy}
    else
      {:error, reason} when is_atom(reason) -> {:error, "#{path}: #{:file.format_error(reason)}"}
      {:error, message} -> {:error, "#{path}: #{message}"}
    end
  end

  defp yaml(text) do
    case YamlElixir.read_from_string(text) do
      {:ok, nil} -> {:ok, %{}}
      {:ok, fields} -> {:ok, fields}
      {:error, error} -> {:error, "is not YAML: #{Exception.message(error)}"}
    end
  end
end
