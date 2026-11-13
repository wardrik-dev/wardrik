defmodule WardrikDaemon.AgentFile do
  @moduledoc """
  Reads an agent file from `agents/`. The frontmatter is the definition; the body is the instructions.

      ---
      description: Watches the incident queue and says what needs an engineer.
      model: anthropic:claude-sonnet-5
      tools: [linear/*]
      policy: careful
      ---
      You watch the incident queue. Summarise anything new.

    * The file name is the agent's name: `agents/triage.md` is `triage`. A name is unique in its org.
    * `org` - the deployment's `org`, or one in `config.yaml`'s `orgs`. The owner's org unless set.
    * `owner` - its org, or a person in it, as `"@jon"` or `acme/@jon`. Its org unless set.
    * Every other key is part of the `Wardrik.Definition`. Missing keys come from `defaults`.
  """

  alias WardrikDaemon.AgentRecords
  alias WardrikDaemon.Config
  alias WardrikDaemon.Owners

  @typedoc "Whose agent a file declares, and its name."
  @type agent() :: %{org: String.t(), owner: String.t(), name: String.t()}

  @doc """
  Reads the file at `path`. Returns its owner, name and definition, with `defaults` filled in.
  """
  @spec read(Path.t(), Config.t()) :: {:ok, agent(), map()} | {:error, String.t()}
  def read(path, %Config{} = config) do
    with {:ok, text} <- File.read(path),
         {:ok, fields, body} <- split(text),
         {:ok, agent} <- agent(path, fields, config) do
      {:ok, agent, definition(fields, body, config.defaults)}
    else
      {:error, reason} when is_atom(reason) -> {:error, to_string(:file.format_error(reason))}
      {:error, why} -> {:error, why}
    end
  end

  defp split("---" <> rest) do
    with [front, body] <- String.split(rest, ~r/\n---[ \t]*(\n|\z)/, parts: 2),
         {:ok, fields} when is_map(fields) <- YamlElixir.read_from_string(front) do
      {:ok, fields, String.trim(body)}
    else
      [_unclosed] -> {:error, "opens its frontmatter with --- and never closes it"}
      {:ok, _other} -> {:error, "has frontmatter that isn't a set of keys"}
      {:error, error} -> {:error, "has frontmatter that isn't YAML: #{Exception.message(error)}"}
    end
  end

  defp split(text), do: {:ok, %{}, String.trim(text)}

  defp agent(path, fields, config) do
    name =
      path
      |> Path.basename()
      |> Path.rootname()

    org = fields["org"] || org(fields["owner"], config.org)
    owner = owner(fields["owner"], org)

    with :ok <- unnamed(fields),
         :ok <- named(name),
         :ok <- declared(org, config),
         :ok <- owned(owner, org, fields["owner"]),
         do: {:ok, %{org: org, owner: owner, name: name}}
  end

  defp unnamed(fields) do
    if Map.has_key?(fields, "name") or Map.has_key?(fields, "user"),
      do:
        {:error,
         "names its agent with name or user; the file's name is its name, and owner says whose"},
      else: :ok
  end

  defp named(name) do
    if AgentRecords.name?(name),
      do: :ok,
      else: {:error, "isn't named as an agent is: letters, digits, _, . and -, at most 64"}
  end

  defp declared(org, config) do
    orgs = Map.delete(config.orgs, "*")

    if org == config.org or Map.has_key?(orgs, org),
      do: :ok,
      else: {:error, "is in the org #{inspect(org)}, which config.yaml doesn't declare"}
  end

  defp owned(owner, org, given) do
    if is_binary(owner) and Owners.valid?(owner) and Owners.within?(owner, org),
      do: :ok,
      else:
        {:error,
         "is owned by #{inspect(given)}: give its org, #{org}, or a person in it, as #{org}/@jon"}
  end

  # An owner a file names holds its org, unless it's a person in the file's own.
  defp org(owner, default) when is_binary(owner) do
    if String.starts_with?(owner, "@"), do: default, else: Owners.org(owner)
  end

  defp org(_owner, default), do: default

  defp owner(nil, org), do: org
  defp owner("@" <> person, org), do: Owners.person(org, person)
  defp owner(owner, _org), do: owner

  defp definition(fields, body, defaults) do
    defaults
    |> Map.merge(Map.drop(fields, ~w(org owner)))
    |> instructions(body)
  end

  defp instructions(definition, ""), do: definition
  defp instructions(definition, body), do: Map.put(definition, "instructions", body)
end
