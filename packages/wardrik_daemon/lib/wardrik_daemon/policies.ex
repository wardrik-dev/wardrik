defmodule WardrikDaemon.Policies do
  @moduledoc """
  Reads the policies in `policies/`. `policies/careful.yaml` is `policy: careful`.

      allow: [web_search, linear/*]
      ask:
        github/create_*: This opens an issue on GitHub.
      deny: [shell/*]
      budget: {usd: 5.00, per: day}

  See `Wardrik.Policy`. An empty file doesn't read; write `default: allow` to allow every call.
  """

  @doc "Returns each policy in `dir` by name, or the reason one doesn't read. A missing directory holds none."
  @spec read(Path.t()) :: {:ok, %{String.t() => Wardrik.Policy.t()}} | {:error, String.t()}
  def read(dir) do
    read =
      for path <- Path.wildcard(Path.join(dir, "*.{yaml,yml}")),
          do: {Path.rootname(Path.basename(path)), policy(path)}

    case Enum.find(read, &match?({_name, {:error, _why}}, &1)) do
      nil -> {:ok, Map.new(read, fn {name, {:ok, policy}} -> {name, policy} end)}
      {_name, {:error, why}} -> {:error, why}
    end
  end

  defp policy(path) do
    name = Path.rootname(Path.basename(path))

    with {:ok, fields} <- fields(path),
         {:ok, policy} <- Wardrik.Policy.decode(fields, name: name) do
      {:ok, policy}
    else
      {:error, why} -> {:error, "#{path}: #{why}"}
    end
  end

  defp fields(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, fields} when is_map(fields) and map_size(fields) > 0 -> {:ok, fields}
      {:ok, _empty} -> {:error, "is empty; a policy that allows every call says default: allow"}
      {:error, error} -> {:error, "isn't YAML: #{Exception.message(error)}"}
    end
  end
end
