defmodule WardrikDaemon.PolicyFile do
  @moduledoc """
  Reads a policy file, one in `policies/` under the config directory, into the
  `WardrikPolicy` it writes. The file's name is the policy's: `policies/careful.yaml`,
  or `policies/careful.yml`, is `careful`, and an agent file names it as
  `policy: careful`.

      allow: [web_search, linear/*]
      ask:
        github/create_*: This opens an issue on GitHub.
      deny: [shell/*]
      default: allow
      budget:
        usd: 5.00
        per: day

  See `WardrikPolicy` for what the rules say, and `WardrikPolicy.Budget` for the
  budget. A file that says nothing is refused: a policy that allows every call
  says `default: allow`.
  """

  @empty "is empty; a policy that allows every call says default: allow"

  @doc "Reads the policy `path` writes."
  @spec read(Path.t()) :: {:ok, WardrikPolicy.t()} | {:error, String.t()}
  def read(path) do
    name = path |> Path.basename() |> Path.rootname()

    with {:ok, text} <- File.read(path),
         {:ok, fields} <- yaml(text),
         {:ok, policy} <- WardrikPolicy.decode(fields, name) do
      {:ok, policy}
    else
      {:error, reason} when is_atom(reason) -> {:error, "#{path}: #{:file.format_error(reason)}"}
      {:error, message} -> {:error, "#{path}: #{message}"}
    end
  end

  defp yaml(text) do
    case YamlElixir.read_from_string(text) do
      {:ok, fields} when fields in [nil, %{}] -> {:error, @empty}
      {:ok, fields} -> {:ok, fields}
      {:error, error} -> {:error, "is not YAML: #{Exception.message(error)}"}
    end
  end
end
