defmodule WardrikWorkspace.Spec do
  @moduledoc """
  An agent's workspace: its own tree, and the trees it shares with other
  agents, as `WardrikWorkspace.Mount`s.

      {:ok, spec} = WardrikWorkspace.Spec.new(id, %{
        "team" => "acme",
        "runbooks" => %{"tree" => "acme/runbooks", "mode" => "read"}
      })

  The agent's own tree is `agents/` and its resource name, as
  `agents/acme/@jon/agent/triage`, seen at the root of its paths. A
  shared tree is named by its owner, an org or a user in it, with a name
  after it, and is reachable by the owner's agents, `<owner>/agent/*`:
  `acme` and `acme/runbooks` by acme's own agents, none of its users', and
  `acme/@jon/notes` by jon's. Others mount it where the deployment shares
  it with them, by the `WardrikWorkspace.Share`s `new/3` is handed: to
  read, or to read and change. `new/3` refuses a tree the agent can reach
  neither way, as `Wardrik.Resource.covers?/2` decides, and sees each at
  `shared/<name>`, so `shared/` at the root of a path is never the agent's
  own.

  `context/2` names files read into each turn, in its own tree or one it
  shares, and `context_bytes/2` how much of them may be, 16 KB unless it
  says; see `WardrikWorkspace.Context`.
  """

  alias Wardrik.AgentID
  alias Wardrik.Resource
  alias WardrikWorkspace.Mount
  alias WardrikWorkspace.Path
  alias WardrikWorkspace.Share

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
  of name to a tree, or to `%{"tree" => tree, "mode" => "read"}`. A tree
  another owns is mounted where one of `:shares`, the deployment's
  `WardrikWorkspace.Share`s, lets the agent, in the mode it lets it.
  """
  @spec new(AgentID.t(), map(), shares: [Share.t()]) :: {:ok, t()} | {:error, String.t()}
  def new(id, shared \\ %{}, opts \\ [])

  def new(%AgentID{} = id, shared, opts) when is_map(shared) do
    shares = Keyword.get(Keyword.validate!(opts, shares: []), :shares)

    shared
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn {name, tree}, {:ok, mounts} ->
      case mount(id, name, tree, shares) do
        {:ok, mount} -> {:cont, {:ok, [mount | mounts]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
    |> case do
      {:ok, mounts} ->
        {:ok, %__MODULE__{tree: own(id), shared: Enum.reverse(mounts)}}

      error ->
        error
    end
  end

  def new(_id, _shared, _opts), do: {:error, "shared is a map of names to trees"}

  defp own(id), do: %Mount{tree: "agents/#{AgentID.resource(id)}"}

  defp mount(id, name, %{"tree" => tree} = settings, shares) do
    with :ok <- known(name, settings),
         {:ok, mode} <- mode(name, Map.get(settings, "mode", "write")),
         do: mount(id, name, tree, mode, shares)
  end

  defp mount(id, name, tree, shares) when is_binary(tree),
    do: mount(id, name, tree, :write, shares)

  defp mount(_id, name, _tree, _shares),
    do: {:error, "shared #{inspect(name)} names a tree, or a tree and a mode"}

  defp mount(id, name, tree, mode, shares) when is_binary(name) and is_binary(tree) do
    with :ok <- name(name),
         {:ok, tree} <- tree("shared " <> name, tree),
         :ok <- reaches(id, name, tree, mode, shares),
         do: {:ok, %Mount{name: name, tree: "shared/" <> tree, mode: mode}}
  end

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

  @doc false
  # A tree is named as an org is, or as an agent would be: `acme`,
  # `acme/runbooks` or `acme/@jon/notes`. `what` names it in a message.
  @spec tree(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def tree(what, tree) do
    trimmed = String.trim_trailing(tree, "/")

    case {String.split(trimmed, "/"), AgentID.parse(trimmed)} do
      {[org], _id} ->
        if AgentID.segment?(org), do: {:ok, trimmed}, else: not_a_tree(what, tree)

      {_parts, {:ok, %AgentID{external_id: nil}}} ->
        {:ok, trimmed}

      {_parts, _not_a_name} ->
        not_a_tree(what, tree)
    end
  end

  defp not_a_tree(what, tree),
    do:
      {:error,
       "#{what}: #{inspect(tree)} is not a tree; a tree is org, org/name or org/@user/name"}

  # The tree's owner's agents mount it as they ask; another agent as a share
  # lets it.
  defp reaches(id, name, tree, mode, shares) do
    owners = owners(tree)
    shared = Share.mode(shares, tree, id)

    cond do
      Resource.covers?(owners, AgentID.resource(id)) -> :ok
      allowed?(shared, mode) -> :ok
      shared == {:ok, :read} -> read_only(name, tree, id)
      true -> {:error, "shared #{name}: #{tree} belongs to #{owners}, which does not cover #{id}"}
    end
  end

  defp allowed?({:ok, :write}, _mode), do: true
  defp allowed?({:ok, :read}, :read), do: true
  defp allowed?(_shared, _mode), do: false

  defp read_only(name, tree, id),
    do: {:error, "shared #{name}: #{tree} is shared with #{id} to read; mount it with mode: read"}

  # A tree is reachable by the agents of the owner its name begins with.
  defp owners(tree) do
    owner =
      case String.split(tree, "/") do
        [org] -> org
        parts -> parts |> Enum.drop(-1) |> Enum.join("/")
      end

    Resource.parse!(owner <> "/agent/*")
  end

  @doc """
  `:ok` where every tree `spec` shares belongs to agents `token` reaches,
  or is one `:shares` lets the agent `:id` mount as it does, or a message
  naming one that is neither: what a definition sent with `token` may
  share.
  """
  @spec within(t(), Wardrik.Token.t(), id: AgentID.t(), shares: [Share.t()]) ::
          :ok | {:error, String.t()}
  def within(%__MODULE__{shared: shared}, token, opts) do
    opts = Keyword.validate!(opts, [:id, shares: []])
    {id, shares} = {Keyword.fetch!(opts, :id), opts[:shares]}

    Enum.find_value(shared, :ok, fn %Mount{name: name, tree: "shared/" <> tree, mode: mode} ->
      owners = owners(tree)

      if not (Wardrik.Token.reaches?(token, owners) or
                allowed?(Share.mode(shares, tree, id), mode)),
         do:
           {:error,
            "shared #{name}: #{tree} belongs to #{owners}, which the token does not reach"}
    end)
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
