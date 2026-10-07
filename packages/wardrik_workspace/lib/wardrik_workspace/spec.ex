defmodule WardrikWorkspace.Spec do
  @moduledoc """
  An agent's workspace: its own tree, and the trees it shares with other
  agents, as `WardrikWorkspace.Mount`s.

      {:ok, spec} = WardrikWorkspace.Spec.new(id, %{
        "team" => "acme",
        "runbooks" => %{"tree" => "acme/runbooks", "mode" => "read"}
      })

  The agent's own tree is `agents/<id>`, seen at the root of its paths. A
  shared tree is named like a prefix with a name after it, and is reachable by
  the agents under that prefix: `acme` and `acme/runbooks` by acme's agents,
  `acme/@jon/notes` by jon's. `new/2` refuses one the agent cannot reach, as
  `Wardrik.AgentID.Prefix.covers?/2` decides, and sees each at
  `shared/<name>`, so `shared/` at the root of a path is never the agent's
  own.

  `context/2` names files read into each turn, in its own tree or one it
  shares, and `context_bytes/2` how much of them may be, 16 KB unless it
  says; see `WardrikWorkspace.Context`.
  """

  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix
  alias WardrikWorkspace.Mount
  alias WardrikWorkspace.Path

  @context_bytes 16 * 1024
  @min_context_bytes 1024
  @max_context_bytes 256 * 1024

  @enforce_keys [:tree]
  defstruct [:tree, shared: [], context: [], context_bytes: @context_bytes]

  @type t() :: %__MODULE__{
          tree: Mount.t(),
          shared: [Mount.t()],
          context: [String.t()],
          context_bytes: pos_integer()
        }

  @name ~r/\A[a-z0-9][a-z0-9_-]*\z/
  @max_context 20

  @doc """
  The workspace of the agent `id`, sharing the trees `shared` names: a map
  of name to a tree, or to `%{"tree" => tree, "mode" => "read"}`.
  """
  @spec new(AgentID.t(), map()) :: {:ok, t()} | {:error, String.t()}
  def new(id, shared \\ %{})

  def new(%AgentID{} = id, shared) when is_map(shared) do
    shared
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn {name, tree}, {:ok, mounts} ->
      case mount(id, name, tree) do
        {:ok, mount} -> {:cont, {:ok, [mount | mounts]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
    |> case do
      {:ok, mounts} ->
        {:ok, %__MODULE__{tree: %Mount{tree: "agents/#{id}"}, shared: Enum.reverse(mounts)}}

      error ->
        error
    end
  end

  def new(_id, _shared), do: {:error, "shared is a map of names to trees"}

  defp mount(id, name, %{"tree" => tree} = settings) do
    with :ok <- known(name, settings),
         {:ok, mode} <- mode(name, Map.get(settings, "mode", "write")),
         {:ok, mount} <- mount(id, name, tree),
         do: {:ok, %{mount | mode: mode}}
  end

  defp mount(id, name, tree) when is_binary(name) and is_binary(tree) do
    with :ok <- name(name),
         {:ok, tree} <- tree(name, tree),
         :ok <- reaches(id, name, tree),
         do: {:ok, %Mount{name: name, tree: "shared/" <> tree}}
  end

  defp mount(_id, name, _tree),
    do: {:error, "shared #{inspect(name)} names a tree, or a tree and a mode"}

  defp known(name, settings) do
    case Map.keys(settings) -- ["tree", "mode"] do
      [] -> :ok
      [key | _] -> {:error, "shared #{name}: #{key} is not a setting; expected tree or mode"}
    end
  end

  defp mode(_name, "write"), do: {:ok, :write}
  defp mode(_name, "read"), do: {:ok, :read}
  defp mode(name, _mode), do: {:error, "shared #{name}: mode is read or write"}

  defp name(name) do
    if Regex.match?(@name, name),
      do: :ok,
      else:
        {:error,
         "shared #{inspect(name)} is not a name; a name is lowercase letters, digits, - and _"}
  end

  # A tree is named as an org is, or as an agent would be: `acme`,
  # `acme/runbooks` or `acme/@jon/notes`.
  defp tree(name, tree) do
    trimmed = String.trim_trailing(tree, "/")

    case {String.split(trimmed, "/"), AgentID.parse(trimmed)} do
      {[org], _id} ->
        if AgentID.segment?(org), do: {:ok, trimmed}, else: not_a_tree(name, tree)

      {_parts, {:ok, %AgentID{external_id: nil}}} ->
        {:ok, trimmed}

      {_parts, _not_a_name} ->
        not_a_tree(name, tree)
    end
  end

  defp not_a_tree(name, tree),
    do:
      {:error,
       "shared #{name}: #{inspect(tree)} is not a tree; a tree is org, org/name or org/@user/name"}

  # A tree is reachable by the agents under the prefix its name begins with.
  defp reaches(id, name, tree) do
    prefix =
      case String.split(tree, "/") do
        [org] -> Prefix.parse!(org)
        parts -> parts |> Enum.drop(-1) |> Enum.join("/") |> Prefix.parse!()
      end

    if Prefix.covers?(prefix, id),
      do: :ok,
      else: {:error, "shared #{name}: #{tree} belongs to #{prefix}, which #{id} is not under"}
  end

  @doc """
  The mount `path` falls in, and the path within it, or a message saying why
  it names no file this workspace has.
  """
  @spec resolve(t(), term()) :: {:ok, Mount.t(), String.t()} | {:error, String.t()}
  def resolve(%__MODULE__{} = spec, path) do
    with {:ok, path} <- Path.normalize(path) do
      case String.split(path, "/", parts: 3) do
        ["shared", name, rest] ->
          shared(spec, name, rest)

        ["shared" | _rest] ->
          {:error, "#{path} is not a file; the trees shared with you are under shared/<name>/"}

        _own ->
          {:ok, spec.tree, path}
      end
    end
  end

  defp shared(spec, name, rest) do
    case Enum.find(spec.shared, &(&1.name == name)) do
      %Mount{} = mount -> {:ok, mount, rest}
      nil -> {:error, "No tree is shared with you as shared/#{name}#{names(spec)}"}
    end
  end

  defp names(%__MODULE__{shared: []}), do: ""

  defp names(%__MODULE__{shared: shared}),
    do: "; the trees shared with you are " <> Enum.map_join(shared, ", ", &"shared/#{&1.name}")

  @doc """
  The workspace, with the files `paths` names read into each turn, in the
  order named: paths in the agent's own tree, or under `shared/<name>/` in a
  tree it shares. At most #{@max_context}.
  """
  @spec context(t(), term()) :: {:ok, t()} | {:error, String.t()}
  def context(%__MODULE__{} = spec, paths) when is_list(paths) do
    if Enum.count_until(paths, @max_context + 1) > @max_context,
      do: {:error, "context names at most #{@max_context} files"},
      else: named(spec, paths)
  end

  def context(%__MODULE__{}, _paths), do: {:error, "context is a list of files"}

  defp named(spec, paths) do
    resolved = Enum.map(paths, &resolve(spec, &1))

    case Enum.find(resolved, &match?({:error, _message}, &1)) do
      {:error, message} -> {:error, "context: " <> message}
      nil -> {:ok, %{spec | context: resolved |> Enum.map(&written/1) |> Enum.uniq()}}
    end
  end

  # A path as the agent sees it, however it was written.
  defp written({:ok, mount, rest}), do: Mount.root(mount) <> rest

  @doc """
  The workspace, reading at most `bytes` of the files `context/2` names into
  each turn, from #{@min_context_bytes} to #{@max_context_bytes}.
  """
  @spec context_bytes(t(), term()) :: {:ok, t()} | {:error, String.t()}
  def context_bytes(%__MODULE__{} = spec, bytes)
      when is_integer(bytes) and bytes in @min_context_bytes..@max_context_bytes,
      do: {:ok, %{spec | context_bytes: bytes}}

  def context_bytes(%__MODULE__{}, _bytes),
    do:
      {:error,
       "context max_bytes is a number of bytes from #{@min_context_bytes} to #{@max_context_bytes}"}

  @doc "Every mount of the workspace: the agent's own, then those it shares."
  @spec mounts(t()) :: [Mount.t()]
  def mounts(%__MODULE__{tree: tree, shared: shared}), do: [tree | shared]
end
