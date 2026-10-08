defmodule WardrikHTTP.Definition do
  @moduledoc """
  Where the HTTP API's agent definitions go: the body of
  `PUT /v1/agents/{id}`, as
  `wardrik_protocol`'s `agent_definition.json` describes it, read into the
  `Wardrik.Agent.Spec` it writes.

  `WardrikHTTP.Listener` takes the module as `:definition`. The router checks the
  token's scope, runs the spec `put/3` answers with `Wardrik.Fleet.put/1`, and
  forgets the agent on `DELETE`; the module decides what a definition may say,
  the seams its agent is given, whether it is kept, and who owns an agent. Every
  spec runs under the token's ceiling, whose hooks the router puts ahead of the
  spec's own, so no module lets a definition loosen it; see `Wardrik.Grant`.

  | Callback | Route | Without it |
  | --- | --- | --- |
  | `put/3` | `PUT /v1/agents/{id}` | the listener has no module, and the route answers `501` |
  | `get/1` | `GET /v1/agents/{id}/definition` | `501` |
  | `delete/1` | `DELETE /v1/agents/{id}` | `501` |
  | `put_schedule/3` | `PUT /v1/agents/{id}/schedules/{schedule}` | `501` |
  | `delete_schedule/2` | `DELETE /v1/agents/{id}/schedules/{schedule}` | `501` |

  A daemon's is `WardrikDaemon.Agents`, which reads a definition as it reads an
  agent file, keeps it, and refuses the agents its files declare. A module
  that keeps definitions, in `Wardrik.Store` or elsewhere, implements all of
  them.
  """

  @doc """
  The spec for the agent `id`, from the definition's fields, or a
  message saying what does not read. `{:error, :conflict, message}` refuses an
  agent the module does not let the API define, and answers `409`.

  `grant` is the defining token's: what the definition may reach, such as
  the trees an agent shares, is the module's to check against its scope, and
  a module that builds the spec again later holds it under the same ceiling.
  The spec is for `id` and no other.
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
  none was, and `{:error, :conflict, message}` to refuse, which answers `409`
  and leaves the agent be.
  """
  @callback delete(id :: Wardrik.AgentID.t()) ::
              :ok | {:error, :not_found} | {:error, :conflict, String.t()}

  @doc """
  Sets the schedule `name` of the agent `id` to `fields`, the body of the
  route as `wardrik_protocol`'s `schedule_definition.json` describes it:
  whether it was `:created`, which answers `201`, or `:changed`, and the
  schedule as `schedule.json` describes it. `{:error, :not_found}` answers
  `404` for an agent the module keeps no definition for, a message `400` for
  fields that do not read, and a conflict `409`.
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
end
