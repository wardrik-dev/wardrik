defmodule Wardrik.Definition do
  @moduledoc """
  What every agent is, as the host keeps it: a definition as
  `wardrik_protocol`'s `agent_definition.json` describes it, read into the
  `Wardrik.Agent.Spec` it runs on, and the triggers beside it. It is where
  an agent's spec comes from as it is defined, created, started or woken.

  A host names the module once, as the `:definitions` of its
  `Wardrik.Host`, and every operation asks it, whichever surface it came
  from, as does every agent as it starts or wakes. Every callback but
  `reload/0` and `reloading/0` is handed the host first, for the store it
  keeps definitions in:

      host = Wardrik.Host.new(definitions: MyApp.Definitions)
      children = [{Wardrik, host: host}]

  The module decides what a definition may say, the seams its agent is
  given, whether it is kept, and who owns an agent. The operation checks the
  caller's grant first, runs the spec `put/4` answers with
  `Wardrik.Fleet.put/1`, and puts the grant's ceiling ahead of the spec's own
  hooks, so no module lets a definition loosen it; see `Wardrik.Grant`.

  | Callback | Operation | `Wardrik.Definition.None` |
  | --- | --- | --- |
  | `put/4` | `Wardrik.Operations.Define` | `:unsupported` |
  | `get/2` | `Wardrik.Operations.ReadDefinition` | `:unsupported` |
  | `delete/2` | `Wardrik.Operations.Forget`, `ForgetAgents` | the agent is forgotten, and no definition with it |
  | `put_trigger/4` | `Wardrik.Operations.SetTrigger` | `:unsupported` |
  | `delete_trigger/3` | `Wardrik.Operations.RemoveTrigger` | `:unsupported` |
  | `editable/2` | `Wardrik.Operations.Forget`, `ForgetAgents`, which keep what it refuses | every agent may be forgotten |
  | `current/2` | `Wardrik.Operations.Spawn`, `SpawnOn`, and an agent starting or waking | an agent starts and wakes as it was stored |
  | `create/2` | `Wardrik.Operations.Spawn`, `SpawnOn`, for an agent nothing defines | `:unsupported`: such an agent is not found |
  | `reloading/0`, `reload/0` | `Wardrik.Operations.Reload`, on every node `reloading/0` names | no node, so `:unsupported` |

  A daemon's is `WardrikDaemon.Agents`, which reads a definition as it reads an
  agent file, keeps it, and refuses the agents its files declare. A module
  that keeps definitions, in `WardrikStore` or elsewhere, implements all of
  them; one that keeps some uses this module, and answers the rest as
  `Wardrik.Definition.None` does.
  """

  @doc """
  The spec for the agent `id`, from the definition's fields, or a
  message saying what does not read. `{:error, :conflict, message}` refuses an
  agent the module does not let anyone define.

  `grant` is the caller's: what the definition may reach, such as the trees
  an agent shares, is the module's to check against its scope, and a module
  that builds the spec again later holds it under the same ceiling. The spec
  is for `id` and no other.
  """
  @callback put(
              Wardrik.Host.t(),
              id :: Wardrik.AgentID.t(),
              definition :: map(),
              grant :: Wardrik.Grant.t()
            ) ::
              {:ok, Wardrik.Agent.Spec.t()}
              | {:error, String.t()}
              | {:error, :conflict, String.t()}
              | :unsupported

  @doc "The definition last put for the agent `id`, as it was sent."
  @callback get(Wardrik.Host.t(), id :: Wardrik.AgentID.t()) ::
              {:ok, map()} | {:error, :not_found} | :unsupported

  @doc """
  Told that the agent `id` is to be forgotten, before it is:
  `:ok` where a definition was kept and is gone, `{:error, :not_found}` where
  none was, and `{:error, :conflict, message}` to refuse, which leaves the
  agent be.
  """
  @callback delete(Wardrik.Host.t(), id :: Wardrik.AgentID.t()) ::
              :ok | {:error, :not_found} | {:error, :conflict, String.t()}

  @doc """
  Sets the trigger `name` of the agent `id` to `fields`, as
  `wardrik_protocol`'s `trigger_definition.json` describes them: whether it
  was `:created` or `:changed`, and the trigger as `trigger.json` describes
  it. `{:error, :not_found}` is for an agent the module keeps no definition
  for, a message for fields that do not read.
  """
  @callback put_trigger(
              Wardrik.Host.t(),
              id :: Wardrik.AgentID.t(),
              name :: String.t(),
              fields :: map()
            ) ::
              {:ok, :created | :changed, map()}
              | {:error, :not_found}
              | {:error, String.t()}
              | {:error, :conflict, String.t()}
              | :unsupported

  @doc """
  Deletes the trigger `name` of the agent `id`: `:ok`, `{:error, :not_found}`
  where it has none, or a conflict.
  """
  @callback delete_trigger(Wardrik.Host.t(), id :: Wardrik.AgentID.t(), name :: String.t()) ::
              :ok | {:error, :not_found} | {:error, :conflict, String.t()} | :unsupported

  @doc """
  `:ok` where the agent `id` may be changed or forgotten through this
  module, or a conflict saying why not, as one an agent file declares; it
  changes nothing.
  """
  @callback editable(Wardrik.Host.t(), id :: Wardrik.AgentID.t()) ::
              :ok | {:error, :conflict, String.t()}

  @doc """
  The spec the agent `id` runs on now, from the definition kept of it, or of
  the agent it is a conversation of, or `:none` where none is kept. An agent
  takes it as it starts, wakes, or restarts on another node, so a definition
  changed while it slept is the one it wakes with.
  """
  @callback current(Wardrik.Host.t(), id :: Wardrik.AgentID.t()) ::
              {:ok, Wardrik.Agent.Spec.t()} | :none

  @doc """
  Defines the agent `id`, which nothing defines yet, from what the host
  gives every new agent, and answers the spec it runs on; or a message
  saying why it cannot, or a conflict where something else already holds
  what it would write; `:unsupported` where it creates none.
  """
  @callback create(Wardrik.Host.t(), id :: Wardrik.AgentID.t()) ::
              {:ok, Wardrik.Agent.Spec.t()}
              | {:error, String.t()}
              | {:error, :conflict, String.t()}
              | :unsupported

  @doc """
  Reads every definition this node's module keeps again, and brings the
  agents it runs to what they say now. Asked on each node `reloading/0`
  names.
  """
  @callback reload() :: :ok

  @doc """
  The nodes whose module reads its definitions again on `reload/0`: every
  node of the deployment running what reads them, as each daemon's does.
  `[]` where nothing does, which leaves `Wardrik.Operations.Reload`
  `:unsupported`.
  """
  @callback reloading() :: [node()]

  @doc """
  A module that implements some of the callbacks, as one that keeps no
  triggers, uses this: every callback it leaves out answers as
  `Wardrik.Definition.None` does.

      defmodule MyApp.Definitions do
        use Wardrik.Definition

        @impl Wardrik.Definition
        def put(host, id, definition, grant), do: ...
      end
  """
  defmacro __using__(_opts) do
    quote do
      @behaviour Wardrik.Definition

      @impl Wardrik.Definition
      def put(_host, _id, _definition, _grant), do: :unsupported

      @impl Wardrik.Definition
      def get(_host, _id), do: :unsupported

      @impl Wardrik.Definition
      def delete(_host, _id), do: {:error, :not_found}

      @impl Wardrik.Definition
      def put_trigger(_host, _id, _name, _fields), do: :unsupported

      @impl Wardrik.Definition
      def delete_trigger(_host, _id, _name), do: :unsupported

      @impl Wardrik.Definition
      def editable(_host, _id), do: :ok

      @impl Wardrik.Definition
      def current(_host, _id), do: :none

      @impl Wardrik.Definition
      def create(_host, _id), do: :unsupported

      @impl Wardrik.Definition
      def reload, do: :ok

      @impl Wardrik.Definition
      def reloading, do: []

      defoverridable Wardrik.Definition
    end
  end

  @doc """
  Reads every definition again on each of `nodes`, through `module`, one
  after another.
  """
  @spec reload_on(module(), [node()]) :: :ok
  def reload_on(module, nodes) when is_list(nodes) do
    Enum.each(nodes, &(:ok = :erpc.call(&1, module, :reload, [], :timer.minutes(1))))
  end

  @doc "Whether the definitions of `host` keep one of the agent `id`."
  @spec kept?(Wardrik.Host.t(), Wardrik.AgentID.t()) :: boolean()
  def kept?(host, id),
    do: match?({:ok, _definition}, Wardrik.Host.definitions(host).get(host, id))

  @doc """
  Forgets the definition the definitions of `host` keep of the agent `id`,
  as the agent is forgotten: whether one was kept, or a conflict where they
  refuse.
  """
  @spec forget(Wardrik.Host.t(), Wardrik.AgentID.t()) ::
          {:ok, boolean()} | {:error, :conflict, String.t()}
  def forget(host, id) do
    case Wardrik.Host.definitions(host).delete(host, id) do
      :ok -> {:ok, true}
      {:error, :not_found} -> {:ok, false}
      {:error, :conflict, why} -> {:error, :conflict, why}
    end
  end
end
