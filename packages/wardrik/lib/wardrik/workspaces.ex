defmodule Wardrik.Workspaces do
  @moduledoc """
  Gives agents files: their own workspace, other agents', and files read into every turn.

      tools: [files]
      context: [MEMORY.md, shared/runbooks/deploy.md]
      workspace:
        shared:
          runbooks: agt_runbooks
          notes: {agent: agt_notes, mode: read}

  Your resolver shares workspaces:

      %Wardrik.Resolved{workspaces: %{"agt_runbooks" => :write, "agt_notes" => :read}}

    * `files` in `tools` adds the file tools.
    * `context` lists up to 20 files, or `{files: [...], max_bytes: 16384}`.
    * `mode: read` mounts a write share read only.
    * An agent's conversations share its workspace.
  """

  alias Wardrik.Error
  alias Wardrik.Workspace.Mount

  @max_files 20
  @bytes 1_024..262_144

  @doc """
  Returns the capabilities and middleware for `:agent`'s workspace, or `invalid_request`.

      Wardrik.Workspaces.resolve(wardrik,
        agent: "agt_triage",
        definition: definition,
        workspaces: %{"agt_runbooks" => :read},
        files: true
      )
  """
  @spec resolve(Wardrik.t(),
          agent: String.t(),
          definition: map(),
          workspaces: %{String.t() => :read | :write},
          files: boolean()
        ) :: {:ok, [capabilities: list(), middleware: list()]} | {:error, Error.t()}
  def resolve(wardrik, args) do
    id = Keyword.fetch!(args, :agent)
    definition = Keyword.fetch!(args, :definition)
    files? = Keyword.fetch!(args, :files)
    shares = Keyword.fetch!(args, :workspaces)

    with {:ok, shared} <- shared(id, shares, get_in(definition, ["workspace", "shared"]) || %{}),
         {:ok, context} <- context(definition["context"]) do
      base = [store: wardrik.store, tree: tree(id), shared: shared]

      {:ok,
       [
         capabilities: if(files?, do: [{Wardrik.Workspace, base}], else: []),
         middleware: if(context, do: [{Wardrik.Workspace.Context, base ++ context}], else: [])
       ]}
    end
  end

  @doc """
  Returns the agent `id`'s own tree, `agents/<URL-encoded id>`.
  """
  @spec tree(String.t()) :: String.t()
  def tree(id), do: "agents/" <> URI.encode_www_form(id)

  defp shared(id, shares, shared) do
    mounts = Enum.map(shared, fn {name, mount} -> mount(id, shares, name, mount) end)

    case Enum.find(mounts, &match?({:error, _error}, &1)) do
      nil -> {:ok, Enum.map(mounts, fn {:ok, mount} -> mount end)}
      error -> error
    end
  end

  defp mount(id, shares, name, agent) when is_binary(agent),
    do: mount(id, shares, name, %{"agent" => agent})

  defp mount(id, shares, name, %{"agent" => agent} = mount) do
    with :ok <- named(name),
         {:ok, mode} <- access(id, Map.get(shares, agent), agent, mount["mode"]),
         do: {:ok, %Mount{name: name, tree: tree(agent), mode: mode}}
  end

  defp named(name) do
    if Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, name),
      do: :ok,
      else: invalid("A shared tree's name, #{inspect(name)}, is letters, digits, - and _.")
  end

  defp access(id, nil, agent, _mode),
    do: invalid("#{id} can't mount #{agent}'s workspace: its resolver doesn't share it.")

  defp access(id, :read, agent, "write"),
    do: invalid("#{id} can't write #{agent}'s workspace: its resolver shares it to read.")

  defp access(_id, _shared, _agent, "read"), do: {:ok, :read}
  defp access(_id, shared, _agent, _mode), do: {:ok, shared}

  defp context(nil), do: {:ok, nil}
  defp context(files) when is_list(files), do: context(%{"files" => files})

  defp context(%{"files" => files} = context) do
    bytes = Map.get(context, "max_bytes", 16_384)

    cond do
      length(files) > @max_files -> invalid("context names at most #{@max_files} files.")
      bytes not in @bytes -> invalid("context's max_bytes is from 1024 to 262144.")
      true -> {:ok, [files: files, max_bytes: bytes]}
    end
  end

  defp invalid(message), do: {:error, Error.new(:invalid_request, message)}
end
