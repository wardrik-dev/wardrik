defmodule Wardrik.Definition do
  @moduledoc """
  Where agents' definitions go: a definition as `wardrik_protocol`'s
  `agent_definition.json` describes it, read into the `Wardrik.Agent.Spec` it
  runs on, and the triggers beside it.

  A host names the module once, as `Wardrik`'s `:definitions`, and every
  operation that defines an agent asks it, whichever surface it came from:

      children = [{Wardrik, definitions: MyApp.Definitions}]

  The module decides what a definition may say, the seams its agent is
  given, whether it is kept, and who owns an agent. The operation checks the
  caller's grant first, runs the spec `put/3` answers with
  `Wardrik.Fleet.put/1`, and puts the grant's ceiling ahead of the spec's own
  hooks, so no module lets a definition loosen it; see `Wardrik.Grant`.

  | Callback | Operation | Without it |
  | --- | --- | --- |
  | `put/3` | `Wardrik.Operations.Define` | no module is named, and each operation is `:unsupported` |
  | `get/1` | `Wardrik.Operations.ReadDefinition` | `:unsupported` |
  | `delete/1` | `Wardrik.Operations.Forget`, `ForgetAgents` | the agent is forgotten, and no definition with it |
  | `put_trigger/3` | `Wardrik.Operations.SetTrigger` | `:unsupported` |
  | `delete_trigger/2` | `Wardrik.Operations.RemoveTrigger` | `:unsupported` |

  A daemon's is `WardrikDaemon.Agents`, which reads a definition as it reads an
  agent file, keeps it, and refuses the agents its files declare. A module
  that keeps definitions, in `WardrikStore` or elsewhere, implements all of
  them.
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
  @callback put(id :: Wardrik.AgentID.t(), definition :: map(), grant :: Wardrik.Grant.t()) ::
              {:ok, Wardrik.Agent.Spec.t()}
              | {:error, String.t()}
              | {:error, :conflict, String.t()}

  @doc "The definition last put for the agent `id`, as it was sent."
  @callback get(id :: Wardrik.AgentID.t()) :: {:ok, map()} | {:error, :not_found}

  @doc """
  Told that the agent `id` is to be forgotten, before it is:
  `:ok` where a definition was kept and is gone, `{:error, :not_found}` where
  none was, and `{:error, :conflict, message}` to refuse, which leaves the
  agent be.
  """
  @callback delete(id :: Wardrik.AgentID.t()) ::
              :ok | {:error, :not_found} | {:error, :conflict, String.t()}

  @doc """
  Sets the trigger `name` of the agent `id` to `fields`, as
  `wardrik_protocol`'s `trigger_definition.json` describes them: whether it
  was `:created` or `:changed`, and the trigger as `trigger.json` describes
  it. `{:error, :not_found}` is for an agent the module keeps no definition
  for, a message for fields that do not read.
  """
  @callback put_trigger(id :: Wardrik.AgentID.t(), name :: String.t(), fields :: map()) ::
              {:ok, :created | :changed, map()}
              | {:error, :not_found}
              | {:error, String.t()}
              | {:error, :conflict, String.t()}

  @doc """
  Deletes the trigger `name` of the agent `id`: `:ok`, `{:error, :not_found}`
  where it has none, or a conflict.
  """
  @callback delete_trigger(id :: Wardrik.AgentID.t(), name :: String.t()) ::
              :ok | {:error, :not_found} | {:error, :conflict, String.t()}

  @doc """
  `:ok` where the agent `id` may be changed or forgotten through this
  module, or a conflict saying why not, as one an agent file declares; it
  changes nothing. A module without it lets every agent be.
  """
  @callback editable(id :: Wardrik.AgentID.t()) :: :ok | {:error, :conflict, String.t()}

  @optional_callbacks get: 1, delete: 1, put_trigger: 3, delete_trigger: 2, editable: 1

  @callbacks %{put: 3, get: 1, delete: 1, put_trigger: 3, delete_trigger: 2, editable: 1}
  @module {__MODULE__, :module}

  @doc """
  Keeps `module`, or `nil` for none, as the host's: every operation finds it
  from then on. Answers `:ignore`, so `Wardrik` runs it as a child that
  starts nothing.
  """
  @spec configure(module() | nil) :: :ignore
  def configure(module) when is_atom(module) do
    :persistent_term.put(@module, module)
    :ignore
  end

  @doc """
  `:ok` where the host's module lets the agent `id` be changed or forgotten,
  or a conflict saying why not; `:ok` where it does not say.
  """
  @spec editable(Wardrik.AgentID.t()) :: :ok | {:error, :conflict, String.t()}
  def editable(id) do
    case module(:editable) do
      {:ok, module} -> module.editable(id)
      :unsupported -> :ok
    end
  end

  @doc "Whether the host's module keeps a definition of the agent `id`; `false` where it keeps none."
  @spec kept?(Wardrik.AgentID.t()) :: boolean()
  def kept?(id) do
    case module(:get) do
      {:ok, module} -> match?({:ok, _definition}, module.get(id))
      :unsupported -> false
    end
  end

  @doc """
  Forgets the definition the host's module keeps of the agent `id`, as the
  agent is forgotten: whether one was kept, or a conflict where the module
  refuses. A host that keeps none forgets nothing.
  """
  @spec forget(Wardrik.AgentID.t()) :: {:ok, boolean()} | {:error, :conflict, String.t()}
  def forget(id) do
    case module(:delete) do
      {:ok, module} -> forgotten(module.delete(id))
      :unsupported -> {:ok, false}
    end
  end

  defp forgotten(:ok), do: {:ok, true}
  defp forgotten({:error, :not_found}), do: {:ok, false}
  defp forgotten({:error, :conflict, why}), do: {:error, :conflict, why}

  @doc """
  The host's module, where it has `callback`, or `:unsupported`: none was
  named, or it does not keep what `callback` is for.
  """
  @spec module(atom()) :: {:ok, module()} | :unsupported
  def module(callback) do
    with module when module != nil <- :persistent_term.get(@module, nil),
         {:module, module} <- Code.ensure_loaded(module),
         true <- function_exported?(module, callback, Map.fetch!(@callbacks, callback)) do
      {:ok, module}
    else
      _none -> :unsupported
    end
  end
end
