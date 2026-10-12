defmodule Wardrik.Definition do
  @moduledoc """
  Where agents' definitions go: a definition as `wardrik_protocol`'s
  `agent_definition.json` describes it, read into the `Wardrik.Agent.Spec` it
  runs on, and the schedules beside it.

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
  | `delete/1` | `Wardrik.Operations.Forget` | `:unsupported` |
  | `put_schedule/3` | `Wardrik.Operations.SetSchedule` | `:unsupported` |
  | `delete_schedule/2` | `Wardrik.Operations.RemoveSchedule` | `:unsupported` |

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
  Sets the schedule `name` of the agent `id` to `fields`, as
  `wardrik_protocol`'s `schedule_definition.json` describes them: whether it
  was `:created` or `:changed`, and the schedule as `schedule.json` describes
  it. `{:error, :not_found}` is for an agent the module keeps no definition
  for, a message for fields that do not read.
  """
  @callback put_schedule(id :: Wardrik.AgentID.t(), name :: String.t(), fields :: map()) ::
              {:ok, :created | :changed, map()}
              | {:error, :not_found}
              | {:error, String.t()}
              | {:error, :conflict, String.t()}

  @doc """
  Deletes the schedule `name` of the agent `id`: `:ok`, `{:error, :not_found}`
  where it has none, or a conflict.
  """
  @callback delete_schedule(id :: Wardrik.AgentID.t(), name :: String.t()) ::
              :ok | {:error, :not_found} | {:error, :conflict, String.t()}

  @optional_callbacks get: 1, delete: 1, put_schedule: 3, delete_schedule: 2

  @callbacks %{put: 3, get: 1, delete: 1, put_schedule: 3, delete_schedule: 2}
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
