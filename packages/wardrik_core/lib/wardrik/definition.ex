defprotocol Wardrik.Definition do
  @moduledoc """
  What every agent is, as the host keeps it: a definition as
  `WardrikProtocol`'s `agent_definition.json` describes it, read into the
  `Wardrik.Agent.Spec` it runs on, and the triggers beside it. It is where
  an agent's spec comes from as it is defined, created, started or woken.

  A host names the value once, as the `:definitions` of its
  `Wardrik.Host`, and every function of `Wardrik` on agents asks it,
  whichever surface it came from, as does every agent as it starts or wakes. The value carries what
  its implementation needs, such as the store it keeps definitions in:

      host = Wardrik.Host.new(definitions: %MyApp.Definitions{store: store})
      children = [{Wardrik.Core, host: host}]

  The implementation decides what a definition may say, the seams its agent
  is given, whether it is kept, and who owns an agent. `Wardrik` checks
  the caller's grant first, runs the spec `put/3` answers with
  `Wardrik.Fleet.put/1`, and puts the grant's ceiling ahead of the spec's
  own hooks, so no implementation lets a definition loosen it; see
  `Wardrik.Grant`.

  | Function | `Wardrik` | `Wardrik.Definition.None` |
  | --- | --- | --- |
  | `put/3` | `agent_define/3` | `:unsupported` |
  | `get/2` | `agent_definition_read/2` | `:unsupported` |
  | `delete/2` | `agent_forget/2`, `agents_forget/2` | the agent is forgotten, and no definition with it |
  | `put_trigger/4` | `agent_trigger_set/4` | `:unsupported` |
  | `delete_trigger/3` | `agent_trigger_remove/3` | `:unsupported` |
  | `editable/2` | `agent_forget/2`, `agents_forget/2`, which keep what it refuses | every agent may be forgotten |
  | `current/2` | `agent_spawn/3`, `Wardrik.Fleet.whereis/2`, and an agent starting or waking | an agent starts and wakes as it was stored |
  | `defined/2` | `Wardrik.Fleet.list/2`, for agents not yet started | none |
  | `create/2` | `agent_spawn/3`, for an agent nothing defines | `:unsupported`: such an agent is not found |
  | `reloading/1`, `reload/1` | `deployment_reload/1`, on every node `reloading/1` names | no node, so `:unsupported` |

  A daemon's is `WardrikDaemon.Agents`, which reads a definition as it reads
  an agent file, keeps it, and refuses the agents its files declare. An
  implementation that keeps some of them uses `Wardrik.Definition.None` in
  its `defimpl`, and answers the rest as it does. `Wardrik.Definitions`
  holds what `Wardrik` does with a host's definitions beyond one call.
  """

  @doc """
  The spec for the agent `id`, from the fields of the definition `opts`
  name, or a message saying what does not read. `{:error, :conflict, message}` refuses an
  agent the implementation does not let anyone define.

    * `:definition` - its fields, as sent
    * `:grant` - the caller's `Wardrik.Grant`

  The grant decides what the definition may reach, such as the trees
  an agent shares, is the implementation's to check against its scope, and
  one that builds the spec again later holds it under the same ceiling. The
  spec is for `id` and no other.
  """
  @spec put(t(), Wardrik.AgentID.t(), definition: map(), grant: Wardrik.Grant.t()) ::
          {:ok, Wardrik.Agent.Spec.t()}
          | {:error, String.t()}
          | {:error, :conflict, String.t()}
          | :unsupported
  def put(definitions, id, opts)

  @doc """
  The definition last put for the agent `id`, as it was sent, with the tools
  it names that offer nothing yet; see `Wardrik.Definition.Read`.
  """
  @spec get(t(), Wardrik.AgentID.t()) ::
          {:ok, Wardrik.Definition.Read.t()} | {:error, :not_found} | :unsupported
  def get(definitions, id)

  @doc """
  Told that the agent `id` is to be forgotten, before it is:
  `:ok` where a definition was kept and is gone, `{:error, :not_found}` where
  none was, and `{:error, :conflict, message}` to refuse, which leaves the
  agent be.
  """
  @spec delete(t(), Wardrik.AgentID.t()) ::
          :ok | {:error, :not_found} | {:error, :conflict, String.t()}
  def delete(definitions, id)

  @doc """
  Sets the trigger `name` of the agent `id` to the `:fields` `opts` name, as
  `WardrikProtocol`'s `trigger_definition.json` describes them: whether it
  was `:created` or `:changed`, and the trigger as `trigger.json` describes
  it. `{:error, :not_found}` is for an agent no definition is kept for, a
  message for fields that do not read.
  """
  @spec put_trigger(t(), Wardrik.AgentID.t(), String.t(), fields: map()) ::
          {:ok, :created | :changed, map()}
          | {:error, :not_found}
          | {:error, String.t()}
          | {:error, :conflict, String.t()}
          | :unsupported
  def put_trigger(definitions, id, name, opts)

  @doc """
  Deletes the trigger `name` of the agent `id`: the trigger it was, as
  `put_trigger/4` answers one, `{:error, :not_found}` where it has none, or
  a conflict.
  """
  @spec delete_trigger(t(), Wardrik.AgentID.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found} | {:error, :conflict, String.t()} | :unsupported
  def delete_trigger(definitions, id, name)

  @doc """
  `:ok` where the agent `id` may be changed or forgotten through these
  definitions, or a conflict saying why not, as one an agent file declares;
  it changes nothing.
  """
  @spec editable(t(), Wardrik.AgentID.t()) :: :ok | {:error, :conflict, String.t()}
  def editable(definitions, id)

  @doc """
  The spec the agent `id` runs on now, from the definition kept of it, or of
  the agent it is a conversation of, or `:none` where none is kept. An agent
  takes it as it starts, wakes, or restarts on another node, so a definition
  changed while it slept is the one it wakes with, and `Wardrik.Fleet`
  starts from it an agent the store does not hold.
  """
  @spec current(t(), Wardrik.AgentID.t()) :: {:ok, Wardrik.Agent.Spec.t()} | :none
  def current(definitions, id)

  @doc """
  The agents a definition is kept for under `prefix`, found without
  building any, so `Wardrik.Fleet.list/1` lists those not yet started.
  """
  @spec defined(t(), Wardrik.AgentID.Prefix.t()) :: [Wardrik.AgentID.t()]
  def defined(definitions, prefix)

  @doc """
  Defines the agent `id`, which nothing defines yet, from what the host
  gives every new agent, and answers the spec it runs on; or a message
  saying why it cannot, or a conflict where something else already holds
  what it would write; `:unsupported` where it creates none.
  """
  @spec create(t(), Wardrik.AgentID.t()) ::
          {:ok, Wardrik.Agent.Spec.t()}
          | {:error, String.t()}
          | {:error, :conflict, String.t()}
          | :unsupported
  def create(definitions, id)

  @doc """
  Reads every definition this node keeps again, and brings the agents it
  runs to what they say now. Asked on each node `reloading/1` names, with
  the value of the node asking, so what names this node's own is found by
  name there.
  """
  @spec reload(t()) :: :ok
  def reload(definitions)

  @doc """
  The nodes whose definitions are read again on `reload/1`: every node of
  the deployment running what reads them, as each daemon's does. `[]` where
  nothing does, which leaves `Wardrik.deployment_reload/1` `:unsupported`.
  """
  @spec reloading(t()) :: [node()]
  def reloading(definitions)
end
